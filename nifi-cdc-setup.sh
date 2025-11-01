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
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done

source .env

NIFI_URL="https://${NIFI_HOST:-localhost}:${NIFI_PORT:-8443}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf '%b\n' "$*"; }
info() { log "${GREEN}$*${NC}"; }
warn() { log "${YELLOW}$*${NC}"; }
err() { log "${RED}$*${NC}" >&2; }
debug() { [ -n "${DEBUG:-}" ] && log "${BLUE}[DEBUG] $*${NC}"; }

info "Starting NiFi CDC Pattern Setup..."
warn "Using NiFi URL: ${NIFI_URL}"
warn "Using credentials: ${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}"
warn "PostgreSQL Host: ${POSTGRES_HOST} Port: ${POSTGRES_PORT} DB: ${POSTGRES_DB}"
[ "$DRY_RUN" = 1 ] && log "${BLUE}[DRY RUN] No changes will be applied. Showing intended actions only.${NC}"

required_vars=(NIFI_HOST NIFI_PORT POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD NIFI_SINGLE_USER_CREDENTIALS_USERNAME NIFI_SINGLE_USER_CREDENTIALS_PASSWORD)
missing=()
for v in "${required_vars[@]}"; do
  [ -z "${!v:-}" ] && missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
  err "Missing required env vars: ${missing[*]}"
  exit 1
fi

if ! echo "$NIFI_PORT" | grep -Eq '^[0-9]+$'; then err "NIFI_PORT must be numeric"; exit 1; fi
if ! echo "$POSTGRES_PORT" | grep -Eq '^[0-9]+$'; then err "POSTGRES_PORT must be numeric"; exit 1; fi

wait_for_nifi() {
  warn "Waiting for NiFi to be ready..."
  [ "$DRY_RUN" = 1 ] && log "${BLUE}[DRY RUN] Skipping readiness check.${NC}" && return 0
  for i in $(seq 1 60); do
    if curl -k -s "${NIFI_URL}/nifi-api/system-about" >/dev/null; then info "NiFi ready"; return 0; fi
    sleep 5; printf '.'
  done
  err "NiFi not ready after timeout"; return 1
}

get_token() {
  warn "Getting authentication token..."
  if [ "$DRY_RUN" = 1 ]; then TOKEN="DRY_RUN_TOKEN"; log "${BLUE}[DRY RUN] Synthetic token used.${NC}"; return 0; fi
  TOKEN=$(curl -k -s -X POST "${NIFI_URL}/nifi-api/access/token" -H 'Content-Type: application/x-www-form-urlencoded' -d "username=${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}&password=${NIFI_SINGLE_USER_CREDENTIALS_PASSWORD}")
  [ -z "$TOKEN" ] && err "Failed to obtain token" && exit 1
  info "Token acquired (first 20 chars): ${TOKEN:0:20}..."
}

root_pg_id() {
  if [ "$DRY_RUN" = 1 ]; then echo "dry-root"; return 0; fi
  curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | jq -r '.processGroupFlow.id'
}

find_or_create_pg() {
  local name=$1
  if [ "$DRY_RUN" = 1 ]; then echo "dry-pg-${name// /-}"; return 0; fi
  local existing=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | jq -r --arg n "$name" '.processGroupFlow.flow.processGroups[]? | select(.component.name==$n) | .component.id' | head -1)
  if [ -n "$existing" ]; then info "Reusing process group: $existing"; echo "$existing"; return 0; fi
  warn "Creating process group '$name'..."
  curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/$(root_pg_id)/process-groups" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"${name}\",\"position\":{\"x\":200,\"y\":100}}}" | jq -r '.id'
}

find_or_create_param_ctx() {
  local name=$1
  if [ "$DRY_RUN" = 1 ]; then echo "dry-paramctx-${name// /-}"; return 0; fi
  local existing=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/parameter-contexts" -H "Authorization: Bearer ${TOKEN}" | jq -r --arg n "$name" '.parameterContexts[]? | select(.component.name==$n) | .id' | head -1)
  if [ -n "$existing" ]; then info "Reusing parameter context: $existing"; echo "$existing"; return 0; fi
  warn "Creating parameter context '$name'..."
  curl -sk -X POST "${NIFI_URL}/nifi-api/parameter-contexts" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"revision\":{\"version\":0},\"component\":{\"name\":\"${name}\",\"parameters\":[{\"parameter\":{\"name\":\"DB_HOST\",\"value\":\"${POSTGRES_HOST}\"}},{\"parameter\":{\"name\":\"DB_PORT\",\"value\":\"${POSTGRES_PORT}\"}},{\"parameter\":{\"name\":\"DB_NAME\",\"value\":\"${POSTGRES_DB}\"}},{\"parameter\":{\"name\":\"DB_USER\",\"value\":\"${POSTGRES_USER}\"}},{\"parameter\":{\"name\":\"DB_PASSWORD\",\"value\":\"${POSTGRES_PASSWORD}\",\"sensitive\":true}}]}}" | jq -r '.id'
}

