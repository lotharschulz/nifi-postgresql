#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Setup script for Apache NiFi CDC Pattern with PostgreSQL Logical Replication
# This script configures NiFi flow using REST API with token-based authentication

# Dry run flag (no changes applied to NiFi when enabled)
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

# ---------------- Helper utilities (reused from outbox script) -----------------

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
        if echo "$val" | grep -Eq '^\[.*\]$'; then
            placeholder+=("$var=$val")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing required environment variables:${NC} ${missing[*]}" >&2
        exit 1
    fi

    if [ ${#placeholder[@]} -gt 0 ]; then
        echo -e "${RED}The following variables still have placeholder values:${NC}" >&2
        for p in "${placeholder[@]}"; do
            echo " - $p" >&2
        done
        exit 1
    fi

    if ! echo "$NIFI_PORT" | grep -Eq '^[0-9]+$'; then
        echo -e "${RED}NIFI_PORT must be numeric${NC}" >&2; exit 1; fi
    if ! echo "$POSTGRES_PORT" | grep -Eq '^[0-9]+$'; then
        echo -e "${RED}POSTGRES_PORT must be numeric${NC}" >&2; exit 1; fi

    echo -e "${GREEN}Environment validation passed.${NC}"
}

log_error_response() {
    local http_code=$1
    local body=$2
    echo -e "${RED}HTTP ${http_code} error${NC}"
    if command -v jq >/dev/null 2>&1; then
        echo "$body" | jq . 2>/dev/null || echo "$body"
    else
        echo "$body"
    fi
}

is_revision_conflict() {
    local http_code=$1
    local body=$2
    if echo "$body" | grep -qi "not the most up-to-date revision"; then
        return 0
    fi
    if [ "$http_code" = "409" ]; then
        return 0
    fi
    return 1
}

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
    
    echo -e "${GREEN}Token acquired${NC}"
}

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

create_process_group() {
    local parent_id=$1
    local name=$2
    
    local pg_id
    if [ "$DRY_RUN" = "1" ]; then
        pg_id="dry-pg-${name// /-}"
        echo -e "${BLUE}[DRY RUN] Would create process group '${name}' -> ${pg_id}${NC}"
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

create_dbcp_service() {
    local pg_id=$1
    
    echo -e "${YELLOW}Creating Database Connection Pool...${NC}" >&2
    
    local dbcp_id
    if [ "$DRY_RUN" = "1" ]; then
        dbcp_id="dry-dbcp-${pg_id}"
        echo -e "${BLUE}[DRY RUN] Would create DBCP controller service -> ${dbcp_id}${NC}" >&2
    else
        dbcp_id=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/controller-services" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"revision\": {\"version\": 0},
                \"component\": {
                    \"name\": \"PostgreSQL Connection Pool\",
                    \"type\": \"org.apache.nifi.dbcp.DBCPConnectionPool\",
                    \"properties\": {
                        \"Database Connection URL\": \"jdbc:postgresql://#{DB_HOST}:#{DB_PORT}/#{DB_NAME}\",
                        \"Database Driver Class Name\": \"org.postgresql.Driver\",
                        \"Database User\": \"#{DB_USER}\",
                        \"Password\": \"#{DB_PASSWORD}\",
                        \"Max Total Connections\": \"8\",
                        \"Max Idle Connections\": \"0\",
                        \"Validation query\": \"SELECT 1\"
                    }
                }
            }" | jq -r '.id')
    fi
    
    if [ -z "$dbcp_id" ] || [ "$dbcp_id" = "null" ]; then
        echo -e "${RED}Failed to create Database Connection Pool${NC}"
        exit 1
    fi
    
    echo "$dbcp_id"
}

