#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Setup script for Apache NiFi Outbox Pattern with PostgreSQL
# This script configures NiFi flow using REST API with token-based authentication
# debugging:
#  ./nifi-outbox-setup.sh [--dry-run|-n] || echo "Failed with exit code $?"


# Dry run flag (no changes applied to NiFi when enabled)
# A --dry-run / -n flag is now supported
# Usage: ./nifi-outbox-setup.sh [--dry-run|-n]
# What It Does:
#  No POST/PUT calls are executed against NiFi.
#  Synthetic IDs are generated for process groups, controller services, and processors.
#  Configuration, connection creation, enabling services, and parameter context assignment are all skipped with informative messages.
#  Authentication call is skipped and a fake token is used.
#  Output clearly marks each intended action with [DRY RUN].
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

echo -e "${GREEN}Starting NiFi Outbox Pattern Setup...${NC}"
echo -e "${YELLOW}Using NiFi URL: ${NIFI_URL}${NC}"
echo -e "${YELLOW}Using credentials: ${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}${NC}"
echo -e "${YELLOW}PostgreSQL Host: ${POSTGRES_HOST} Port: ${POSTGRES_PORT} DB: ${POSTGRES_DB}${NC}"

if [ "$DRY_RUN" = "1" ]; then
    echo -e "${BLUE}[DRY RUN] No changes will be applied. Showing intended actions only.${NC}"
fi
# ---------------- Helper utilities -----------------

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

is_revision_conflict() {
    local http_code=$1
    local body=$2
    # NiFi may return 400 or 409 with conflict text
    if echo "$body" | grep -qi "not the most up-to-date revision"; then
        return 0
    fi
    if [ "$http_code" = "409" ]; then
        return 0
    fi
    return 1
}

# Quick SQL probe to ensure outbox table exists (optional, best-effort)
check_outbox_table() {
    echo -e "${YELLOW}Verifying existence of 'outbox' table...${NC}"
    local sql="SELECT to_regclass('public.outbox') IS NOT NULL AS exists;"
    if command -v psql >/dev/null 2>&1; then
        if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c "$sql" 2>/dev/null | grep -q t; then
            echo -e "${GREEN}Outbox table found.${NC}"
        else
            echo -e "${RED}Outbox table not found in ${POSTGRES_DB}. Please create it before running this script.${NC}"
            exit 1
        fi
    elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q '^postgres'; then
        # Attempt via docker exec (container name heuristic)
        local pg_container=$(docker ps --format '{{.Names}}' | grep -E 'postgres_cdc|postgres' | head -1)
        if [ -n "$pg_container" ] && docker exec "$pg_container" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c "$sql" 2>/dev/null | grep -q t; then
            echo -e "${GREEN}Outbox table found (inside container).${NC}"
        else
            echo -e "${RED}Outbox table not found (checked via docker). Create it first (see init.sql).${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}Could not verify outbox table (psql not available). Continuing...${NC}"
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

# Function to create Database Connection Pool
create_dbcp_service() {
    local pg_id=$1
    
    echo -e "${YELLOW}Creating Database Connection Pool...${NC}"
    
    local dbcp_id
    if [ "$DRY_RUN" = "1" ]; then
        dbcp_id="dry-dbcp-${pg_id}"
        echo -e "${BLUE}[DRY RUN] Would create DBCP controller service in PG ${pg_id}. -> ${dbcp_id}${NC}"
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
    
    # Enable the controller service (skip in dry run)
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${BLUE}[DRY RUN] Would enable controller service ${dbcp_id}.${NC}"
    else
        echo -e "${YELLOW}Enabling Database Connection Pool...${NC}"
        local response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/controller-services/${dbcp_id}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"revision\": {\"version\": 1},
                \"component\": {
                    \"id\": \"${dbcp_id}\",
                    \"state\": \"ENABLED\"
                }
            }" -w " HTTPSTATUS:%{http_code}")
        local http_code=${response##*HTTPSTATUS:}
        if [ "$http_code" != "200" ]; then
            echo -e "${YELLOW}Note: Controller service will be enabled after configuration${NC}"
        else
            echo -e "${GREEN}Database Connection Pool enabled${NC}"
        fi
    fi
    
    echo $dbcp_id
}