assign_param_ctx() {
  local pg_id=$1 ctx_id=$2
  [ "$DRY_RUN" = 1 ] && log "${BLUE}[DRY RUN] Would assign param ctx ${ctx_id} to ${pg_id}.${NC}" && return 0
  local pg_json=$(curl -sk -X GET "${NIFI_URL}/nifi-api/process-groups/${pg_id}" -H "Authorization: Bearer ${TOKEN}")
  local rev=$(echo "$pg_json" | jq -r '.revision.version')
  local cid=$(echo "$pg_json" | jq -r '.revision.clientId // empty')
  local rev_block
  [ -n "$cid" ] && rev_block="{\"version\":${rev},\"clientId\":\"${cid}\"}" || rev_block="{\"version\":${rev}}"
  curl -sk -X PUT "${NIFI_URL}/nifi-api/process-groups/${pg_id}" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"revision\":${rev_block},\"component\":{\"id\":\"${pg_id}\",\"parameterContext\":{\"id\":\"${ctx_id}\"}}}" >/dev/null
  info "Parameter context assigned"
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
  if [ "$code" != 201 ] && [ "$code" != 200 ]; then err "Failed to create processor ${name} (HTTP $code)"; echo "$body" >&2; return 1; fi
  echo "$body" | jq -r '.id'
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
  debug "Enable response: $en"
  echo "$id"
}

main() {
  wait_for_nifi
  get_token
  local PG_NAME="PostgreSQL CDC Pattern"
  local PARAM_CTX_NAME="CDC-DB"
  local PG_ID=$(find_or_create_pg "$PG_NAME")
  local PARAM_CTX_ID=$(find_or_create_param_ctx "$PARAM_CTX_NAME")
  assign_param_ctx "$PG_ID" "$PARAM_CTX_ID"

  # Create DBCP (CDC specific name, independent of outbox DBCP)
  local DBCP_ID=$(create_dbcp_service "$PG_ID")
  info "DBCP Service (CDC) ID: $DBCP_ID"

  # In dry-run mode we stop after controller service mock to show planned actions
  if [ "$DRY_RUN" = 1 ]; then
    warn "Dry-run complete (skipping processor creation & connections)."
    info "NiFi CDC Pattern Setup (dry-run) finished successfully."
    return 0
  fi

  # Processors
  # Capture Change (if available else fallback to QueryDatabaseTable incremental pattern)
  local CAPTURE_TYPE="org.apache.nifi.processors.standard.CaptureChangePostgreSQL"
  # Probe availability (bundle list)
  local available=""
  if [ "$DRY_RUN" != 1 ]; then
    available=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" -H "Authorization: Bearer ${TOKEN}" | grep -F "$CAPTURE_TYPE" || true)
  else
    debug "[DRY] Skipping processor availability probe"
  fi
  if [ -n "$available" ]; then
    info "Using CaptureChangePostgreSQL processor"
  else
    warn "CaptureChangePostgreSQL not found; falling back to QueryDatabaseTable for CDC simulation"
    CAPTURE_TYPE="org.apache.nifi.processors.standard.QueryDatabaseTable"
  fi
  local CAPTURE_ID=$(create_processor "$PG_ID" "$CAPTURE_TYPE" "CDC Source" 100 100 || true)
  if [ -n "$CAPTURE_ID" ]; then
    if [ "$CAPTURE_TYPE" = "org.apache.nifi.processors.standard.CaptureChangePostgreSQL" ]; then
      local SLOT_NAME="${CDC_SLOT_NAME:-outbox_slot}" # env override
      local TABLE_INCLUDE="${CDC_TABLE_INCLUDE:-public.outbox}"       # example table list
      local cfg=$(cfg_capture_change "$DBCP_ID" "$SLOT_NAME" "$TABLE_INCLUDE")
      configure_with_retry "$CAPTURE_ID" "CDC Source" "$cfg"
    else
      # Minimal config for QueryDatabaseTable as CDC fallback
      local cfg=$(cfg_poll_fallback "$DBCP_ID")
      configure_with_retry "$CAPTURE_ID" "CDC Source" "$cfg"
    fi
  else
    err "CDC Source processor creation failed"
  fi

  # Route events (placeholder for downstream handling)
  local ROUTE_ID=$(create_processor "$PG_ID" "org.apache.nifi.processors.standard.RouteOnAttribute" "Route CDC Events" 400 100 || true)
  if [ -n "$ROUTE_ID" ]; then
    local rcfg=$(cfg_route_event)
    configure_with_retry "$ROUTE_ID" "Route CDC Events" "$rcfg"
  fi

  # Connections (only if both processors exist)
  if [ -n "$CAPTURE_ID" ] && [ -n "$ROUTE_ID" ]; then
    [ "$DRY_RUN" = 1 ] && log "${BLUE}[DRY RUN] Would connect CDC Source -> Route CDC Events${NC}" || curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${PG_ID}/connections" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "{\"revision\":{\"version\":0},\"component\":{\"source\":{\"id\":\"${CAPTURE_ID}\",\"type\":\"PROCESSOR\",\"groupId\":\"${PG_ID}\"},\"destination\":{\"id\":\"${ROUTE_ID}\",\"type\":\"PROCESSOR\",\"groupId\":\"${PG_ID}\"},\"selectedRelationships\":[\"success\"],\"flowFileExpiration\":\"0 sec\",\"backPressureDataSizeThreshold\":\"1 GB\",\"backPressureObjectThreshold\":10000,\"loadBalanceStrategy\":\"DO_NOT_LOAD_BALANCE\",\"loadBalanceCompression\":\"DO_NOT_COMPRESS\"}}" >/dev/null
    info "Connection created (CDC Source -> Route CDC Events)"
  fi

  info "NiFi CDC Pattern Setup Complete!"
  warn "Next steps: Access NiFi UI, review 'PostgreSQL CDC Pattern' group, start processors, and link Route CDC Events to your downstream flow."
  return 0
}

main