create_processor() {
    local pg_id=$1
    local type=$2
    local name=$3
    local x=$4
    local y=$5
    
    if [ "$DRY_RUN" = "1" ]; then
        local fake_id="dry-proc-${RANDOM}"
        echo -e "${BLUE}[DRY RUN] Would create processor '${name}' -> ${fake_id}${NC}"
        echo "$fake_id"
        return 0
    fi

    local payload=$(cat <<EOF
{
    "revision": {"version": 0},
    "component": {
        "type": "${type}",
        "name": "${name}",
        "position": {"x": ${x}, "y": ${y}}
    }
}
EOF
)
    local response=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/processors" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" -w " HTTPSTATUS:%{http_code}")
    local http_code=${response##*HTTPSTATUS:}
    local body=${response% HTTPSTATUS:*}
    if [ "$http_code" != "201" ] && [ "$http_code" != "200" ]; then
        echo -e "${RED}Failed to create processor '${name}' (HTTP ${http_code})${NC}" >&2
        log_error_response "$http_code" "$body"
        return 1
    fi
    echo "$body" | jq -r '.id'
}

configure_processor_with_retry() {
    local processor_id=$1
    local config_json=$2
    local processor_name=$3

    local max_attempts=5
    local attempt=1
    local success=false

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${BLUE}[DRY RUN] Would configure processor ${processor_name} (${processor_id}).${NC}"
        return 0
    fi

    while [ $attempt -le $max_attempts ]; do
        local proc_state=$(curl -sk -X GET "${NIFI_URL}/nifi-api/processors/${processor_id}" \
            -H "Authorization: Bearer ${TOKEN}")
        local rev_version=$(echo "$proc_state" | jq -r '.revision.version')
        local rev_client_id=$(echo "$proc_state" | jq -r '.revision.clientId // empty')

        if [ -z "$rev_version" ] || [ "$rev_version" = "null" ]; then
            echo -e "${RED}Could not obtain revision for ${processor_name}${NC}"
            break
        fi

        local full_config
        if command -v jq >/dev/null 2>&1; then
            if [ -n "$rev_client_id" ]; then
                full_config=$(jq -n \
                    --arg id "$processor_id" \
                    --argjson config "$(echo "$config_json" | jq '.component.config')" \
                    --argjson rev "$(jq -n --arg ver "$rev_version" --arg cid "$rev_client_id" '{version: ($ver|tonumber), clientId: $cid}')" \
                    '{revision: $rev, component: {id: $id, config: $config}}')
            else
                full_config=$(jq -n \
                    --arg id "$processor_id" \
                    --argjson config "$(echo "$config_json" | jq '.component.config')" \
                    --argjson rev "$(jq -n --arg ver "$rev_version" '{version: ($ver|tonumber)}')" \
                    '{revision: $rev, component: {id: $id, config: $config}}')
            fi
        else
            local config_block=$(echo "$config_json" | jq -r '.component.config')
            full_config="{\"revision\":{\"version\":${rev_version}},\"component\":{\"id\":\"${processor_id}\",\"config\":${config_block}}}"
        fi

        local response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/processors/${processor_id}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${full_config}" \
            -w " HTTPSTATUS:%{http_code}")

        local http_code=${response##*HTTPSTATUS:}
        local body=${response% HTTPSTATUS:*}

        if [ "$http_code" = "200" ]; then
            echo -e "${GREEN}Successfully configured ${processor_name}${NC}"
            success=true
            break
        fi

        if is_revision_conflict "$http_code" "$body"; then
            echo -e "${YELLOW}Revision conflict for ${processor_name}; retrying (${attempt}/${max_attempts})...${NC}"
            attempt=$((attempt + 1))
            sleep 1
            continue
        fi

        echo -e "${RED}Failed configuring ${processor_name} (HTTP ${http_code})${NC}"
        log_error_response "$http_code" "$body"
        break
    done

    if [ "$success" != true ]; then
        echo -e "${RED}Failed to configure ${processor_name} after $attempt attempts${NC}"
        exit 1
    fi
}

create_connection() {
    local source_id=$1
    local source_type=$2
    local source_relationship=$3
    local dest_id=$4
    local dest_type=$5
    local pg_id=$6
    
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${BLUE}[DRY RUN] Would connect ${source_id} (${source_relationship}) -> ${dest_id}.${NC}"
    else
        curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/connections" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"revision\": {\"version\": 0},
                \"component\": {
                    \"source\": {
                        \"id\": \"${source_id}\",
                        \"type\": \"${source_type}\",
                        \"groupId\": \"${pg_id}\"
                    },
                    \"destination\": {
                        \"id\": \"${dest_id}\",
                        \"type\": \"${dest_type}\",
                        \"groupId\": \"${pg_id}\"
                    },
                    \"selectedRelationships\": [\"${source_relationship}\"],
                    \"flowFileExpiration\": \"0 sec\",
                    \"backPressureDataSizeThreshold\": \"1 GB\",
                    \"backPressureObjectThreshold\": \"10000\",
                    \"loadBalanceStrategy\": \"DO_NOT_LOAD_BALANCE\",
                    \"loadBalanceCompression\": \"DO_NOT_COMPRESS\"
                }
            }" > /dev/null
    fi
}

