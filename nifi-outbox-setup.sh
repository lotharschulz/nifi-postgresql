#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Setup script for Apache NiFi Outbox Pattern with PostgreSQL

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
    esac
done

source .env

NIFI_URL="https://${NIFI_HOST:-localhost}:${NIFI_PORT:-8443}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${YELLOW}Using NiFi URL: ${NIFI_URL}${NC}"
echo -e "${YELLOW}PostgreSQL Host: ${POSTGRES_HOST} Port: ${POSTGRES_PORT} DB: ${POSTGRES_DB}${NC}"

[ "$DRY_RUN" = "1" ] && echo -e "${BLUE}[DRY RUN] No changes will be applied.${NC}"

# ============== Helper Functions ==============

validate_env() {
    echo -e "${YELLOW}Validating required environment variables...${NC}"
    local required=(NIFI_HOST NIFI_PORT POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD NIFI_SINGLE_USER_CREDENTIALS_USERNAME NIFI_SINGLE_USER_CREDENTIALS_PASSWORD)
    for var in "${required[@]}"; do
        [ -z "${!var:-}" ] && { echo -e "${RED}Missing: $var${NC}" >&2; exit 1; }
    done
    echo -e "${GREEN}Environment validation passed.${NC}"
}

wait_for_nifi() {
    echo -e "${YELLOW}Waiting for NiFi to be ready...${NC}"
    [ "$DRY_RUN" = "1" ] && { echo -e "${BLUE}[DRY RUN] Skipping.${NC}"; return 0; }
    for i in {1..60}; do
        curl -k -s "${NIFI_URL}/nifi-api/system-about" > /dev/null 2>&1 && { echo -e "${GREEN}NiFi is ready!${NC}"; return 0; }
        echo -n "."
        sleep 5
    done
    echo -e "${RED}NiFi failed to start${NC}"; return 1
}

get_auth_token() {
    echo -e "${YELLOW}Getting authentication token...${NC}"
    [ "$DRY_RUN" = "1" ] && { TOKEN="DRY_RUN_TOKEN"; return 0; }
    TOKEN=$(curl -k -s -X POST "${NIFI_URL}/nifi-api/access/token" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "username=${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}&password=${NIFI_SINGLE_USER_CREDENTIALS_PASSWORD}")
    [ -z "$TOKEN" ] && { echo -e "${RED}Failed to get token${NC}"; exit 1; }
    echo -e "${GREEN}Token acquired${NC}"
}

get_root_pg_id() {
    [ "$DRY_RUN" = "1" ] && { ROOT_PG_ID="dry-root"; return 0; }
    ROOT_PG_ID=$(curl -sk "${NIFI_URL}/nifi-api/flow/process-groups/root" \
        -H "Authorization: Bearer ${TOKEN}" | jq -r '.processGroupFlow.id')
    echo -e "${GREEN}Root Process Group ID: ${ROOT_PG_ID}${NC}"
}

create_process_group() {
    local parent_id=$1 name=$2
    [ "$DRY_RUN" = "1" ] && { echo "dry-pg-${name// /-}"; return 0; }
    curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${parent_id}/process-groups" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"${name}\",\"position\":{\"x\":600,\"y\":100}}}" | jq -r '.id'
}

create_controller_service() {
    local pg_id=$1 name=$2 type=$3 props=$4
    [ "$DRY_RUN" = "1" ] && { echo "dry-svc-${RANDOM}"; return 0; }
    curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/controller-services" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"${name}\",\"type\":\"${type}\",\"properties\":${props}}}" | jq -r '.id'
}

enable_controller_service() {
    local svc_id=$1 name=$2
    [ "$DRY_RUN" = "1" ] && { echo -e "${BLUE}[DRY RUN] Would enable ${name}${NC}"; return 0; }
    
    for i in {1..10}; do
        local status=$(curl -sk "${NIFI_URL}/nifi-api/controller-services/${svc_id}" \
            -H "Authorization: Bearer ${TOKEN}" | jq -r '.component.validationStatus')
        [ "$status" = "VALID" ] && break
        sleep 1
    done
    
    local rev=$(curl -sk "${NIFI_URL}/nifi-api/controller-services/${svc_id}" \
        -H "Authorization: Bearer ${TOKEN}" | jq -r '.revision.version')
    curl -sk -X PUT "${NIFI_URL}/nifi-api/controller-services/${svc_id}/run-status" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"revision\":{\"version\":${rev}},\"state\":\"ENABLED\"}" > /dev/null
    echo -e "${GREEN}${name} enabled${NC}"
}