# Function to create a processor
create_processor() {
    local pg_id=$1
    local type=$2
    local name=$3
    local x=$4
    local y=$5
    
    if [ "$DRY_RUN" = "1" ]; then
        local fake_id="dry-proc-${RANDOM}"
        echo -e "${BLUE}[DRY RUN] Would create processor '${name}' (${type}) at (${x},${y}) -> ${fake_id}${NC}"
        echo "$fake_id"
        return 0
    fi

    local response=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${pg_id}/processors" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"revision\": {\"version\": 0},
            \"component\": {
                \"type\": \"${type}\",
                \"name\": \"${name}\",
                \"position\": {\"x\": ${x}, \"y\": ${y}}
            }
        }")
    echo "$response" | jq -r '.id'
}

# Function to configure processor with retry logic
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

        # Build JSON payload safely
        if [ -n "$rev_client_id" ]; then
            revision_block="{\"version\": ${rev_version}, \"clientId\": \"${rev_client_id}\"}"
        else
            revision_block="{\"version\": ${rev_version}}"
        fi

        local config_block=$(echo "$config_json" | jq -r '.component.config')
        local full_config="{\n  \"revision\": ${revision_block},\n  \"component\": {\n    \"id\": \"${processor_id}\",\n    \"config\": ${config_block}\n  }\n}"

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
            echo -e "${YELLOW}Revision conflict while configuring ${processor_name}; retrying (attempt $attempt/${max_attempts})...${NC}"
            sleep 1
        else
            echo -e "${RED}Failed configuring ${processor_name} (HTTP $http_code) - not a revision conflict. Aborting retries.${NC}"
            log_error_response "$http_code" "$body"
            break
        fi
        attempt=$((attempt + 1))
    done

    if [ "$success" != true ]; then
        echo -e "${RED}Failed to configure ${processor_name} after $attempt attempts${NC}"
        exit 1
    fi
}

# Function to configure QueryDatabaseTable processor
configure_query_db_processor() {
    local processor_id=$1
    local dbcp_id=$2
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"Database Connection Pooling Service\": \"${dbcp_id}\",
                    \"Database Type\": \"PostgreSQL\",
                    \"Table Name\": \"outbox\",
                    \"Columns to Return\": \"id,aggregate_type,aggregate_id,event_type,payload,created_at\",
                    \"Maximum-value Columns\": \"id\",
                    \"Max Rows Per Flow File\": \"100\",
                    \"Fetch Size\": \"100\",
                    \"Use Avro Logical Types\": \"false\",
                    \"Default Decimal Precision\": \"10\",
                    \"Default Decimal Scale\": \"0\",
                    \"Default Text Column Width\": \"4000\"
                },
                \"schedulingPeriod\": \"30 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"PRIMARY\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [],
                \"comments\": \"Polls the outbox table for new events using incremental ID\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "QueryDatabaseTable"
}

# Function to configure ConvertAvroToJSON processor
configure_avro_to_json_processor() {
    local processor_id=$1
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"JSON container options\": \"array\",
                    \"Wrap Single Record\": \"false\"
                },
                \"schedulingPeriod\": \"0 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"ALL\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [\"failure\"],
                \"comments\": \"Converts Avro records to JSON format\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "ConvertAvroToJSON"
}

# Function to configure SplitJson processor
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
                \"comments\": \"Splits JSON array into individual events\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "SplitJson"
}

# Function to configure EvaluateJsonPath processor
configure_evaluate_json_processor() {
    local processor_id=$1
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"Destination\": \"flowfile-attribute\",
                    \"Return Type\": \"auto-detect\",
                    \"Path Not Found Behavior\": \"warn\",
                    \"Null Value Representation\": \"empty string\",
                    \"event.id\": \"\$.id\",
                    \"event.aggregate_type\": \"\$.aggregate_type\",
                    \"event.aggregate_id\": \"\$.aggregate_id\",
                    \"event.event_type\": \"\$.event_type\",
                    \"event.created_at\": \"\$.created_at\"
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
                \"comments\": \"Extracts event metadata to flowfile attributes\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "EvaluateJsonPath"
}

# Function to configure LogAttribute processor
configure_publish_processor() {
    local processor_id=$1
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"Log Level\": \"info\",
                    \"Log Payload\": \"true\",
                    \"Attributes to Log\": \"event.*\",
                    \"Attributes to Log Separately\": \"event.aggregate_type,event.event_type,event.aggregate_id\",
                    \"Log prefix\": \"OUTBOX_EVENT\"
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
                \"comments\": \"Logs outbox events (replace with Kafka/target system)\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "LogAttribute"
}

