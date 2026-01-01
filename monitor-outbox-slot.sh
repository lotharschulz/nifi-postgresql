#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Outbox Monitoring Script
# Monitors PostgreSQL outbox table for pending events and processing metrics

# Configuration
AGE_THRESHOLD_SECONDS=300  # 5 minutes - threshold for warning about old unprocessed events

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
CONTINUOUS=0
INTERVAL=10
SHOW_HELP=0
for arg in "$@"; do
    case "$arg" in
        --continuous|-c) CONTINUOUS=1 ;;
        --interval=*) INTERVAL="${arg#*=}" ;;
        --help|-h) SHOW_HELP=1 ;;
    esac
done

# Show help and exit if requested (before sourcing .env to allow --help when .env doesn't exist)
if [ "$SHOW_HELP" = "1" ]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "Outbox Monitoring Tool - Monitor PostgreSQL outbox table for pending events"
    echo ""
    echo "Options:"
    echo "  --continuous, -c     Run continuously (default: run once)"
    echo "  --interval=SECONDS   Interval between checks in continuous mode (default: 10)"
    echo "  --help, -h           Show this help"
    echo ""
    echo "Best Practices:"
    echo "  1. Monitor outbox table size regularly"
    echo "  2. Old unprocessed events may indicate consumer issues"
    echo "  3. Set up alerts for high event counts or old events"
    echo "  4. Ensure NiFi consumers are running properly"
    echo ""
    echo "Examples:"
    echo "  $0                      # Run once"
    echo "  $0 --continuous         # Run continuously with 10s interval"
    echo "  $0 -c --interval=30     # Run continuously with 30s interval"
    exit 0
fi

# Check if .env exists and source it
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found. Please create it from .env.example${NC}"
    exit 1
fi

source .env

echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   PostgreSQL Outbox Monitoring Tool          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}\n"

monitor_outbox() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${BLUE}=== Monitoring at ${timestamp} ===${NC}\n"
    
    # Check if outbox table exists
    local table_exists=$(docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
        "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'outbox');" 2>/dev/null || echo "f")
    
    if [ "$table_exists" != "t" ]; then
        echo -e "${RED}✗ Outbox table not found${NC}"
        echo -e "  Create the table with: ${CYAN}docker-compose up -d${NC}\n"
        return
    fi
    
    # Summary -> Get Pending Events Count
    local pending_count=$(docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
        "SELECT COUNT(*) FROM outbox;" 2>/dev/null || echo "0")
    
    if [ "$pending_count" -eq 0 ]; then
        echo -e "${GREEN}✓ No pending events in outbox table${NC}"
        echo -e "  Generate test data with: ${CYAN}./test-outbox.sh${NC}\n"
    else
        echo -e "${YELLOW}⚠ Pending events in outbox: ${pending_count}${NC}\n"
    fi
    
    # Summary -> Event Type Distribution (event type overview)
    echo -e "${YELLOW}Event Type Distribution:${NC}"
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            event_type,
            COUNT(*) as count,
            MIN(created_at) as oldest_event,
            MAX(created_at) as newest_event
        FROM outbox
        GROUP BY event_type
        ORDER BY count DESC;" 2>/dev/null
    
    # Health status/alerts -> Event Age Analysis (identifies problems/warnings)
    # Check for old events
    echo -e "\n${YELLOW}Event Age Analysis:${NC}"
    local old_count=$(docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
        "SELECT COUNT(*) FROM outbox 
         WHERE created_at < NOW() - INTERVAL '${AGE_THRESHOLD_SECONDS} seconds';" 2>/dev/null || echo "0")
    
    if [ "$old_count" -gt 0 ]; then
        echo -e "${RED}⚠ Warning: ${old_count} events older than $((AGE_THRESHOLD_SECONDS / 60)) minutes detected!${NC}"
        echo -e "${YELLOW}This may indicate that NiFi consumers are not processing events.${NC}"
        echo -e "${YELLOW}Action: Check NiFi flow status and processor state.${NC}\n"
        
        # Show oldest events
        echo -e "${YELLOW}Oldest Unprocessed Events:${NC}"
        docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
            "SELECT
                id,
                aggregate_type,
                event_type,
                aggregate_id,
                created_at,
                EXTRACT(EPOCH FROM (NOW() - created_at))::INTEGER as age_seconds
            FROM outbox
            ORDER BY created_at ASC
            LIMIT 5;" 2>/dev/null
    else
        echo -e "${GREEN}✓ No old events - all events are recent (< $((AGE_THRESHOLD_SECONDS / 60)) minutes)${NC}"
    fi
    
    # Breakdowns -> Aggregate Type Distribution (breakdown by aggregate type)
    echo -e "\n${YELLOW}Aggregate Type Distribution:${NC}"
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            aggregate_type,
            COUNT(*) as count
        FROM outbox
        GROUP BY aggregate_type
        ORDER BY count DESC;" 2>/dev/null
    
    # Sample data -> Recent Events (actual event records)
    # Show recent events
    if [ "$pending_count" -gt 0 ]; then
        echo -e "\n${YELLOW}Recent Events (Last 5):${NC}"
        docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
            "SELECT
                id,
                aggregate_type,
                event_type,
                aggregate_id,
                created_at
            FROM outbox
            ORDER BY created_at DESC
            LIMIT 5;" 2>/dev/null
    fi
    
    # Technical metrics -> Table Statistics (infrastructure/sizing info)
    # Show table statistics
    echo -e "\n${YELLOW}Outbox Table Statistics:${NC}"
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            pg_size_pretty(pg_total_relation_size('outbox')) as total_size,
            pg_size_pretty(pg_relation_size('outbox')) as table_size,
            pg_size_pretty(pg_indexes_size('outbox')) as indexes_size
        FROM pg_class
        WHERE relname = 'outbox';" 2>/dev/null
    
    echo ""
}

# Main execution
if [ "$CONTINUOUS" = "1" ]; then
    echo -e "${CYAN}Running in continuous mode (interval: ${INTERVAL}s). Press Ctrl+C to stop.${NC}\n"
    while true; do
        monitor_outbox
        echo -e "${CYAN}Waiting ${INTERVAL} seconds for next check...${NC}\n"
        sleep "$INTERVAL"
    done
else
    monitor_outbox
    
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Monitoring Complete                  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${YELLOW}Best Practices for Outbox Pattern:${NC}"
    echo -e "  1. ${CYAN}Monitor Regularly:${NC} Run this script to track outbox status"
    echo -e "     ${BLUE}./monitor-outbox-slot.sh --continuous${NC}"
    echo -e ""
    echo -e "  2. ${CYAN}Check Consumer Status:${NC} Ensure NiFi flow is running"
    echo -e "     ${BLUE}docker-compose logs nifi | grep OUTBOX_EVENT${NC}"
    echo -e ""
    echo -e "  3. ${CYAN}Clean Old Events:${NC} If accumulating, check consumer health"
    echo -e "     ${BLUE}docker exec nifi_database psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT COUNT(*) FROM outbox;'${NC}"
    echo -e ""
    echo -e "  4. ${CYAN}Monitor Event Age:${NC} Old events indicate processing issues"
    echo -e "     ${BLUE}./nifi-diagnose.sh${NC}"
fi