create_processor() {
    local pg_id=$1 type=$2 name=$3 x=$4 y=$5
    [ "$DRY_RUN" = "1" ] && { echo "dry-proc-${RANDOM}"; return 0; }
    curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/processors" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"revision\":{\"version\":0},\"component\":{\"type\":\"${type}\",\"name\":\"${name}\",\"position\":{\"x\":${x},\"y\":${y}}}}" | jq -r '.id'
}

configure_processor() {
    local proc_id=$1
    local config_json=$2
    local name=$3
    
    [ "$DRY_RUN" = "1" ] && { echo -e "${BLUE}[DRY RUN] Would configure ${name}${NC}"; return 0; }
    
    sleep 0.5
    local rev=$(curl -sk "${NIFI_URL}/nifi-api/processors/${proc_id}" \
        -H "Authorization: Bearer ${TOKEN}" | jq -r '.revision.version')
    
    local full_config=$(cat <<EOF
{
    "revision": {"version": ${rev}},
    "component": {
        "id": "${proc_id}",
        "config": ${config_json}
    }
}
EOF
)
    
    local response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/processors/${proc_id}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${full_config}" -w "\nHTTP:%{http_code}")
    
    local http_code=$(echo "$response" | tail -1 | sed 's/HTTP://')
    if [ "$http_code" = "200" ]; then
        echo -e "${GREEN}Configured ${name}${NC}"
    else
        echo -e "${RED}Failed to configure ${name} (HTTP ${http_code})${NC}"
        echo "$response" | head -n -1 | jq -r '.message // .' 2>/dev/null || true
    fi
}

create_connection() {
    local src=$1 src_rel=$2 dst=$3 pg_id=$4
    [ "$DRY_RUN" = "1" ] && return 0
    curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/connections" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"${src}\",\"type\":\"PROCESSOR\",\"groupId\":\"${pg_id}\"},\"destination\":{\"id\":\"${dst}\",\"type\":\"PROCESSOR\",\"groupId\":\"${pg_id}\"},\"selectedRelationships\":[\"${src_rel}\"]}}" > /dev/null
}

# ============== Main Setup ==============