# ---------------- CDC-specific configuration functions -----------------

configure_execute_sql_processor() {
    local processor_id=$1
    local dbcp_id=$2
    
    local config
    if command -v jq >/dev/null 2>&1; then
        config=$(jq -n \
            --arg dbcp_id "$dbcp_id" \
            '{
                component: {
                    config: {
                        properties: {
                            "Database Connection Pooling Service": $dbcp_id,
                            "SQL select query": "SELECT * FROM pg_logical_slot_get_changes('"'"'nifi_cdc_slot'"'"', NULL, NULL, '"'"'include-timestamp'"'"', '"'"'on'"'"');",
                            "Max Wait Time": "0 seconds",
                            "Output Batch Size": "100"
                        },
                        schedulingPeriod: "5 sec",
                        schedulingStrategy: "TIMER_DRIVEN",
                        executionNode: "PRIMARY",
                        penaltyDuration: "30 sec",
                        yieldDuration: "1 sec",
                        bulletinLevel: "WARN",
                        runDurationMillis: 0,
                        concurrentlySchedulableTaskCount: 1,
                        autoTerminatedRelationships: [],
                        comments: "Queries PostgreSQL logical replication slot for CDC events"
                    }
                }
            }')
    else
        config="{\"component\":{\"config\":{\"properties\":{\"Database Connection Pooling Service\":\"${dbcp_id}\",\"SQL select query\":\"SELECT * FROM pg_logical_slot_get_changes('nifi_cdc_slot', NULL, NULL, 'include-timestamp', 'on');\",\"Max Wait Time\":\"0 seconds\",\"Output Batch Size\":\"100\"},\"schedulingPeriod\":\"5 sec\",\"schedulingStrategy\":\"TIMER_DRIVEN\",\"executionNode\":\"PRIMARY\",\"penaltyDuration\":\"30 sec\",\"yieldDuration\":\"1 sec\",\"bulletinLevel\":\"WARN\",\"runDurationMillis\":0,\"concurrentlySchedulableTaskCount\":1,\"autoTerminatedRelationships\":[],\"comments\":\"Queries PostgreSQL logical replication slot for CDC events\"}}}"
    fi
    
    configure_processor_with_retry "$processor_id" "$config" "ExecuteSQL"
}

create_avro_reader_service() {
    local pg_id=$1
    
    echo -e "${YELLOW}Creating Avro Record Reader...${NC}" >&2
    
    local reader_id
    if [ "$DRY_RUN" = "1" ]; then
        reader_id="dry-avro-reader-${pg_id}"
        echo -e "${BLUE}[DRY RUN] Would create Avro reader service -> ${reader_id}${NC}" >&2
    else
        reader_id=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/controller-services" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"revision\": {\"version\": 0},
                \"component\": {
                    \"name\": \"Avro Record Reader\",
                    \"type\": \"org.apache.nifi.avro.AvroReader\",
                    \"properties\": {}
                }
            }" | jq -r '.id')
    fi
    
    if [ -z "$reader_id" ] || [ "$reader_id" = "null" ]; then
        echo -e "${RED}Failed to create Avro Record Reader${NC}"
        exit 1
    fi
    
    echo "$reader_id"
}

