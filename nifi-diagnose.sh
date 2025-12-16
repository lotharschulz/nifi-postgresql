#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Diagnostic script for NiFi CDC/Outbox setup

source .env

NIFI_URL="https://${NIFI_HOST:-localhost}:${NIFI_PORT:-8443}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     NiFi CDC/Outbox Diagnostic Tool    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"

# Check Docker containers
echo -e "${BLUE}=== Docker Containers ===${NC}\n"
if docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "postgres_cdc|nifi_cdc"; then
    echo ""
else
    echo -e "${RED}Containers not running! Start with: docker-compose up -d${NC}\n"
fi

# Check NiFi connectivity
echo -e "${BLUE}=== NiFi Connectivity ===${NC}\n"
if curl -k -s "${NIFI_URL}/nifi-api/system-about" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ NiFi is accessible at ${NIFI_URL}${NC}"
else
    echo -e "${RED}✗ Cannot connect to NiFi at ${NIFI_URL}${NC}"
    echo -e "  Wait for NiFi to start or check logs: docker-compose logs nifi"
    exit 1
fi

# Get token
TOKEN=$(curl -k -s -X POST "${NIFI_URL}/nifi-api/access/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "username=${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}&password=${NIFI_SINGLE_USER_CREDENTIALS_PASSWORD}")

if [ -z "$TOKEN" ]; then
    echo -e "${RED}✗ Failed to authenticate${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Authentication successful${NC}\n"

# Function to check process group
check_process_group() {
    local pg_name=$1
    echo -e "${BLUE}=== ${pg_name} ===${NC}\n"
    
    local pg_id=$(curl -sk "${NIFI_URL}/nifi-api/flow/process-groups/root" \
        -H "Authorization: Bearer ${TOKEN}" | \
        jq -r ".processGroupFlow.flow.processGroups[]? | select(.component.name==\"${pg_name}\") | .component.id")
    
    if [ -z "$pg_id" ] || [ "$pg_id" = "null" ]; then
        echo -e "${RED}✗ Process group not found${NC}\n"
        return
    fi
    
    echo -e "${GREEN}✓ Process group exists: ${pg_id}${NC}\n"
    
    # Get processor status
    echo -e "${YELLOW}Processors:${NC}"
    local proc_data=$(curl -sk "${NIFI_URL}/nifi-api/process-groups/${pg_id}/processors" \
        -H "Authorization: Bearer ${TOKEN}")
    
    echo "$proc_data" | jq -r '.processors[] | 
        "\(.component.state | if . == "STOPPED" then "⏹" elif . == "RUNNING" then "▶" else "?" end) \(.component.name): \(.component.validationStatus)"' | \
        while read line; do
            if echo "$line" | grep -q "VALID"; then
                echo -e "  ${GREEN}${line}${NC}"
            elif echo "$line" | grep -q "INVALID"; then
                echo -e "  ${RED}${line}${NC}"
            else
                echo -e "  ${YELLOW}${line}${NC}"
            fi
        done
    
    # Check for validation errors
    local errors=$(echo "$proc_data" | jq -r '.processors[] | select(.component.validationErrors | length > 0) | "\(.component.name): \(.component.validationErrors | join("; "))"')
    
    if [ -n "$errors" ]; then
        echo -e "\n${RED}Validation Errors:${NC}"
        echo "$errors" | while read line; do
            echo -e "  ${RED}• ${line}${NC}"
        done
    fi
    
    # Controller services
    echo -e "\n${YELLOW}Controller Services:${NC}"
    curl -sk "${NIFI_URL}/nifi-api/flow/process-groups/${pg_id}/controller-services" \
        -H "Authorization: Bearer ${TOKEN}" | \
        jq -r '.controllerServices[]? | 
            "\(.component.state | if . == "ENABLED" then "✓" else "✗" end) \(.component.name): \(.component.state)"' | \
        while read line; do
            if echo "$line" | grep -q "ENABLED"; then
                echo -e "  ${GREEN}${line}${NC}"
            else
                echo -e "  ${RED}${line}${NC}"
            fi
        done
    
    echo ""
}

# Check both patterns
check_process_group "PostgreSQL CDC Pattern"
check_process_group "PostgreSQL Outbox Pattern"

# Database checks
echo -e "${BLUE}=== PostgreSQL Database ===${NC}\n"

if docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "SELECT 1;" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ PostgreSQL is accessible${NC}"
else
    echo -e "${RED}✗ Cannot connect to PostgreSQL${NC}"
fi

# Check tables
echo -e "\n${YELLOW}Tables:${NC}"
for table in orders outbox; do
    if docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "SELECT 1 FROM ${table} LIMIT 1;" > /dev/null 2>&1; then
        count=$(docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c "SELECT COUNT(*) FROM ${table};")
        echo -e "  ${GREEN}✓ ${table}${NC} (${count} rows)"
    else
        echo -e "  ${RED}✗ ${table} - not found${NC}"
    fi
done

# Check replication slot
echo -e "\n${YELLOW}Replication Slot:${NC}"
slot=$(docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
    "SELECT slot_name || ' (' || plugin || ')' FROM pg_replication_slots WHERE slot_name = 'nifi_cdc_slot';")
if [ -n "$slot" ]; then
    pending=$(docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
        "SELECT COUNT(*) FROM pg_logical_slot_peek_changes('nifi_cdc_slot', NULL, 100);" 2>/dev/null || echo "?")
    echo -e "  ${GREEN}✓ ${slot}${NC} (${pending} pending changes)"
else
    echo -e "  ${RED}✗ nifi_cdc_slot not found${NC}"
    echo -e "  Create with: ${CYAN}./test-cdc.sh --setup${NC}"
fi

# CDC Slot Monitoring - WAL Growth and Replication Slots
echo -e "\n${BLUE}=== CDC Slot Monitoring (WAL & Slot Management) ===${NC}\n"
echo -e "${YELLOW}Monitoring slot lag and activity...${NC}\n"

# Check if any slots exist
slot_count=$(docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
    "SELECT COUNT(*) FROM pg_replication_slots;")

if [ "$slot_count" -eq 0 ]; then
    echo -e "${RED}✗ No replication slots found${NC}"
    echo -e "  Create a slot with: ${CYAN}./test-cdc.sh --setup${NC}\n"
else
    # Monitor slot lag and activity
    docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
        "SELECT
            slot_name,
            active,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
            pg_size_pretty(COALESCE(safe_wal_size, 0)) AS safe_wal_size,
            restart_lsn,
            confirmed_flush_lsn
        FROM pg_replication_slots
        ORDER BY slot_name;"
    
    # Check for inactive slots with large lag
    inactive_count=$(docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c \
        "SELECT COUNT(*) FROM pg_replication_slots WHERE NOT active;")
    
    if [ "$inactive_count" -gt 0 ]; then
        echo -e "\n${RED}⚠ Warning: ${inactive_count} inactive replication slot(s) detected${NC}"
        echo -e "${YELLOW}Inactive slots can cause WAL accumulation and disk space issues.${NC}"
        echo -e "${YELLOW}Consider monitoring these slots or removing them if no longer needed.${NC}\n"
    else
        echo -e "\n${GREEN}✓ All replication slots are active${NC}\n"
    fi
fi

echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Diagnostic Complete           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
