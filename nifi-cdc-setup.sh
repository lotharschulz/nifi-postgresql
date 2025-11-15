#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Setup script for Apache NiFi CDC Pattern with PostgreSQL
# Coexists with nifi-outbox-setup.sh. Idempotent and order-independent.
# Creates a separate process group and parameter context (names unique).
# Supports DRY_RUN and DEBUG environment variables similar to outbox script.

# debugging options:
# 1)
#  ./nifi-cdc-setup.sh [--dry-run|-n] || echo "Failed with exit code $?"
# 2)
#  export DEBUG=1
#  ./nifi-cdc-setup.sh
#  unset DEBUG
#  ./nifi-cdc-setup.sh

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n)
            DRY_RUN=1
            ;;
    esac
done

# Load environment variables
source .env

# NiFi API base URL
NIFI_URL="https://${NIFI_HOST:-localhost}:${NIFI_PORT:-8443}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting NiFi CDC Pattern Setup...${NC}"
echo -e "${YELLOW}Using NiFi URL: ${NIFI_URL}${NC}"
echo -e "${YELLOW}Using credentials: ${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}${NC}"
echo -e "${YELLOW}PostgreSQL Host: ${POSTGRES_HOST} Port: ${POSTGRES_PORT} DB: ${POSTGRES_DB}${NC}"

if [ "$DRY_RUN" = "1" ]; then
    echo -e "${BLUE}[DRY RUN] No changes will be applied. Showing intended actions only.${NC}"
fi

# Validate required environment variables are present and non-empty
validate_env() {
    echo -e "${YELLOW}Validating required environment variables...${NC}"
    local missing=()
    local placeholder=()
    local required=( \
        NIFI_HOST NIFI_PORT \
        POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
        NIFI_SINGLE_USER_CREDENTIALS_USERNAME NIFI_SINGLE_USER_CREDENTIALS_PASSWORD )

    for var in "${required[@]}"; do
        local val="${!var}"
        if [ -z "$val" ]; then
            missing+=("$var")
            continue
        fi
        # Treat bracketed template values as not yet configured
        if echo "$val" | grep -Eq '^\[.*\]$'; then
            placeholder+=("$var=$val")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing required environment variables:${NC} ${missing[*]}" >&2
        echo -e "Populate them in your .env file (see env-tmplt)." >&2
        exit 1
    fi

    if [ ${#placeholder[@]} -gt 0 ]; then
        echo -e "${RED}The following variables still have placeholder values:${NC}" >&2
        for p in "${placeholder[@]}"; do
            echo " - $p" >&2
        done
        echo -e "Update these with real credentials before running." >&2
        exit 1
    fi

    # Light validation for numeric ports
    if ! echo "$NIFI_PORT" | grep -Eq '^[0-9]+$'; then
        echo -e "${RED}NIFI_PORT must be numeric (current: $NIFI_PORT)${NC}" >&2; exit 1; fi
    if ! echo "$POSTGRES_PORT" | grep -Eq '^[0-9]+$'; then
        echo -e "${RED}POSTGRES_PORT must be numeric (current: $POSTGRES_PORT)${NC}" >&2; exit 1; fi

    echo -e "${GREEN}Environment validation passed.${NC}"
}

log_error_response() {
    local http_code=$1
    local body=$2
    echo -e "${RED}HTTP ${http_code} error${NC}"
    # Try to pretty print JSON if possible
    if command -v jq >/dev/null 2>&1; then
        echo "$body" | jq . 2>/dev/null || echo "$body"
        # Extract common NiFi validation error locations if present
        local validation_errors=$(echo "$body" | jq -r '.component.validationErrors[]?' 2>/dev/null || true)
        if [ -n "$validation_errors" ]; then
            echo -e "${RED}Validation Errors:${NC}"
            echo "$validation_errors" | sed 's/^/ - /'
        fi
    else
        echo "$body"
    fi
}

# Function to wait for NiFi to be ready
wait_for_nifi() {
    echo -e "${YELLOW}Waiting for NiFi to be ready...${NC}"
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${BLUE}[DRY RUN] Skipping NiFi readiness check.${NC}"
        return 0
    fi
    max_attempts=60
    attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -k -s "${NIFI_URL}/nifi-api/system-about" > /dev/null 2>&1; then
            echo -e "${GREEN}NiFi is ready!${NC}"
            return 0
        fi
        echo -n "."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    echo -e "${RED}NiFi failed to start after 5 minutes${NC}"
    return 1
}

# Function to get authentication token
get_auth_token() {
    echo -e "${YELLOW}Getting authentication token...${NC}"
    if [ "$DRY_RUN" = "1" ]; then
        TOKEN="DRY_RUN_TOKEN"
        echo -e "${BLUE}[DRY RUN] Skipping authentication (using synthetic token).${NC}"
        return 0
    fi
    
    TOKEN=$(curl -k -s -X POST "${NIFI_URL}/nifi-api/access/token" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "username=${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}&password=${NIFI_SINGLE_USER_CREDENTIALS_PASSWORD}")
    if [ -z "$TOKEN" ]; then
        echo -e "${RED}Failed to get authentication token${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Token acquired (first 20 chars): ${TOKEN:0:20}...${NC}"
}

# Function to get root process group ID
get_root_pg_id() {
    if [ "$DRY_RUN" = "1" ]; then
        ROOT_PG_ID="dry-root"
        echo -e "${BLUE}[DRY RUN] Synthetic Root Process Group ID: ${ROOT_PG_ID}${NC}"
        return 0
    fi
    ROOT_PG_ID=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | jq -r '.processGroupFlow.id')
    if [ -z "$ROOT_PG_ID" ] || [ "$ROOT_PG_ID" = "null" ]; then
        echo -e "${RED}Failed to get root process group ID${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Root Process Group ID: ${ROOT_PG_ID}${NC}"
}

# Function to create a process group
create_process_group() {
    local parent_id=$1
    local name=$2
    
    local pg_id
    if [ "$DRY_RUN" = "1" ]; then
        pg_id="dry-pg-${name// /-}"
        echo -e "${BLUE}[DRY RUN] Would create process group '${name}' under ${parent_id}. -> ${pg_id}${NC}"
    else
        pg_id=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${parent_id}/process-groups" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"revision\": {\"version\": 0},
                \"component\": {
                    \"name\": \"${name}\",
                    \"position\": {\"x\": 100, \"y\": 100}
                }
            }" | jq -r '.id')
    fi
    
    if [ -z "$pg_id" ] || [ "$pg_id" = "null" ]; then
        echo -e "${RED}Failed to create process group${NC}"
        exit 1
    fi
    
    echo $pg_id
}

