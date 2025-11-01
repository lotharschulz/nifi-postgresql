## Spin up NiFi and PostgreSQL

```sh
docker-compose up -d
```

response:
```sh
 ✔ Network nifi_postgresql_default       Created
 ✔ Volume nifi_postgresql_nifi_conf      Created
 ✔ Volume nifi_postgresql_nifi_logs      Created
 ✔ Volume nifi_postgresql_postgres_data  Created
 ✔ Volume nifi_postgresql_nifi_state     Created
 ✔ Container nifi_cdc                    Started
 ✔ Container postgres_cdc                Started
```

## Load environment variables from .env file and retrieve a token
```sh
export $(cat .env | grep -v '^#' | xargs)

echo "NIFI_HOST: ${NIFI_HOST}"
echo "NIFI_PORT: ${NIFI_PORT}"
export NIFI_URL="https://${NIFI_HOST}:${NIFI_PORT}"
echo "NIFI_URL: ${NIFI_URL}"

echo "POSTGRES_HOST: ${POSTGRES_HOST}"
echo "POSTGRES_PORT: ${POSTGRES_PORT}"
echo "POSTGRES_DB: ${POSTGRES_DB}"
echo "POSTGRES_USER: ${POSTGRES_USER}"

# Get authentication token (it's returned as plain text, not JSON)
TOKEN=$(curl -k -s -X POST "${NIFI_URL}/nifi-api/access/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=${NIFI_SINGLE_USER_CREDENTIALS_USERNAME}&password=${NIFI_SINGLE_USER_CREDENTIALS_PASSWORD}")
echo "Token (first 20 chars): ${TOKEN:0:20}..."
```

sample response:
```sh
NIFI_HOST: localhost
NIFI_PORT: 8443
NIFI_URL: https://localhost:8443
POSTGRES_HOST: localhost
POSTGRES_PORT: 5432
POSTGRES_DB: demo_db
Token (first 20 chars): eyJraWQiOiI0OGIxYWVm...
```

## Get root process group ID
```sh
ROOT_PG_ID=$(curl -sk -X GET "${NIFI_URL}/nifi-api/flow/process-groups/root" \
-H "Authorization: Bearer ${TOKEN}" | \
jq -r '.processGroupFlow.id')
echo "Root process group ID: ${ROOT_PG_ID}"
```

sample response:
```sh
Root process group ID: 2fafd23b-019a-1000-2fb1-0261b9e1f073
```

## Create a new process group for Outbox pattern:
```sh
PG_ID=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${ROOT_PG_ID}/process-groups" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"revision\": {\"version\": 0},
        \"component\": {
            \"name\": \"PostgreSQL Outbox Pattern\",
            \"position\": {\"x\": 100, \"y\": 100}
        }
    }" | jq -r '.id')
echo "Process group ID: ${PG_ID}"
```

sample response:
```sh
Process group ID: 2fc04422-019a-1000-a209-e892c78c8934
```

## Create Database Connection Pool service
```sh
DBCP_ID=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${PG_ID}/controller-services" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"revision\": {\"version\": 0},
        \"component\": {
            \"name\": \"PostgreSQL Connection Pool\",
            \"type\": \"org.apache.nifi.dbcp.DBCPConnectionPool\",
            \"properties\": {
                \"Database Connection URL\": \"jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}\",
                \"Database Driver Class Name\": \"org.postgresql.Driver\",
                \"Database User\": \"${POSTGRES_USER}\",
                \"Password\": \"${POSTGRES_PASSWORD}\",
                \"Max Total Connections\": \"8\",
                \"Max Idle Connections\": \"0\",
                \"Validation query\": \"SELECT 1\"
            }
        }
    }" | jq -r '.id')
    
echo "Database Connection Pool ID: ${DBCP_ID}"
    
# Enable the Database Connection Pool service
response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/controller-services/${DBCP_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"revision\": {\"version\": 1},
        \"component\": {
            \"id\": \"${DBCP_ID}\",
            \"state\": \"ENABLED\"
        }
    }" -w " HTTPSTATUS:%{http_code}")

http_code=${response##*HTTPSTATUS:}
body=${response% HTTPSTATUS:*}

if [ "$http_code" != "200" ]; then
    echo "Failed to request enable Database Connection Pool service (HTTP $http_code)"
    echo "$body"
    exit 1
else
    echo "Successfully enabled controller service"
fi
```

sample response
```sh
Database Connection Pool ID: 35a29cde-019a-1000-61e5-c2ab4460707f
Successfully enabled controller service
```

## Create a controller service
```sh
CONTR_SVC_ID=$(curl -sk -X POST "${NIFI_URL}/nifi-api/process-groups/${PG_ID}/controller-services" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"revision\": {\"version\": 0},
        \"component\": {
            \"name\": \"PostgreSQL Connection Pool\",
            \"type\": \"org.apache.nifi.dbcp.DBCPConnectionPool\",
            \"properties\": {
                \"Database Connection URL\": \"jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}\",
                \"Database Driver Class Name\": \"org.postgresql.Driver\",
                \"Database User\": \"${POSTGRES_USER}\",
                \"Password\": \"${POSTGRES_PASSWORD}\",
                \"Max Total Connections\": \"8\",
                \"Max Idle Connections\": \"0\",
                \"Validation query\": \"SELECT 1\"
            }
        }
    }" | jq -r '.id')
echo "Controller Service ID: ${CONTR_SVC_ID}"

# Enable the controller service
response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/controller-services/${CONTR_SVC_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"revision\": {\"version\": 1},
        \"component\": {
            \"id\": \"${CONTR_SVC_ID}\",
            \"state\": \"ENABLED\"
        }
    }" -w " HTTPSTATUS:%{http_code}")

http_code=${response##*HTTPSTATUS:}
body=${response% HTTPSTATUS:*}

if [ "$http_code" != "200" ]; then
    echo "Failed to request enable controller service (HTTP $http_code)"
    echo "$body"
    exit 1
else
    echo "Successfully enabled controller service"
fi
```

