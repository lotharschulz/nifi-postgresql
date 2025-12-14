#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Test script for CDC Pattern
# Performs database operations to generate CDC events

source .env

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Parse arguments
SETUP_ONLY=0
SHOW_LOGS=0
CONTINUOUS=0
for arg in "$@"; do
    case "$arg" in
        --setup|-s) SETUP_ONLY=1 ;;
        --logs|-l) SHOW_LOGS=1 ;;
        --continuous|-c) CONTINUOUS=1 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --setup, -s      Only create replication slot (no test data)"
            echo "  --logs, -l       Show NiFi logs after operations"
            echo "  --continuous, -c Perform operations every 5 seconds"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

echo -e "${GREEN}Testing CDC Pattern...${NC}\n"

run_sql() {
    docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "$1"
}

run_sql_quiet() {
    docker exec postgres_cdc psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c "$1"
}

# Check/create replication slot
echo -e "${YELLOW}Checking replication slot...${NC}"
SLOT_EXISTS=$(run_sql_quiet "SELECT EXISTS(SELECT 1 FROM pg_replication_slots WHERE slot_name = 'nifi_cdc_slot');")

if [ "$SLOT_EXISTS" = "f" ]; then
    echo -e "${YELLOW}Creating replication slot 'nifi_cdc_slot'...${NC}"
    run_sql "SELECT * FROM pg_create_logical_replication_slot('nifi_cdc_slot', 'test_decoding');"
    echo -e "${GREEN}✓ Replication slot created${NC}"
else
    echo -e "${GREEN}✓ Replication slot already exists${NC}"
fi

# Show slot info
echo -e "\n${YELLOW}Replication slot info:${NC}"
run_sql "SELECT slot_name, plugin, slot_type, active, restart_lsn FROM pg_replication_slots WHERE slot_name = 'nifi_cdc_slot';"

if [ "$SETUP_ONLY" = "1" ]; then
    echo -e "\n${GREEN}Setup complete. Run without --setup to generate test data.${NC}"
    exit 0
fi

perform_operations() {
    local batch_id=${1:-1}
    
    echo -e "\n${BLUE}=== Batch ${batch_id}: Performing CDC operations ===${NC}\n"
    
    # INSERT
    echo -e "${YELLOW}1. INSERT operation${NC}"
    local customer="CDC User ${batch_id}"
    run_sql "INSERT INTO orders (customer_name, product, quantity, total_amount) VALUES ('${customer}', 'CDC Test Product', 3, 299.99);" > /dev/null
    echo -e "${GREEN}✓${NC} Inserted order for ${CYAN}${customer}${NC}"
    
    # Get the ID
    local last_id=$(run_sql_quiet "SELECT id FROM orders WHERE customer_name = '${customer}' ORDER BY id DESC LIMIT 1;")
    
    # UPDATE
    echo -e "${YELLOW}2. UPDATE operation${NC}"
    run_sql "UPDATE orders SET quantity = 5, total_amount = 499.99 WHERE id = ${last_id};" > /dev/null
    echo -e "${GREEN}✓${NC} Updated order ${CYAN}#${last_id}${NC}"
    
    # Another INSERT
    echo -e "${YELLOW}3. Another INSERT${NC}"
    run_sql "INSERT INTO orders (customer_name, product, quantity, total_amount) VALUES ('CDC User ${batch_id}b', 'Another Product', 1, 49.99);" > /dev/null
    echo -e "${GREEN}✓${NC} Inserted another order"
    
    echo -e "\n${GREEN}Batch ${batch_id} complete${NC}"
}

show_pending_changes() {
    echo -e "\n${YELLOW}Pending CDC changes (peek):${NC}"
    local changes=$(run_sql_quiet "SELECT COUNT(*) FROM pg_logical_slot_peek_changes('nifi_cdc_slot', NULL, 20);")
    echo -e "  Pending changes: ${CYAN}${changes}${NC}"
    
    if [ "$changes" -gt 0 ]; then
        echo -e "\n${YELLOW}Sample changes:${NC}"
        run_sql "SELECT lsn, xid, substring(data, 1, 80) as data_preview FROM pg_logical_slot_peek_changes('nifi_cdc_slot', NULL, 5);"
    fi
}

if [ "$CONTINUOUS" = "1" ]; then
    echo -e "${BLUE}Continuous mode - performing operations every 5 seconds. Press Ctrl+C to stop.${NC}"
    counter=1
    while true; do
        perform_operations $counter
        show_pending_changes
        counter=$((counter + 1))
        echo -e "\n${CYAN}Waiting 5 seconds...${NC}"
        sleep 5
    done
else
    perform_operations 1
    show_pending_changes
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}CDC test operations complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo -e "1. Go to NiFi UI: ${BLUE}https://localhost:8443/nifi${NC}"
    echo -e "2. Start the 'PostgreSQL CDC Pattern' processors"
    echo -e "3. Watch CDC events being processed"
    echo -e "\n${YELLOW}Useful commands:${NC}"
    echo -e "  Watch NiFi logs:  ${CYAN}docker-compose logs -f nifi | grep CDC_CHANGE${NC}"
    echo -e "  Peek changes:     ${CYAN}docker exec postgres_cdc psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"SELECT * FROM pg_logical_slot_peek_changes('nifi_cdc_slot', NULL, 10);\"${NC}"
    echo -e "  Continuous test:  ${CYAN}./test-cdc.sh --continuous${NC}"
    
    echo -e "\n${RED}Important:${NC} CDC changes are ${RED}consumed${NC} when NiFi reads them."
    echo -e "Run this script again after NiFi processes events to generate new ones."
fi

if [ "$SHOW_LOGS" = "1" ]; then
    echo -e "\n${YELLOW}Showing NiFi logs (Ctrl+C to stop)...${NC}\n"
    docker-compose logs -f nifi 2>&1 | grep --line-buffered -E "CDC_CHANGE|LogAttribute"
fi