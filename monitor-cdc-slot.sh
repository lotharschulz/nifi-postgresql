#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# CDC Slot Monitoring Script
# Monitors PostgreSQL replication slots for WAL growth and lag
# Based on best practices from: https://www.lotharschulz.info/2025/10/15/postgresql-cdc-best-practices-managing-wal-growth-and-replication-slots/

# Configuration
LAG_THRESHOLD_BYTES=524288000  # 500 MB - threshold for warning about inactive slots

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
    echo "CDC Slot Monitoring Tool - Monitor PostgreSQL replication slots for WAL growth"
    echo ""
    echo "Options:"
    echo "  --continuous, -c     Run continuously (default: run once)"
    echo "  --interval=SECONDS   Interval between checks in continuous mode (default: 10)"
    echo "  --help, -h           Show this help"
    echo ""
    echo "Best Practices:"
    echo "  1. Monitor slot lag and activity regularly"
    echo "  2. Inactive slots can cause WAL accumulation"
    echo "  3. Set max_slot_wal_keep_size to prevent unlimited growth"
    echo "  4. Remove unused replication slots promptly"
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
echo -e "${GREEN}║   PostgreSQL CDC Slot Monitoring Tool        ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}\n"

monitor_slots() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${BLUE}=== Monitoring at ${timestamp} ===${NC}\n"
    
    # Check if any slots exist
    local slot_count=$(docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
        "SELECT COUNT(*) FROM pg_replication_slots;" 2>/dev/null || echo "0")
    
    if [ "$slot_count" -eq 0 ]; then
        echo -e "${RED}✗ No replication slots found${NC}"
        echo -e "  Create a slot with: ${CYAN}./test-cdc.sh --setup${NC}\n"
        return
    fi
    
    echo -e "${YELLOW}Total replication slots: ${slot_count}${NC}\n"
    
    # Monitor slot lag and activity
    echo -e "${YELLOW}Slot Status and WAL Lag:${NC}"
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            slot_name,
            active,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
            pg_size_pretty(COALESCE(safe_wal_size, 0)) AS safe_wal_size,
            restart_lsn,
            confirmed_flush_lsn
        FROM pg_replication_slots
        ORDER BY slot_name;"
    
    # Check for inactive slots
    echo -e "\n${YELLOW}Inactive Slots Analysis:${NC}"
    local inactive=$(docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            slot_name,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
            pg_size_pretty(COALESCE(safe_wal_size, 0)) AS safe_wal_size
        FROM pg_replication_slots
        WHERE NOT active;" 2>/dev/null)
    
    if echo "$inactive" | grep -q "(0 rows)"; then
        echo -e "${GREEN}✓ No inactive slots - all slots are active${NC}"
    else
        echo "$inactive"
        
        # Check if any inactive slots have large lag (indicating a real problem)
        local large_lag_count=$(docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
            "SELECT COUNT(*) FROM pg_replication_slots 
             WHERE NOT active 
             AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > ${LAG_THRESHOLD_BYTES};" 2>/dev/null || echo "0")
        
        if [ "$large_lag_count" -gt 0 ]; then
            echo -e "\n${RED}⚠ Warning: Inactive slots with large lag (>500 MB) detected!${NC}"
            echo -e "${YELLOW}This indicates slots are not being consumed and WAL is accumulating.${NC}"
            echo -e "${YELLOW}Action: Investigate why consumers are not active or remove unused slots.${NC}"
        else
            echo -e "\n${BLUE}🔍 Debug: Slots are inactive but lag is low.${NC}"
            echo -e "${CYAN}Context:${NC}"
            echo -e "${CYAN}  - This is appearing because flows like './test-cdc.sh --continuous' use${NC}"
            echo -e "${CYAN}    pg_logical_slot_get_changes() via ExecuteSQL on a schedule (e.g., every 10 seconds)${NC}"
            echo -e "${CYAN}  - This doesn't maintain a persistent connection${NC}"
            echo -e "${CYAN}  - Inactive slots with low lag are very likely being consumed periodically${NC}"
            echo -e "${CYAN}  - Slots are only 'active' when a consumer is actively connected and reading${NC}"
        fi
    fi
    
    # Show WAL configuration
    echo -e "\n${YELLOW}WAL Configuration:${NC}"
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            name,
            setting,
            unit
        FROM pg_settings
        WHERE name IN ('wal_level', 'max_replication_slots', 'max_wal_senders', 'max_slot_wal_keep_size')
        ORDER BY name;"
    
    # Calculate total WAL size
    echo -e "\n${YELLOW}WAL Directory Information:${NC}"
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            pg_size_pretty(SUM(size)) as total_wal_size,
            COUNT(*) as wal_file_count
        FROM pg_ls_waldir();" 2>/dev/null || echo -e "${YELLOW}Note: pg_ls_waldir() requires superuser privileges${NC}"
    
    echo ""
}

# Main execution
if [ "$CONTINUOUS" = "1" ]; then
    echo -e "${CYAN}Running in continuous mode (interval: ${INTERVAL}s). Press Ctrl+C to stop.${NC}\n"
    while true; do
        monitor_slots
        echo -e "${CYAN}Waiting ${INTERVAL} seconds for next check...${NC}\n"
        sleep "$INTERVAL"
    done
else
    monitor_slots
    
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Monitoring Complete                  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${YELLOW}Best Practices for WAL and Slot Management:${NC}"
    echo -e "  1. ${CYAN}Implement Slot Monitoring:${NC} Run this script regularly"
    echo -e "     ${BLUE}./monitor-cdc-slot.sh --continuous${NC}"
    echo -e ""
    echo -e "  2. ${CYAN}Set WAL Size Limits:${NC} Configure max_slot_wal_keep_size"
    echo -e "     ${BLUE}ALTER SYSTEM SET max_slot_wal_keep_size = '20GB';${NC}"
    echo -e ""
    echo -e "  3. ${CYAN}Monitor Inactive Slots:${NC} Remove or investigate inactive slots"
    echo -e "     ${BLUE}SELECT * FROM pg_replication_slots WHERE NOT active;${NC}"
    echo -e ""
    echo -e "  4. ${CYAN}Drop Unused Slots:${NC} Remove slots that are no longer needed"
    echo -e "     ${BLUE}SELECT pg_drop_replication_slot('slot_name');${NC}"
    echo -e ""
    echo -e "Reference: ${CYAN}https://www.lotharschulz.info/2025/10/15/postgresql-cdc-best-practices-managing-wal-growth-and-replication-slots/${NC}"
fi