create_json_writer_service() {
    local pg_id=$1
    
    echo -e "${YELLOW}Creating JSON Record Writer...${NC}" >&2
    
    local writer_id
    if [ "$DRY_RUN" = "1" ]; then
        writer_id="dry-json-writer-${pg_id}"
        echo -e "${BLUE}[DRY RUN] Would create JSON writer service -> ${writer_id}${NC}" >&2
    else
        writer_id=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/controller-services" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"revision\": {\"version\": 0},
                \"component\": {
                    \"name\": \"JSON Record Writer\",
                    \"type\": \"org.apache.nifi.json.JsonRecordSetWriter\",
                    \"properties\": {
                        \"Pretty Print JSON\": \"false\",
                        \"Schema Write Strategy\": \"no-schema\",
                        \"output-grouping\": \"output-array\"
                    }
                }
            }" | jq -r '.id')
    fi
    
    if [ -z "$writer_id" ] || [ "$writer_id" = "null" ]; then
        echo -e "${RED}Failed to create JSON Record Writer${NC}"
        exit 1
    fi
    
    echo "$writer_id"
}

enable_controller_service() {
    local service_id=$1
    local service_name=$2
    
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${BLUE}[DRY RUN] Would enable controller service ${service_id}${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Enabling ${service_name}...${NC}"
    
    # Get current revision
    local svc_state=$(curl -sk -X GET "${NIFI_URL}/nifi-api/controller-services/${service_id}" \
        -H "Authorization: Bearer ${TOKEN}")
    local rev_version=$(echo "$svc_state" | jq -r '.revision.version')
    
    curl -sk -X PUT "${NIFI_URL}/nifi-api/controller-services/${service_id}/run-status" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"revision\": {\"version\": ${rev_version}},
            \"state\": \"ENABLED\"
        }" > /dev/null
    
    echo -e "${GREEN}${service_name} enabled${NC}"
}

configure_convert_record_processor() {
    local processor_id=$1
    local reader_id=$2
    local writer_id=$3
    
    local config
    if command -v jq >/dev/null 2>&1; then
        config=$(jq -n \
            --arg reader_id "$reader_id" \
            --arg writer_id "$writer_id" \
            '{
                component: {
                    config: {
                        properties: {
                            "record-reader": $reader_id,
                            "record-writer": $writer_id
                        },
                        schedulingPeriod: "0 sec",
                        schedulingStrategy: "TIMER_DRIVEN",
                        executionNode: "ALL",
                        penaltyDuration: "30 sec",
                        yieldDuration: "1 sec",
                        bulletinLevel: "WARN",
                        runDurationMillis: 0,
                        concurrentlySchedulableTaskCount: 1,
                        autoTerminatedRelationships: ["failure"],
                        comments: "Converts Avro to JSON for processing"
                    }
                }
            }')
    else
        config="{\"component\":{\"config\":{\"properties\":{\"record-reader\":\"${reader_id}\",\"record-writer\":\"${writer_id}\"},\"schedulingPeriod\":\"0 sec\",\"schedulingStrategy\":\"TIMER_DRIVEN\",\"executionNode\":\"ALL\",\"penaltyDuration\":\"30 sec\",\"yieldDuration\":\"1 sec\",\"bulletinLevel\":\"WARN\",\"runDurationMillis\":0,\"concurrentlySchedulableTaskCount\":1,\"autoTerminatedRelationships\":[\"failure\"],\"comments\":\"Converts Avro to JSON for processing\"}}}"
    fi
    
    configure_processor_with_retry "$processor_id" "$config" "ConvertRecord"
}

configure_split_json_processor() {
    local processor_id=$1
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"JsonPath Expression\": \"\$[*]\",
                    \"Null Value Representation\": \"empty string\"
                },
                \"schedulingPeriod\": \"0 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"ALL\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [\"failure\", \"original\"],
                \"comments\": \"Splits CDC changes into individual events\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "SplitJson"
}

configure_parse_cdc_processor() {
    local processor_id=$1
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"Destination\": \"flowfile-attribute\",
                    \"Return Type\": \"auto-detect\",
                    \"Path Not Found Behavior\": \"warn\",
                    \"Null Value Representation\": \"empty string\",
                    \"cdc.lsn\": \"\$.lsn\",
                    \"cdc.xid\": \"\$.xid\",
                    \"cdc.data\": \"\$.data\"
                },
                \"schedulingPeriod\": \"0 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"ALL\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [\"failure\", \"unmatched\"],
                \"comments\": \"Extracts CDC metadata from logical replication output\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "EvaluateJsonPath"
}

