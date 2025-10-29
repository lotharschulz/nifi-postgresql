```sh
# Spin up NiFi and PostgreSQL
$ docker-compose up -d
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

Load environment variables from .env file and retrieve a token
```sh
export $(cat .env | grep -v '^#' | xargs)

echo "NIFI_HOST: ${NIFI_HOST}"
echo "NIFI_PORT: ${NIFI_PORT}"
export NIFI_URL="https://${NIFI_HOST}:${NIFI_PORT}"
echo "NIFI_URL: ${NIFI_URL}"

echo "POSTGRES_HOST: ${POSTGRES_HOST}"
echo "POSTGRES_PORT: ${POSTGRES_PORT}"
echo "POSTGRES_DB: ${POSTGRES_DB}"

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

Get root process group ID

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

Create a new process group for Outbox pattern:

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

Create a controller service
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
Controller Service ID: 325c1525-019a-1000-b10e-0dbf1993683e
Successfully enabled controller service
```

Create QueryDatabaseTable processor to poll outbox table
TODO