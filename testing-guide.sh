# NiFi CDC & Outbox Pattern Testing Guide

This guide walks you through testing both the CDC (Change Data Capture) and Outbox patterns with PostgreSQL and Apache NiFi.

## Prerequisites

- Docker and Docker Compose installed
- `jq` installed (for JSON processing in scripts)
- `.env` file configured (copy from `env-tmplt` if needed)

## Quick Start

```bash
# 1. Start the environment
docker-compose down -v && sleep 1 && docker-compose up -d
 
# Wait for NiFi to be ready
sleep 120

# 3. Make scripts executable
chmod +x nifi-cdc-setup.sh nifi-outbox-setup.sh test-cdc.sh test-outbox.sh nifi-diagnose.sh

# 4. Run CDC setup script
./nifi-cdc-setup.sh

# 4.1 Create replication slot (if not exists):
./test-cdc.sh --setup

# 4.2 Start the flow in NiFi UI
# 4.3 Generate test data:
./test-cdc.sh

# 5. Run Outbox setup script
./nifi-outbox-setup.sh

# 5.1 Start the flow in NiFi UI
# 5.2 Generate test data:
./test-outbox.sh

# 5.3 Wait a moment for processing, then check
sleep 15
docker exec postgres_cdc psql -U demo_user -d demo_db -c "SELECT COUNT(*) FROM outbox;"

#-------------

# Verify
./nifi-diagnose.sh
```

---

## Part 1: Testing the Outbox Pattern

The Outbox pattern polls a dedicated `outbox` table for events. When you insert an order, a database trigger automatically creates an outbox event.

### Step 1: Setup the Outbox Flow

```bash
./nifi-outbox-setup.sh
```

Expected output:
```
✓ Created Process Group
✓ Created DBCP, JSON Reader, JSON Writer
✓ All controller services enabled
✓ All processors configured
✓ All connections created
```

### Step 2: Start the Flow in NiFi

1. Open https://localhost:8443/nifi in your browser
2. Accept the self-signed certificate warning
3. Log in with your credentials from `.env`
4. Double-click the **"PostgreSQL Outbox Pattern"** process group
5. Press `Ctrl+A` to select all processors
6. Right-click → **Start**

All processor boxes should turn green with a play icon.

### Step 3: Generate Test Data

```bash
./test-outbox.sh
```

This inserts 5 test orders. The database trigger automatically creates outbox events.

### Step 4: Observe the Flow

**In NiFi UI:**
- Watch the "Queued" counters on connections increase briefly
- Data flows through: Poll → Convert → Split → Extract → Log/Delete

**In Terminal:**
```bash
# Watch NiFi process events
docker-compose logs -f nifi | grep OUTBOX_EVENT
```

**Check database:**
```bash
# Outbox should be empty after processing
docker exec postgres_cdc psql -U demo_user -d demo_db -c "SELECT * FROM outbox;"

# Orders should remain
docker exec postgres_cdc psql -U demo_user -d demo_db -c "SELECT * FROM orders;"
```

### Step 5: Continuous Testing

```bash
# Insert data every 5 seconds
./test-outbox.sh --continuous
```

---

## Part 2: Testing the CDC Pattern

CDC captures ALL database changes through PostgreSQL's logical replication.

### Step 1: Setup the CDC Flow

```bash
./nifi-cdc-setup.sh
```

### Step 2: Create the Replication Slot

```bash
./test-cdc.sh --setup
```

This creates the `nifi_cdc_slot` replication slot that NiFi will read from.

### Step 3: Start the Flow in NiFi

1. In NiFi UI, go back to the root canvas (breadcrumb at top)
2. Double-click **"PostgreSQL CDC Pattern"** process group
3. `Ctrl+A` → Right-click → **Start**

### Step 4: Generate CDC Events

```bash
./test-cdc.sh
```

This performs INSERT and UPDATE operations that generate CDC events.

### Step 5: Observe CDC Processing

**In Terminal:**
```bash
docker-compose logs -f nifi | grep CDC_CHANGE
```

**Important:** CDC events are **consumed** when NiFi reads them. To see more events, run `./test-cdc.sh` again after NiFi processes the current batch.

### Step 6: Continuous CDC Testing

```bash
./test-cdc.sh --continuous
```

---

## Running Both Patterns Simultaneously

Yes, you can run both patterns at the same time! They are independent:

| Pattern | Data Source | Use Case |
|---------|-------------|----------|
| **CDC** | Replication slot (all changes) | Audit logs, data sync |
| **Outbox** | Outbox table (explicit events) | Domain events, messaging |

### Start Both:

1. Start CDC flow in NiFi
2. Start Outbox flow in NiFi
3. Run both test scripts:

```bash
# Terminal 1: Outbox testing
./test-outbox.sh --continuous

# Terminal 2: CDC testing  
./test-cdc.sh --continuous

# Terminal 3: Watch all logs
docker-compose logs -f nifi | grep -E "OUTBOX_EVENT|CDC_CHANGE"
```

---

## Troubleshooting

### Run Diagnostics

```bash
./nifi-diagnose.sh
```

### Common Issues

**1. Processors show warnings (yellow triangle)**
- Usually means controller services aren't enabled
- Go to process group → hamburger menu → Controller Services
- Enable all disabled services

**2. "INVALID" validation status**
- Check the specific validation error in NiFi UI
- Often means a required property is missing

**3. No data flowing**
- Verify processors are started (green play icon)
- Check if there's data in the source (outbox table or replication slot)
- Check connections aren't full (back-pressure)

**4. CDC slot doesn't exist**
```bash
./test-cdc.sh --setup
```

**5. Database connection fails**
- Verify PostgreSQL is running: `docker ps`
- Check the `DB_HOST` parameter is set to `postgres` (Docker network name), not `localhost`

### Clean Restart

```bash
# Full reset
docker-compose down -v
docker-compose up -d

# Wait for NiFi
sleep 120

# Rebuild flows
./nifi-cdc-setup.sh
./nifi-outbox-setup.sh
./test-cdc.sh --setup
```

---

## Understanding the Flows

### Outbox Pattern Flow

```
Poll Outbox Table (QueryDatabaseTable)
         ↓ (Avro)
Convert to JSON (ConvertRecord)
         ↓ (JSON array)
Split Events (SplitJson)
         ↓ (individual JSON)
Extract Event Metadata (EvaluateJsonPath)
         ↓
    ┌────┴────┐
    ↓         ↓
Publish    Prepare Cleanup SQL
(Log)            ↓
           Delete from Outbox
```

### CDC Pattern Flow

```
Read CDC Slot (ExecuteSQL)
         ↓ (Avro - slot query results)
Convert to JSON (ConvertRecord)
         ↓ (JSON array)
Split Changes (SplitJson)
         ↓ (individual change)
Parse CDC Data (EvaluateJsonPath)
         ↓
Route Changes (RouteOnAttribute)
         ↓ (has_changes = true)
Log CDC Changes (LogAttribute)
```

---

## Next Steps

After testing, you can replace the `LogAttribute` processors with actual message brokers:

- **Kafka**: Use `PublishKafka` processor
- **RabbitMQ**: Use `PublishAMQP` processor  
- **AWS SNS/SQS**: Use respective AWS processors
- **HTTP Webhook**: Use `InvokeHTTP` processor