configure_route_cdc_processor() {
    local processor_id=$1
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"Routing Strategy\": \"Route to Property name\",
                    \"has_changes\": \"\${cdc.data:isEmpty():not()}\"
                },
                \"schedulingPeriod\": \"0 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"ALL\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [\"unmatched\"],
                \"comments\": \"Routes only events with CDC data\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "RouteOnAttribute"
}

configure_log_processor() {
    local processor_id=$1
    local prefix=$2
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"Log Level\": \"info\",
                    \"Log Payload\": \"true\",
                    \"Attributes to Log\": \"cdc.*\",
                    \"Log prefix\": \"${prefix}\"
                },
                \"schedulingPeriod\": \"0 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"ALL\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [\"success\"],
                \"comments\": \"Logs CDC changes from logical replication\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "LogAttribute"
}

# Main setup flow
main() {
    validate_env

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${BLUE}[DRY RUN] Short-circuiting NiFi API calls${NC}"
        ROOT_PG_ID="dry-root"
        PG_ID="dry-pg-PostgreSQL-CDC-Pattern"
        PARAM_CTX_ID="dry-paramctx-CDC-DB"
        DBCP_ID="dry-dbcp-${PG_ID}"
        AVRO_READER_ID="dry-avro-reader-${PG_ID}"
        JSON_WRITER_ID="dry-json-writer-${PG_ID}"
    else
        wait_for_nifi
        get_auth_token
        get_root_pg_id

        # Check for existing process group
        echo -e "${YELLOW}Looking for existing 'PostgreSQL CDC Pattern' process group...${NC}"
        PG_ID=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | jq -r '.processGroupFlow.flow.processGroups[]? | select(.component.name=="PostgreSQL CDC Pattern") | .component.id' | head -1)
        if [ -n "$PG_ID" ]; then
            echo -e "${GREEN}Reusing existing process group: ${PG_ID}${NC}"
        else
            echo -e "${YELLOW}Creating CDC Pattern process group...${NC}"
            PG_ID=$(create_process_group "${ROOT_PG_ID}" "PostgreSQL CDC Pattern")
            echo -e "${GREEN}Created Process Group: ${PG_ID}${NC}"
        fi

        # Create parameter context
        echo -e "${YELLOW}Ensuring parameter context 'CDC-DB' exists...${NC}"
        PARAM_CTX_ID=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/parameter-contexts" -H "Authorization: Bearer ${TOKEN}" | jq -r '.parameterContexts[]? | select(.component.name=="CDC-DB") | .id' | head -1)
        if [ -z "$PARAM_CTX_ID" ]; then
            PARAM_CTX_ID=$(curl -sk -X POST "${NIFI_URL}/nifi-api/parameter-contexts" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"revision\": {\"version\": 0},
                    \"component\": {
                        \"name\": \"CDC-DB\",
                        \"parameters\": [
                            {\"parameter\": {\"name\": \"DB_HOST\", \"value\": \"${POSTGRES_HOST}\"}},
                            {\"parameter\": {\"name\": \"DB_PORT\", \"value\": \"${POSTGRES_PORT}\"}},
                            {\"parameter\": {\"name\": \"DB_NAME\", \"value\": \"${POSTGRES_DB}\"}},
                            {\"parameter\": {\"name\": \"DB_USER\", \"value\": \"${POSTGRES_USER}\"}},
                            {\"parameter\": {\"name\": \"DB_PASSWORD\", \"value\": \"${POSTGRES_PASSWORD}\", \"sensitive\": true}}
                        ]
                    }
                }" | jq -r '.id')
            echo -e "${GREEN}Created parameter context: ${PARAM_CTX_ID}${NC}"
        else
            echo -e "${GREEN}Reusing parameter context: ${PARAM_CTX_ID}${NC}"
        fi

        # Assign parameter context to process group
        PG_ENTITY=$(curl -sk -X GET "${NIFI_URL}/nifi-api/process-groups/${PG_ID}" -H "Authorization: Bearer ${TOKEN}")
        PG_REV=$(echo "$PG_ENTITY" | jq -r '.revision.version')
        PG_CLIENT_ID=$(echo "$PG_ENTITY" | jq -r '.revision.clientId // empty')
        if [ -n "$PG_CLIENT_ID" ]; then
            PG_REV_BLOCK="{\"version\": ${PG_REV}, \"clientId\": \"${PG_CLIENT_ID}\"}"
        else
            PG_REV_BLOCK="{\"version\": ${PG_REV}}"
        fi
        curl -sk -X PUT "${NIFI_URL}/nifi-api/process-groups/${PG_ID}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{ \"revision\": ${PG_REV_BLOCK}, \"component\": { \"id\": \"${PG_ID}\", \"parameterContext\": { \"id\": \"${PARAM_CTX_ID}\" } } }" >/dev/null
        echo -e "${GREEN}Parameter context assigned to process group.${NC}"

        # Create Database Connection Pool
        DBCP_ID=$(create_dbcp_service "${PG_ID}")
        echo -e "${GREEN}Created Database Connection Pool: ${DBCP_ID}${NC}"
        
        # Create Record Reader and Writer services
        AVRO_READER_ID=$(create_avro_reader_service "${PG_ID}")
        echo -e "${GREEN}Created Avro Record Reader: ${AVRO_READER_ID}${NC}"
        
        JSON_WRITER_ID=$(create_json_writer_service "${PG_ID}")
        echo -e "${GREEN}Created JSON Record Writer: ${JSON_WRITER_ID}${NC}"
        
        # Enable controller services
        enable_controller_service "${DBCP_ID}" "Database Connection Pool"
        enable_controller_service "${AVRO_READER_ID}" "Avro Record Reader"
        enable_controller_service "${JSON_WRITER_ID}" "JSON Record Writer"
    fi
    
    # Create processors
    echo -e "${YELLOW}Creating CDC processors...${NC}"
    
    # Check if processors already exist
    echo -e "${YELLOW}Checking for existing processors...${NC}"
    EXISTING_PROCS=$(curl -sk -X GET "${NIFI_URL}/nifi-api/process-groups/${PG_ID}/processors" -H "Authorization: Bearer ${TOKEN}" | jq -r '.processors[]?.component.name' 2>/dev/null || echo "")
    
    if echo "$EXISTING_PROCS" | grep -q "Read CDC Slot"; then
        echo -e "${YELLOW}Processors already exist in this process group. Skipping creation.${NC}"
        echo -e "${GREEN}To reconfigure, delete the process group and run the script again.${NC}"
        exit 0
    fi
    
    # 1. ExecuteSQL - Query logical replication slot
    CDC_EXECUTE_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.ExecuteSQL" "Read CDC Slot" 1200 100)
    if [ -z "$CDC_EXECUTE_ID" ] || [ "$CDC_EXECUTE_ID" = "null" ]; then
        echo -e "${RED}Failed to create ExecuteSQL${NC}" >&2
    else
        configure_execute_sql_processor "${CDC_EXECUTE_ID}" "${DBCP_ID}"
        echo -e "${GREEN}Configured ExecuteSQL processor${NC}"
    fi
    
    # 2. ConvertRecord - Convert result to JSON
    CONVERT_JSON_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.ConvertRecord" "Convert to JSON" 1200 300)
    if [ -z "$CONVERT_JSON_ID" ] || [ "$CONVERT_JSON_ID" = "null" ]; then
        echo -e "${RED}Failed to create ConvertRecord${NC}" >&2
    else
        configure_convert_record_processor "${CONVERT_JSON_ID}" "${AVRO_READER_ID}" "${JSON_WRITER_ID}"
        echo -e "${GREEN}Configured ConvertRecord processor${NC}"
    fi
    
    # 3. SplitJson - Split into individual changes
    SPLIT_JSON_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.SplitJson" "Split Changes" 1200 500)
    if [ -z "$SPLIT_JSON_ID" ] || [ "$SPLIT_JSON_ID" = "null" ]; then
        echo -e "${RED}Failed to create SplitJson${NC}" >&2
    else
        configure_split_json_processor "${SPLIT_JSON_ID}"
        echo -e "${GREEN}Configured SplitJson processor${NC}"
    fi
    
    # 4. EvaluateJsonPath - Parse CDC event
    PARSE_CDC_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.EvaluateJsonPath" "Parse CDC Data" 1200 700)
    if [ -z "$PARSE_CDC_ID" ] || [ "$PARSE_CDC_ID" = "null" ]; then
        echo -e "${RED}Failed to create EvaluateJsonPath${NC}" >&2
    else
        configure_parse_cdc_processor "${PARSE_CDC_ID}"
        echo -e "${GREEN}Configured EvaluateJsonPath processor${NC}"
    fi
    
    # 5. RouteOnAttribute - Filter events with data
    ROUTE_CDC_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.RouteOnAttribute" "Route Changes" 1200 900)
    if [ -z "$ROUTE_CDC_ID" ] || [ "$ROUTE_CDC_ID" = "null" ]; then
        echo -e "${RED}Failed to create RouteOnAttribute${NC}" >&2
    else
        configure_route_cdc_processor "${ROUTE_CDC_ID}"
        echo -e "${GREEN}Configured RouteOnAttribute processor${NC}"
    fi
    
    # 6. LogAttribute - Log CDC changes
    LOG_CDC_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.LogAttribute" "Log CDC Changes" 1200 1100)
    if [ -n "$LOG_CDC_ID" ] && [ "$LOG_CDC_ID" != "null" ]; then
        configure_log_processor "${LOG_CDC_ID}" "CDC_CHANGE"
        echo -e "${GREEN}Configured LogAttribute processor${NC}"
    fi
    
    # Create connections
    echo -e "${YELLOW}Creating connections between processors...${NC}"
    
    # ExecuteSQL -> ConvertRecord
    create_connection "${CDC_EXECUTE_ID}" "PROCESSOR" "success" "${CONVERT_JSON_ID}" "PROCESSOR" "${PG_ID}"
    
    # ConvertRecord -> SplitJson
    create_connection "${CONVERT_JSON_ID}" "PROCESSOR" "success" "${SPLIT_JSON_ID}" "PROCESSOR" "${PG_ID}"
    
    # SplitJson -> EvaluateJsonPath
    create_connection "${SPLIT_JSON_ID}" "PROCESSOR" "split" "${PARSE_CDC_ID}" "PROCESSOR" "${PG_ID}"
    
    # EvaluateJsonPath -> RouteOnAttribute
    create_connection "${PARSE_CDC_ID}" "PROCESSOR" "matched" "${ROUTE_CDC_ID}" "PROCESSOR" "${PG_ID}"
    
    # RouteOnAttribute -> LogAttribute
    create_connection "${ROUTE_CDC_ID}" "PROCESSOR" "has_changes" "${LOG_CDC_ID}" "PROCESSOR" "${PG_ID}"
    
    echo -e "${GREEN}All connections created successfully!${NC}"
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}NiFi CDC Pattern Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo -e "1. Access NiFi UI at: ${NIFI_URL}/nifi"
    echo -e "2. Navigate to the 'PostgreSQL CDC Pattern' process group"
    echo -e "3. Create the replication slot with this SQL command:"
    echo -e "   ${BLUE}SELECT * FROM pg_create_logical_replication_slot('nifi_cdc_slot', 'test_decoding');${NC}"
    echo -e "4. Review the flow and adjust configuration if needed"
    echo -e "5. Start the processors to begin CDC processing"
    echo -e "6. Test by inserting/updating data in the orders table"
    echo -e "\n${YELLOW}Important:${NC}"
    echo -e "- This uses ExecuteSQL to query the replication slot directly"
    echo -e "- The replication slot must be created before starting the flow"
    echo -e "- LogAttribute processor is a placeholder - replace with your message broker"
    echo -e "- CDC captures all changes to tables in the publication"
    echo -e "\n${YELLOW}To create replication slot:${NC}"
    echo -e "docker exec -it postgres_cdc psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"SELECT * FROM pg_create_logical_replication_slot('nifi_cdc_slot', 'test_decoding');\""
}

# Run main function
main