find_or_create_param_ctx() {
    local name=$1
    if [ "$DRY_RUN" = 1 ]; then echo "dry-paramctx-${name// /-}"; return 0; fi
    local existing=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/parameter-contexts" -H "Authorization: Bearer ${TOKEN}" | jq -r --arg n "$name" '.parameterContexts[]? | select(.component.name==$n) | .id' | head -1)
    if [ -n "$existing" ]; then echo -e "${GREEN}Reusing parameter context: $existing${NC}"; echo "$existing"; return 0; fi
    echo -e "${YELLOW}Creating parameter context '$name'...${NC}"
    curl -sk -X POST "${NIFI_URL}/nifi-api/parameter-contexts" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
        -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"${name}\",\"parameters\":[{\"parameter\":{\"name\":\"DB_HOST\",\"value\":\"${POSTGRES_HOST}\"}},{\"parameter\":{\"name\":\"DB_PORT\",\"value\":\"${POSTGRES_PORT}\"}},{\"parameter\":{\"name\":\"DB_NAME\",\"value\":\"${POSTGRES_DB}\"}},{\"parameter\":{\"name\":\"DB_USER\",\"value\":\"${POSTGRES_USER}\"}},{\"parameter\":{\"name\":\"DB_PASSWORD\",\"value\":\"${POSTGRES_PASSWORD}\",\"sensitive\":true}}]}}" | jq -r '.id'
}

assign_param_ctx() {
    local pg_id=$1 
    local ctx_id=$2
    echo -c "pg_id: $pg_id"
    echo -c "TOKEN: $TOKEN"
    echo -c "ctx_id: $ctx_id"
    [ "$DRY_RUN" = 1 ] && echo -e "${BLUE}[DRY RUN] Would assign param ctx ${ctx_id} to ${pg_id}.${NC}" && return 0
    local pg_json=$(curl -sk -X GET "${NIFI_URL}/nifi-api/process-groups/${pg_id}" -H "Authorization: Bearer ${TOKEN}")
    local rev=$(echo "$pg_json" | jq -r '.revision.version')
    local cid=$(echo "$pg_json" | jq -r '.revision.clientId // empty')
    local rev_block
    [ -n "$cid" ] && rev_block="{\"version\":${rev},\"clientId\":\"${cid}\"}" || rev_block="{\"version\":${rev}}"
    echo -c "rev_block: $rev_block"
    local response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/process-groups/${pg_id}" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
        -d "{\"revision\":${rev_block},\"component\":{\"id\":\"${pg_id}\",\"parameterContext\":{\"id\":\"${ctx_id}\"}}}" >/dev/null)
    echo -c "response: $response"
    local http_code=${response##*HTTPSTATUS:}
    if [ "$http_code" != "200" ]; then
        echo -e "${YELLOW}Parameter context NOT assigned${NC}" >&2
    else
        echo -e "${GREEN}Parameter context assigned${NC}" >&2
    fi
}

