#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Test script for Outbox Pattern
# Inserts test orders which trigger outbox events via database trigger

source .env

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
SHOW_LOGS=0
CONTINUOUS=0
for arg in "$@"; do
    case "$arg" in
        --logs|-l) SHOW_LOGS=1 ;;
        --continuous|-c) CONTINUOUS=1 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --logs, -l       Show NiFi logs after inserting data"
            echo "  --continuous, -c Insert data every 5 seconds"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
    esac
done

echo -e "${GREEN}Testing Outbox Pattern...${NC}\n"

run_sql() {
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "$1"
}

run_sql_quiet() {
    docker exec nifi_database psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c "$1"
}

insert_order() {
    local customer=$1 product=$2 quantity=$3 amount=$4
    run_sql "INSERT INTO orders (customer_name, product, quantity, total_amount) VALUES ('${customer}', '${product}', ${quantity}, ${amount});" > /dev/null
    echo -e "${GREEN}✓${NC} Inserted: ${CYAN}${customer}${NC} - ${product} (qty: ${quantity}, \$${amount})"
}

insert_batch() {
    echo -e "${YELLOW}Inserting test orders...${NC}\n"
    
    # Sample data
    insert_order "Alice Johnson" "MacBook Pro 16\"" 1 2499.99
    insert_order "Bob Smith" "Wireless Mouse" 2 79.98
    insert_order "Carol White" "USB-C Hub" 1 49.99
    insert_order "David Brown" "Mechanical Keyboard" 1 149.99
    insert_order "Eve Davis" "Monitor Stand" 2 89.98
    
    echo ""
}

show_status() {
    echo -e "${YELLOW}Current outbox status:${NC}"
    local count=$(run_sql_quiet "SELECT COUNT(*) FROM outbox;")
    echo -e "  Pending events in outbox: ${CYAN}${count}${NC}"
    
    if [ "$count" -gt 0 ]; then
        echo -e "\n${YELLOW}Recent outbox entries:${NC}"
        run_sql "SELECT id, aggregate_type, event_type, aggregate_id, created_at FROM outbox ORDER BY id DESC LIMIT 5;"
    fi
    
    echo -e "\n${YELLOW}Recent orders:${NC}"
    run_sql "SELECT id, customer_name, product, total_amount, created_at FROM orders ORDER BY id DESC LIMIT 5;"
}

if [ "$CONTINUOUS" = "1" ]; then
    echo -e "${BLUE}Continuous mode - inserting data every 5 seconds. Press Ctrl+C to stop.${NC}\n"
    counter=1
    while true; do
        timestamp=$(date +%H:%M:%S)
        insert_order "Customer ${counter}" "Product ${counter}" $((RANDOM % 5 + 1)) "$((RANDOM % 500 + 50)).99"
        echo -e "  ${CYAN}[${timestamp}]${NC} Batch ${counter} complete"
        counter=$((counter + 1))
        sleep 5
    done
else
    insert_batch
    show_status
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Test data inserted!${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo -e "1. Go to NiFi UI: ${BLUE}https://localhost:8443/nifi${NC}"
    echo -e "2. Start the 'PostgreSQL Outbox Pattern' processors"
    echo -e "3. Watch the outbox table get processed"
    echo -e "\n${YELLOW}Useful commands:${NC}"
    echo -e "  Watch NiFi logs:  ${CYAN}docker-compose logs -f nifi | grep OUTBOX_EVENT${NC}"
    echo -e "  Check outbox:     ${CYAN}docker exec nifi_database psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT * FROM outbox;'${NC}"
    echo -e "  Continuous test:  ${CYAN}./test-outbox.sh --continuous${NC}"
fi

if [ "$SHOW_LOGS" = "1" ]; then
    echo -e "\n${YELLOW}Showing NiFi logs (Ctrl+C to stop)...${NC}\n"
    docker-compose logs -f nifi 2>&1 | grep --line-buffered -E "OUTBOX_EVENT|LogAttribute"
fi