sample response:
```sh
Controller Service ID: 35a30f2f-019a-1000-9c13-73af0ced071f
Successfully enabled controller service
```

## Create Processor Function
```sh
create_processor() {
    local pg_id=$1
    local type=$2
    local name=$3
    local x=$4
    local y=$5
    
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
    
    echo $response | jq -r '.id'
}
```

## Create Processors
### 1. QueryDatabaseTable Processor Configuration
```sh
# create processor
QUERY_DB_PRCS_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.standard.QueryDatabaseTable" "Poll Outbox Table" 100 100)
echo "Query Database Processor ID: ${QUERY_DB_PRCS_ID}"

# configure processor with dynamic revision (NiFi uses optimistic locking)
# Retry a few times in case another operation updated the processor concurrently.
max_attempts=5
attempt=1
success=false
while [ $attempt -le $max_attempts ]; do
    # Fetch latest revision info
    proc_state=$(curl -sk -X GET "${NIFI_URL}/nifi-api/processors/${QUERY_DB_PRCS_ID}" \
        -H "Authorization: Bearer ${TOKEN}")
    REV_VERSION=$(echo "$proc_state" | jq -r '.revision.version')
    REV_CLIENT_ID=$(echo "$proc_state" | jq -r '.revision.clientId')

    response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/processors/${QUERY_DB_PRCS_ID}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"revision\": {\"version\": ${REV_VERSION}, \"clientId\": \"${REV_CLIENT_ID}\"},
            \"component\": {
                \"id\": \"${QUERY_DB_PRCS_ID}\",
                \"config\": {
                    \"properties\": {
                        \"Database Connection Pooling Service\": \"${DBCP_ID}\",
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
        }" -w " HTTPSTATUS:%{http_code}")

    http_code=${response##*HTTPSTATUS:}
    body=${response% HTTPSTATUS:*}

    if [ "$http_code" = "200" ]; then
        echo "Successfully configured QueryDatabaseTable processor"
        success=true
        break
    fi

    echo "Attempt $attempt failed (HTTP $http_code)."
    echo "$body" | grep -q "not the most up-to-date revision"
    if [ $? -eq 0 ]; then
        echo "Revision conflict detected; retrying after brief pause..."
        sleep 1
    else
        echo "Failed to configure QueryDatabaseTable Processor (HTTP $http_code)"
        echo "$body"
        break
    fi
    attempt=$((attempt + 1))
done

if [ "$success" != true ]; then
    echo "Configuration did not succeed after $max_attempts attempts." >&2
    exit 1
fi
```

sample response:
```sh
Query Database Processor ID: 35a9a6ee-019a-1000-08ad-0eb583c08da0
Successfully configured QueryDatabaseTable processor
```

### 2. ConvertAvroToJSON - Convert Avro to JSON

```sh
# create ConvertAvroToJSON processor
AVRO_TO_JSON_ID=$(create_processor "${PG_ID}" "org.apache.nifi.processors.kite.ConvertAvroToJSON" "Convert to JSON" 400 100)
echo "Avro to JSON converter processor ID: ${AVRO_TO_JSON_ID}"

# Configure processor with dynamic revision (NiFi uses optimistic locking)
# Retry a few times in case another operation updated the processor concurrently.
max_attempts=5
attempt=1
success=false
while [ $attempt -le $max_attempts ]; do
    # Fetch latest revision info
    proc_state=$(curl -sk -X GET "${NIFI_URL}/nifi-api/processors/${AVRO_TO_JSON_ID}" \
        -H "Authorization: Bearer ${TOKEN}")
    REV_VERSION=$(echo "$proc_state" | jq -r '.revision.version')
    REV_CLIENT_ID=$(echo "$proc_state" | jq -r '.revision.clientId // empty')
    
    # Build revision JSON - handle optional clientId
    if [ -z "$REV_CLIENT_ID" ] || [ "$REV_CLIENT_ID" = "null" ]; then
        revision_json="{\"version\": ${REV_VERSION}}"
    else
        revision_json="{\"version\": ${REV_VERSION}, \"clientId\": \"${REV_CLIENT_ID}\"}"
    fi

    response=$(curl -sk -X PUT "${NIFI_URL}/nifi-api/processors/${AVRO_TO_JSON_ID}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"revision\": ${revision_json},
            \"component\": {
                \"id\": \"${AVRO_TO_JSON_ID}\",
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
        }" -w " HTTPSTATUS:%{http_code}")

    http_code=${response##*HTTPSTATUS:}
    body=${response% HTTPSTATUS:*}

    if [ "$http_code" = "200" ]; then
        echo "Successfully configured ConvertAvroToJSON processor"
        success=true
        break
    fi

    echo "Attempt $attempt failed (HTTP $http_code)."
    echo "$body" | grep -q "not the most up-to-date revision"
    if [ $? -eq 0 ]; then
        echo "Revision conflict detected; retrying after brief pause..."
        sleep 1
    else
        echo "Failed to configure ConvertAvroToJSON Processor (HTTP $http_code)"
        echo "$body"
        break
    fi
    attempt=$((attempt + 1))
done

if [ "$success" != true ]; then
    echo "Configuration did not succeed after $max_attempts attempts." >&2
    exit 1
fi
```