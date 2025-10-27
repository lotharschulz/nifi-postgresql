```sh
# Spin up NiFi and PostgreSQL
$ docker-compose up -d
```

```sh
 ✔ Network nifi_postgresql_default       Created
 ✔ Volume nifi_postgresql_nifi_conf      Created
 ✔ Volume nifi_postgresql_nifi_logs      Created
 ✔ Volume nifi_postgresql_postgres_data  Created
 ✔ Volume nifi_postgresql_nifi_state     Created
 ✔ Container nifi_cdc                    Started
 ✔ Container postgres_cdc                Started
```

```sh
$ # Load environment variables from .env file
export $(cat .env | grep -v '^#' | xargs)

echo "NIFI_HOST: ${NIFI_HOST}"
echo "NIFI_PORT: ${NIFI_PORT}"

# Get authentication token (it's returned as plain text, not JSON)
TOKEN=$(curl -k -s -X POST "https://${NIFI_HOST}:${NIFI_PORT}/nifi-api/access/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=${NIFI_USERNAME}&password=${NIFI_PASSWORD}")
echo "Token (first 50 chars): ${TOKEN:0:50}..."
```

```sh
NIFI_HOST: localhost
NIFI_PORT: 8443
Token (first 50 chars): eyJraWQiOiI5MTc3MmY0Ni03NDNkLTQ0OGQtODc3YS1mODNlZT...
```

Uploading and configuring your CDC (Change Data Capture) flow.

```sh
$ # Upload the flow template
curl -k -X POST "https://${NIFI_HOST}:${NIFI_PORT}/nifi-api/process-groups/root/templates/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F template=@cdc-outbox-flow.xml

# Get the root process group ID
ROOT_PG_ID=$(curl -k -s "https://${NIFI_HOST}:${NIFI_PORT}/nifi-api/flow/process-groups/root" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.processGroupFlow.id')

echo "Root Process Group ID: ${ROOT_PG_ID}"

# List available templates to get the template ID
TEMPLATES=$(curl -k -s "https://${NIFI_HOST}:${NIFI_PORT}/nifi-api/flow/templates" \
  -H "Authorization: Bearer ${TOKEN}")

echo "Available templates:"
echo "$TEMPLATES" | jq '.templates[] | {id: .template.id, name: .template.name}'
```

```sh
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><templateEntity><template encoding-version="1.4"><description>PostgreSQL CDC with Outbox Pattern - QueryDatabaseTable, EvaluateJsonPath, and LogAttribute</description><groupId>256f711b-019a-1000-3f6b-392f7974ae9d</groupId><id>f6a2ae5d-5beb-40e0-931d-e9b2ba7c72cf</id><name>PostgreSQL CDC Outbox Flow</name><timestamp>10/27/2025 12:21:56 UTC</timestamp><uri>https://localhost:8443/nifi-api/templates/f6a2ae5d-5beb-40e0-931d-e9b2ba7c72cf</uri></template></templateEntity>Root Process Group ID: 256f711b-019a-1000-3f6b-392f7974ae9d
Available templates:
{
  "id": "f6a2ae5d-5beb-40e0-931d-e9b2ba7c72cf",
  "name": "PostgreSQL CDC Outbox Flow"
}
```

Instantiate the Template

```sh
# Get the template ID (assuming it's the first/only template)
TEMPLATE_ID=$(echo "$TEMPLATES" | jq -r '.templates[0].template.id')

echo "Template ID: ${TEMPLATE_ID}"
echo "Root Process Group ID: ${ROOT_PG_ID}"

# Instantiate the template in the root process group
curl -k -X POST "https://${NIFI_HOST}:${NIFI_PORT}/nifi-api/process-groups/${ROOT_PG_ID}/template-instance" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"templateId\": \"${TEMPLATE_ID}\",
    \"originX\": 100,
    \"originY\": 100
  }" | jq '.'
```

```sh
Template ID: 73f0ad32-0d51-40f8-81b9-48c61b4422f0
Root Process Group ID: 27f60c6f-019a-1000-0678-a161e6597f49
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   181  100    79  100   102    718    927 --:--:-- --:--:-- --:--:--  1660
jq: parse error: Invalid numeric literal at line 1, column 3
```