main() {
    validate_env
    wait_for_nifi
    get_auth_token
    get_root_pg_id

    # Check/create process group
    echo -e "${YELLOW}Looking for existing 'PostgreSQL Outbox Pattern' process group...${NC}"
    PG_ID=$(curl -sk "${NIFI_URL}/nifi-api/flow/process-groups/root" \
        -H "Authorization: Bearer ${TOKEN}" | \
        jq -r '.processGroupFlow.flow.processGroups[]? | select(.component.name=="PostgreSQL Outbox Pattern") | .component.id' | head -1)
    
    if [ -n "$PG_ID" ] && [ "$PG_ID" != "null" ]; then
        echo -e "${YELLOW}Process group exists. Deleting for clean setup...${NC}"
        curl -sk -X PUT "${NIFI_URL}/nifi-api/flow/process-groups/${PG_ID}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"id":"'${PG_ID}'","state":"STOPPED"}' > /dev/null 2>&1 || true
        sleep 2
        local pg_rev=$(curl -sk "${NIFI_URL}/nifi-api/process-groups/${PG_ID}" \
            -H "Authorization: Bearer ${TOKEN}" | jq -r '.revision.version')
        curl -sk -X DELETE "${NIFI_URL}/nifi-api/process-groups/${PG_ID}?version=${pg_rev}" \
            -H "Authorization: Bearer ${TOKEN}" > /dev/null 2>&1 || true
        sleep 1
    fi
    
    echo -e "${YELLOW}Creating Outbox Pattern process group...${NC}"
    PG_ID=$(create_process_group "${ROOT_PG_ID}" "PostgreSQL Outbox Pattern")
    echo -e "${GREEN}Created Process Group: ${PG_ID}${NC}"

    # Create parameter context
    echo -e "${YELLOW}Creating parameter context...${NC}"
    PARAM_CTX_ID=$(curl -sk "${NIFI_URL}/nifi-api/flow/parameter-contexts" \
        -H "Authorization: Bearer ${TOKEN}" | \
        jq -r '.parameterContexts[]? | select(.component.name=="Outbox-DB") | .id' | head -1)
    
    if [ -z "$PARAM_CTX_ID" ] || [ "$PARAM_CTX_ID" = "null" ]; then
        PARAM_CTX_ID=$(curl -sk -X POST "${NIFI_URL}/nifi-api/parameter-contexts" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"Outbox-DB\",\"parameters\":[
                {\"parameter\":{\"name\":\"DB_HOST\",\"value\":\"postgres\"}},
                {\"parameter\":{\"name\":\"DB_PORT\",\"value\":\"5432\"}},
                {\"parameter\":{\"name\":\"DB_NAME\",\"value\":\"${POSTGRES_DB}\"}},
                {\"parameter\":{\"name\":\"DB_USER\",\"value\":\"${POSTGRES_USER}\"}},
                {\"parameter\":{\"name\":\"DB_PASSWORD\",\"value\":\"${POSTGRES_PASSWORD}\",\"sensitive\":true}}
            ]}}" | jq -r '.id')
        echo -e "${GREEN}Created parameter context: ${PARAM_CTX_ID}${NC}"
    fi

    # Assign parameter context
    local pg_rev=$(curl -sk "${NIFI_URL}/nifi-api/process-groups/${PG_ID}" \
        -H "Authorization: Bearer ${TOKEN}" | jq -r '.revision.version')
    curl -sk -X PUT "${NIFI_URL}/nifi-api/process-groups/${PG_ID}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"revision\":{\"version\":${pg_rev}},\"component\":{\"id\":\"${PG_ID}\",\"parameterContext\":{\"id\":\"${PARAM_CTX_ID}\"}}}" > /dev/null
    echo -e "${GREEN}Parameter context assigned${NC}"

    # Create Controller Services
    echo -e "${YELLOW}Creating controller services...${NC}"
    
    DBCP_PROPS='{"Database Connection URL":"jdbc:postgresql://#{DB_HOST}:#{DB_PORT}/#{DB_NAME}","Database Driver Class Name":"org.postgresql.Driver","database-driver-locations":"/opt/nifi/nifi-current/lib/postgresql-42.7.8.jar","Database User":"#{DB_USER}","Password":"#{DB_PASSWORD}","Max Total Connections":"8","Validation query":"SELECT 1"}'
    DBCP_ID=$(create_controller_service "$PG_ID" "PostgreSQL Connection Pool" "org.apache.nifi.dbcp.DBCPConnectionPool" "$DBCP_PROPS")
    echo -e "${GREEN}Created DBCP: ${DBCP_ID}${NC}"
    
    AVRO_READER_ID=$(create_controller_service "$PG_ID" "Avro Record Reader" "org.apache.nifi.avro.AvroReader" '{}')
    echo -e "${GREEN}Created Avro Reader: ${AVRO_READER_ID}${NC}"
    
    JSON_WRITER_PROPS='{"Pretty Print JSON":"false","Schema Write Strategy":"no-schema","output-grouping":"output-array"}'
    JSON_WRITER_ID=$(create_controller_service "$PG_ID" "JSON Record Writer" "org.apache.nifi.json.JsonRecordSetWriter" "$JSON_WRITER_PROPS")
    echo -e "${GREEN}Created JSON Writer: ${JSON_WRITER_ID}${NC}"

    # Enable controller services
    sleep 2
    enable_controller_service "$DBCP_ID" "Database Connection Pool"
    enable_controller_service "$AVRO_READER_ID" "Avro Record Reader"
    enable_controller_service "$JSON_WRITER_ID" "JSON Record Writer"

    # Create Processors
    echo -e "${YELLOW}Creating processors...${NC}"
    
    # 1. QueryDatabaseTable - Poll outbox table
    QUERY_ID=$(create_processor "$PG_ID" "org.apache.nifi.processors.standard.QueryDatabaseTable" "Poll Outbox Table" 400 100)
    QUERY_CONFIG=$(cat <<EOF
{
    "properties": {
        "Database Connection Pooling Service": "${DBCP_ID}",
        "Database Type": "PostgreSQL",
        "Table Name": "outbox",
        "Columns to Return": "id,aggregate_type,aggregate_id,event_type,payload,created_at",
        "Maximum-value Columns": "id",
        "Max Rows Per Flow File": "100",
        "Output Format": "Avro"
    },
    "schedulingPeriod": "10 sec",
    "schedulingStrategy": "TIMER_DRIVEN",
    "executionNode": "PRIMARY",
    "autoTerminatedRelationships": ["failure"]
}
EOF
)
    configure_processor "$QUERY_ID" "$QUERY_CONFIG" "QueryDatabaseTable"
    
    # 2. ConvertRecord - Avro to JSON
    CONVERT_ID=$(create_processor "$PG_ID" "org.apache.nifi.processors.standard.ConvertRecord" "Convert to JSON" 400 250)
    CONVERT_CONFIG=$(cat <<EOF
{
    "properties": {
        "Record Reader": "${AVRO_READER_ID}",
        "Record Writer": "${JSON_WRITER_ID}"
    },
    "schedulingPeriod": "0 sec",
    "autoTerminatedRelationships": ["failure"]
}
EOF
)
    configure_processor "$CONVERT_ID" "$CONVERT_CONFIG" "ConvertRecord"
    
    # 3. SplitJson
    SPLIT_ID=$(create_processor "$PG_ID" "org.apache.nifi.processors.standard.SplitJson" "Split Events" 400 400)
    SPLIT_CONFIG=$(cat <<EOF
{
    "properties": {
        "JsonPath Expression": "\$[*]"
    },
    "schedulingPeriod": "0 sec",
    "autoTerminatedRelationships": ["failure", "original"]
}
EOF
)
    configure_processor "$SPLIT_ID" "$SPLIT_CONFIG" "SplitJson"
    
    # 4. EvaluateJsonPath - Extract event metadata
    EVAL_ID=$(create_processor "$PG_ID" "org.apache.nifi.processors.standard.EvaluateJsonPath" "Extract Event Metadata" 400 550)
    EVAL_CONFIG=$(cat <<EOF
{
    "properties": {
        "Destination": "flowfile-attribute",
        "event.id": "\$.id",
        "event.aggregate_type": "\$.aggregate_type",
        "event.aggregate_id": "\$.aggregate_id",
        "event.event_type": "\$.event_type",
        "event.created_at": "\$.created_at"
    },
    "schedulingPeriod": "0 sec",
    "autoTerminatedRelationships": ["failure", "unmatched"]
}
EOF
)
    configure_processor "$EVAL_ID" "$EVAL_CONFIG" "EvaluateJsonPath"
    
    # 5. LogAttribute - Log events (placeholder for message broker)
    LOG_ID=$(create_processor "$PG_ID" "org.apache.nifi.processors.standard.LogAttribute" "Publish Events (Log)" 600 550)
    LOG_CONFIG=$(cat <<EOF
{
    "properties": {
        "Log Level": "info",
        "Log Payload": "true",
        "Attributes to Log": "event.*",
        "Log Prefix": "OUTBOX_EVENT"
    },
    "schedulingPeriod": "0 sec",
    "autoTerminatedRelationships": ["success"]
}
EOF
)
    configure_processor "$LOG_ID" "$LOG_CONFIG" "LogAttribute"
    
    # 6. PutSQL - Delete processed events
    PUT_SQL_ID=$(create_processor "$PG_ID" "org.apache.nifi.processors.standard.PutSQL" "Delete from Outbox" 400 700)
    PUT_SQL_CONFIG=$(cat <<EOF
{
    "properties": {
        "JDBC Connection Pool": "${DBCP_ID}",
        "SQL Statement": "DELETE FROM outbox WHERE id = \${event.id}",
        "Support Fragmented Transactions": "false"
    },
    "schedulingPeriod": "0 sec",
    "autoTerminatedRelationships": ["success", "failure", "retry"]
}
EOF
)
    configure_processor "$PUT_SQL_ID" "$PUT_SQL_CONFIG" "PutSQL"

    # Create connections
    echo -e "${YELLOW}Creating connections...${NC}"
    create_connection "$QUERY_ID" "success" "$CONVERT_ID" "$PG_ID"
    create_connection "$CONVERT_ID" "success" "$SPLIT_ID" "$PG_ID"
    create_connection "$SPLIT_ID" "split" "$EVAL_ID" "$PG_ID"
    create_connection "$EVAL_ID" "matched" "$LOG_ID" "$PG_ID"
    create_connection "$EVAL_ID" "matched" "$PUT_SQL_ID" "$PG_ID"
    echo -e "${GREEN}All connections created${NC}"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}NiFi Outbox Pattern Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo -e "1. Start the flow in NiFi UI"
    echo -e "2. Generate test data:"
    echo -e "   ${BLUE}./test-outbox.sh${NC}"
}

main