create_processor() {
    local pg_id=$1 type=$2 name=$3 x=$4 y=$5
    if [ "$DRY_RUN" = 1 ]; then
    local mock="dry-proc-${name// /-}-${RANDOM}"
    debug "[DRY] Create processor ${name} -> ${mock}"
    echo "$mock"
    return 0
    fi
    local payload
    payload=$(cat <<EOF
{"revision":{"version":0},"component":{"type":"${type}","name":"${name}","position":{"x":${x},"y":${y}}}}
EOF
    )
    debug "Processor payload: $payload"
    local resp=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/processors" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "$payload" -w ' HTTPSTATUS:%{http_code}')
    local code=${resp##*HTTPSTATUS:}; local body=${resp% HTTPSTATUS:*}
    if [ -n "${DEBUG:-}" ]; then
        debug "Create processor HTTP code=${code} body snippet=$(echo "$body" | head -c 200)"
    fi
    if [ "$code" != 201 ] && [ "$code" != 200 ]; then
        err "Failed to create processor ${name} (HTTP $code)"
        if command -v jq >/dev/null 2>&1; then
            echo "$body" | jq . 2>/dev/null || echo "$body" >&2
        else
            echo "$body" >&2
        fi
        return 1
    fi
    local pid=$(echo "$body" | jq -r '.id')
    if [ -z "$pid" ] || [ "$pid" = "null" ]; then
        err "Processor ${name} created but no ID parsed. Raw body follows:"
        echo "$body" >&2
        return 1
    fi
    echo "$pid"
}

configure_with_retry() {
    local pid=$1 name=$2 config_json=$3
    if [ "$DRY_RUN" = 1 ]; then
        debug "[DRY] Would configure ${name} (processor id ${pid})"
        return 0
    fi
    local attempts=0 max=5
    while [ $attempts -lt $max ]; do
        local st=$(curl -sk -X GET "${NIFI_URL}/nifi-api/processors/${pid}" -H "Authorization: Bearer ${TOKEN}")
        local ver=$(echo "$st" | jq -r '.revision.version')
        local cid=$(echo "$st" | jq -r '.revision.clientId // empty')
        [ -z "$ver" ] && err "No revision for ${name}" && return 1
        # Build PUT payload with jq (avoid embedded escaped JSON issues)
        local full
        full=$(jq -n --arg id "$pid" --arg ver "$ver" --arg cid "$cid" --argjson cfg "$(echo "$config_json" | jq '.component.config')" '
        {revision: ( if $cid != "" then {version: ($ver|tonumber), clientId: $cid} else {version: ($ver|tonumber)} end ),
        component: {id: $id, config: $cfg}}'
        )
        debug "PUT payload for ${name}: $full"
        local resp=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/processors/${pid}" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "$full" -w ' HTTPSTATUS:%{http_code}')
        local code=${resp##*HTTPSTATUS:}; local body=${resp% HTTPSTATUS:*}
        if [ "$code" = 200 ]; then info "Configured ${name}"; return 0; fi
        if echo "$body" | grep -qi 'not the most up-to-date revision'; then attempts=$((attempts+1)); sleep 1; continue; fi
        err "Failed configuring ${name} (HTTP $code)"; echo "$body" >&2; return 1
    done
    err "Exceeded retries configuring ${name}"; return 1
}

# Build config JSON helpers
cfg_capture_change() {
    local dbcp_id=$1 
    slot=$2 
    table_expressions=$3
    jq -n --arg dbcp "$dbcp_id" --arg slot "$slot" --arg exprs "$table_expressions" '{component:{config:{properties:{"Database Connection Pooling Service":$dbcp,"CDC Slot Name":$slot,"Table Include List":$exprs,"Output Format":"Avro"},schedulingPeriod:"30 sec",schedulingStrategy:"TIMER_DRIVEN",executionNode:"PRIMARY",penaltyDuration:"30 sec",yieldDuration:"1 sec",bulletinLevel:"WARN",runDurationMillis:0,concurrentlySchedulableTaskCount:1,autoTerminatedRelationships:["error"],comments:"Captures CDC changes from PostgreSQL logical replication slot"}}}'
}

cfg_route_event() {
    jq -n '{component:{config:{properties:{"Routing Strategy":"Random","Cache Identifier":"cdc-cache"},schedulingPeriod:"0 sec",schedulingStrategy:"TIMER_DRIVEN",executionNode:"ALL",penaltyDuration:"30 sec",yieldDuration:"1 sec",bulletinLevel:"WARN",runDurationMillis:0,concurrentlySchedulableTaskCount:1,autoTerminatedRelationships:["failure"],comments:"Routes CDC events"}}}'
}

# Fallback incremental polling config builder (when CaptureChangePostgreSQL unavailable)
cfg_poll_fallback() {
    local dbcp_id=$1
    jq -n --arg dbcp "$dbcp_id" '{component:{config:{properties:{"Database Connection Pooling Service":$dbcp,"Database Type":"PostgreSQL","Table Name":"outbox","Maximum-value Columns":"id","Fetch Size":"100","Max Rows Per Flow File":"100"},schedulingPeriod:"30 sec",schedulingStrategy:"TIMER_DRIVEN",executionNode:"PRIMARY",penaltyDuration:"30 sec",yieldDuration:"1 sec",bulletinLevel:"WARN",runDurationMillis:0,concurrentlySchedulableTaskCount:1,autoTerminatedRelationships:[],comments:"Fallback incremental polling as CDC substitute"}}}'
}

create_dbcp_service() {
    local pg_id=$1
    [ "$DRY_RUN" = 1 ] && echo "dry-dbcp-${pg_id}" && return 0
    local resp=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/controller-services" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{"revision":{"version":0},"component":{"name":"PostgreSQL Connection Pool (CDC)","type":"org.apache.nifi.dbcp.DBCPConnectionPool","properties":{"Database Connection URL":"jdbc:postgresql://#{DB_HOST}:#{DB_PORT}/#{DB_NAME}","Database Driver Class Name":"org.postgresql.Driver","Database User":"#{DB_USER}","Password":"#{DB_PASSWORD}","Validation query":"SELECT 1"}}}' )
    local id=$(echo "$resp" | jq -r '.id')
    [ -z "$id" ] && err "Failed to create DBCP service" && return 1
    # Enable
    local en=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/controller-services/${id}" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{"revision":{"version":1},"component":{"id":"'"${id}"'","state":"ENABLED"}}' -w ' HTTPSTATUS:%{http_code}')
    if [ -n "${DEBUG:-}" ]; then
        echo -e "${BLUE}[DEBUG] Enable response: $en" >&2
    fi
    echo "$id"
}

main() {
    wait_for_nifi

    get_auth_token
    
    PARAM_CTX_NAME="CDC-DB"

    # Get root process group ID
    get_root_pg_id

    # Idempotent: see if progress group already exists
    echo -e "${YELLOW}Looking for existing 'PostgreSQL CDC Pattern' process group...${NC}"
    PG_ID=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | jq -r '.processGroupFlow.flow.processGroups[]? | select(.component.name=="PostgreSQL CDC Pattern") | .component.id' | head -1)
    if [ -n "$PG_ID" ]; then
        echo -e "${GREEN}Reusing existing process group: ${PG_ID}${NC}"
    else
        echo -e "${YELLOW}Creating Outbox Pattern process group...${NC}"
        PG_ID=$(create_process_group "${ROOT_PG_ID}" "PostgreSQL Outbox Pattern")
        echo -e "${GREEN}Created Process Group: ${PG_ID}${NC}"
    fi

    PARAM_CTX_ID=$(find_or_create_param_ctx "${PARAM_CTX_NAME}")
    assign_param_ctx "${PG_ID}" "${PARAM_CTX_ID}"

    # Create DBCP (CDC specific name, independent of outbox DBCP)
    DBCP_ID=$(create_dbcp_service "${PG_ID}")
    echo -e "${GREEN}DBCP Service (CDC) ID: ${DBCP_ID}${NC}"

    # # Processors
    # # Capture Change (if available else fallback to QueryDatabaseTable incremental pattern)
    # CAPTURE_TYPE="org.apache.nifi.processors.standard.CaptureChangePostgreSQL"
    # # Probe availability (bundle list)
    # available=""
    # if [ "$DRY_RUN" != 1 ]; then
    #     available=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | grep -F "${CAPTURE_TYPE}" || true)
    # else
    #     debug "[DRY] Skipping processor availability probe"
    # fi
    # if [ -n "$available" ]; then
    #     echo -e "${GREEN}Using CaptureChangePostgreSQL processor${NC}"
    # else
    #     echo -e "${YELLOW}CaptureChangePostgreSQL not found; falling back to QueryDatabaseTable for CDC simulation${NC}"
    #     CAPTURE_TYPE="org.apache.nifi.processors.standard.QueryDatabaseTable"
    # fi
    # CAPTURE_ID=""
    # if ! CAPTURE_ID=$(create_processor "${PG_ID}" "${CAPTURE_TYPE}" "CDC Source" 100 100); then
    #     echo -e "${RED}Aborting: could not create CDC Source processor${NC}"
    #     return 1
    # fi
    # if [ -n "${CAPTURE_ID}" ]; then
    #     if [ "${CAPTURE_TYPE}" = "org.apache.nifi.processors.standard.CaptureChangePostgreSQL" ]; then
    #     local SLOT_NAME="${CDC_SLOT_NAME:-outbox_slot}" # env override
    #     local TABLE_INCLUDE="${CDC_TABLE_INCLUDE:-public.outbox}"       # example table list
    #     local cfg=$(cfg_capture_change "${DBCP_ID}" "${SLOT_NAME}" "${TABLE_INCLUDE}")
    #     configure_with_retry "${CAPTURE_ID}" "CDC Source" "${cfg}"
    #     else
    #     # Minimal config for QueryDatabaseTable as CDC fallback
    #     local cfg=$(cfg_poll_fallback "${DBCP_ID}")
    #     configure_with_retry "${CAPTURE_ID}" "CDC Source" "${cfg}"
    #     fi
    # else
    #     echo -e "${RED}CDC Source processor creation failed${NC}"
    # fi

    # # Route events (placeholder for downstream handling)
    # local ROUTE_ID=""
    # if ! ROUTE_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.RouteOnAttribute" "Route CDC Events" 400 100); then
    #     echo -e "${RED}Aborting: could not create Route CDC Events processor${NC}"
    #     return 1
    # fi
    # if [ -n "${ROUTE_ID}" ]; then
    #     local rcfg=$(cfg_route_event)
    #     configure_with_retry "${ROUTE_ID}" "Route CDC Events" "${rcfg}"
    # fi

    # # Connections (only if both processors exist)
    # if [ -n "${CAPTURE_ID}" ] && [ -n "${ROUTE_ID}" ]; then
    #     [ "${DRY_RUN}" = 1 ] && echo -e "${BLUE}[DRY RUN] Would connect CDC Source -> Route CDC Events${NC}" || curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${PG_ID}/connections" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"${CAPTURE_ID}\",\"type\":\"PROCESSOR\",\"groupId\":\"${PG_ID}\"},\"destination\":{\"id\":\"${ROUTE_ID}\",\"type\":\"PROCESSOR\",\"groupId\":\"${PG_ID}\"},\"selectedRelationships\":[\"success\"],\"flowFileExpiration\":\"0 sec\",\"backPressureDataSizeThreshold\":\"1 GB\",\"backPressureObjectThreshold\":10000,\"loadBalanceStrategy\":\"DO_NOT_LOAD_BALANCE\",\"loadBalanceCompression\":\"DO_NOT_COMPRESS\"}}" >/dev/null
    #     echo -e "${GREEN}Connection created (CDC Source -> Route CDC Events)${NC}"
    # fi

    # if [ "$DRY_RUN" = 1 ]; then
    #     echo -e "${YELLOW}Dry-run complete (skipping processor creation & connections).${NC}"
    #     echo -e "${GREEN}NiFi CDC Pattern Setup (dry-run) finished successfully.${NC}"
    #     return 0
    # fi

    # echo -e "${GREEN}NiFi CDC Pattern Setup Complete!${NC}"
    # # Post-run verification: list processors in the PG
    # if command -v jq >/dev/null 2>&1; then
    #     echo -e "${YELLOW}Listing processors in process group (verification):${NC}"
    #     curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/${PG_ID}" -H "Authorization: Bearer ${TOKEN}" \
    #     | jq -r '.processGroupFlow.flow.processors[]? | " - " + .component.name + " (" + .component.id + ")"'
    # else
    #     echo -e "${RED}(jq not found) Raw processor listing:${NC}"
    #     curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/${PG_ID}" -H "Authorization: Bearer ${TOKEN}" | head -c 500 >&2
    # fi
    # echo -e "${YELLOW}Next steps: Access NiFi UI, review 'PostgreSQL CDC Pattern' group, start processors, and link Route CDC Events to your downstream flow.${NC}"
    # return 0
}

main