# Function to configure UpdateAttribute processor
configure_update_attribute_processor() {
    local processor_id=$1
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"sql.args.1.type\": \"4\",
                    \"sql.args.1.value\": \"\${event.id}\",
                    \"sql.args.1.format\": \"int\"
                },
                \"schedulingPeriod\": \"0 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"ALL\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [],
                \"comments\": \"Prepares SQL parameters for cleanup\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "UpdateAttribute"
}

# Function to configure PutSQL processor for cleanup
configure_cleanup_processor() {
    local processor_id=$1
    local dbcp_id=$2
    
    local config="{
        \"component\": {
            \"config\": {
                \"properties\": {
                    \"JDBC Connection Pool\": \"${dbcp_id}\",
                    \"SQL Statement\": \"DELETE FROM outbox WHERE id = ?\",
                    \"Support Fragmented Transactions\": \"false\",
                    \"Batch Size\": \"100\",
                    \"Obtain Generated Keys\": \"false\",
                    \"Rollback On Failure\": \"false\"
                },
                \"schedulingPeriod\": \"0 sec\",
                \"schedulingStrategy\": \"TIMER_DRIVEN\",
                \"executionNode\": \"ALL\",
                \"penaltyDuration\": \"30 sec\",
                \"yieldDuration\": \"1 sec\",
                \"bulletinLevel\": \"WARN\",
                \"runDurationMillis\": 0,
                \"concurrentlySchedulableTaskCount\": 1,
                \"autoTerminatedRelationships\": [\"failure\"],
                \"comments\": \"Deletes processed events from outbox table\"
            }
        }
    }"
    
    configure_processor_with_retry "$processor_id" "$config" "PutSQL"
}

# Function to create connections between processors
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

# Main setup flow
main() {
    # Validate environment first
    validate_env

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${BLUE}[DRY RUN] Short-circuiting NiFi API calls; synthesizing IDs and skipping connectivity checks.${NC}"
        ROOT_PG_ID="dry-root"
        PG_ID="dry-pg-PostgreSQL-Outbox-Pattern"
        PARAM_CTX_ID="dry-paramctx-Outbox-DB"
        DBCP_ID="dry-dbcp-${PG_ID}"
    else
        # Wait for NiFi to be ready
        wait_for_nifi

        # Get authentication token
        get_auth_token

        # Pre DB sanity check
        check_outbox_table

        # Get root process group ID
        get_root_pg_id

        # Idempotent: see if PG already exists
        echo -e "${YELLOW}Looking for existing 'PostgreSQL Outbox Pattern' process group...${NC}"
        PG_ID=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | jq -r '.processGroupFlow.flow.processGroups[]? | select(.component.name=="PostgreSQL Outbox Pattern") | .component.id' | head -1)
        if [ -n "$PG_ID" ]; then
            echo -e "${GREEN}Reusing existing process group: ${PG_ID}${NC}"
        else
            echo -e "${YELLOW}Creating Outbox Pattern process group...${NC}"
            PG_ID=$(create_process_group "${ROOT_PG_ID}" "PostgreSQL Outbox Pattern")
            echo -e "${GREEN}Created Process Group: ${PG_ID}${NC}"
        fi

        # Create / reuse parameter context for DB values
        echo -e "${YELLOW}Ensuring parameter context 'Outbox-DB' exists...${NC}"
        PARAM_CTX_ID=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/parameter-contexts" -H "Authorization: Bearer ${TOKEN}" | jq -r '.parameterContexts[]? | select(.component.name=="Outbox-DB") | .id' | head -1)
        if [ -z "$PARAM_CTX_ID" ]; then
            PARAM_CTX_ID=$(curl -sk -X POST "${NIFI_URL}/nifi-api/parameter-contexts" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"revision\": {\"version\": 0},
                    \"component\": {
                        \"name\": \"Outbox-DB\",
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

        # Assign parameter context to process group (fetch PG revision first)
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
    fi
    
    # Create processors
    echo -e "${YELLOW}Creating processors...${NC}"
    
    # 1. QueryDatabaseTable - Poll outbox table
    QUERY_DB_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.QueryDatabaseTable" "Poll Outbox Table" 100 100)
    configure_query_db_processor "${QUERY_DB_ID}" "${DBCP_ID}"
    echo -e "${GREEN}Created QueryDatabaseTable processor${NC}"
    
    # 2. ConvertAvroToJSON - Convert Avro to JSON
    AVRO_TO_JSON_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.kite.ConvertAvroToJSON" "Convert to JSON" 400 100)
    configure_avro_to_json_processor "${AVRO_TO_JSON_ID}"
    echo -e "${GREEN}Created ConvertAvroToJSON processor${NC}"
    
    # 3. SplitJson - Split JSON array into individual events
    SPLIT_JSON_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.SplitJson" "Split Events" 700 100)
    configure_split_json_processor "${SPLIT_JSON_ID}"
    echo -e "${GREEN}Created SplitJson processor${NC}"
    
    # 4. EvaluateJsonPath - Extract event attributes
    EVAL_JSON_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.EvaluateJsonPath" "Extract Event Metadata" 1000 100)
    configure_evaluate_json_processor "${EVAL_JSON_ID}"
    echo -e "${GREEN}Created EvaluateJsonPath processor${NC}"
    
    # 5. LogAttribute - Log events (replace with actual publisher)
    LOG_ATTR_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.LogAttribute" "Publish Events (Log)" 1300 100)
    configure_publish_processor "${LOG_ATTR_ID}"
    echo -e "${GREEN}Created LogAttribute processor (placeholder for publisher)${NC}"
    
    # 6. UpdateAttribute - Prepare for cleanup
    UPDATE_ATTR_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.attributes.UpdateAttribute" "Prepare Cleanup SQL" 1000 300)
    configure_update_attribute_processor "${UPDATE_ATTR_ID}"
    echo -e "${GREEN}Created UpdateAttribute processor${NC}"
    
    # 7. PutSQL - Delete processed events
    PUT_SQL_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.PutSQL" "Delete from Outbox" 1300 300)
    configure_cleanup_processor "${PUT_SQL_ID}" "${DBCP_ID}"
    echo -e "${GREEN}Created PutSQL processor${NC}"
    
    # Create connections
    echo -e "${YELLOW}Creating connections between processors...${NC}"
    
    # QueryDatabaseTable -> ConvertAvroToJSON
    create_connection "${QUERY_DB_ID}" "PROCESSOR" "success" "${AVRO_TO_JSON_ID}" "PROCESSOR" "${PG_ID}"
    
    # ConvertAvroToJSON -> SplitJson
    create_connection "${AVRO_TO_JSON_ID}" "PROCESSOR" "success" "${SPLIT_JSON_ID}" "PROCESSOR" "${PG_ID}"
    
    # SplitJson -> EvaluateJsonPath
    create_connection "${SPLIT_JSON_ID}" "PROCESSOR" "split" "${EVAL_JSON_ID}" "PROCESSOR" "${PG_ID}"
    
    # EvaluateJsonPath -> LogAttribute (publish)
    create_connection "${EVAL_JSON_ID}" "PROCESSOR" "matched" "${LOG_ATTR_ID}" "PROCESSOR" "${PG_ID}"
    
    # EvaluateJsonPath -> UpdateAttribute (for cleanup)
    create_connection "${EVAL_JSON_ID}" "PROCESSOR" "matched" "${UPDATE_ATTR_ID}" "PROCESSOR" "${PG_ID}"
    
    # UpdateAttribute -> PutSQL
    create_connection "${UPDATE_ATTR_ID}" "PROCESSOR" "success" "${PUT_SQL_ID}" "PROCESSOR" "${PG_ID}"
    
    echo -e "${GREEN}All connections created successfully!${NC}"
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}NiFi Outbox Pattern Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo -e "1. Access NiFi UI at: ${NIFI_URL}/nifi"
    echo -e "2. Navigate to the 'PostgreSQL Outbox Pattern' process group"
    echo -e "3. Review the flow and adjust configuration if needed"
    echo -e "4. Start the processors to begin processing"
    echo -e "5. Insert test data using: ./test-outbox.sh"
    echo -e "\n${YELLOW}Note:${NC} The LogAttribute processor is a placeholder."
    echo -e "Replace it with your actual message broker (Kafka, RabbitMQ, etc.)"
}

# Run main function
main