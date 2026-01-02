-- Enable logical replication
ALTER SYSTEM SET wal_level = 'logical';
-- Increase max replication slots
ALTER SYSTEM SET max_replication_slots = 10;
-- Increase max_wal_senders to support more replication connections
ALTER SYSTEM SET max_wal_senders = 10;
-- Set max_slot_wal_keep_size to prevent WAL file bloat
ALTER SYSTEM SET max_slot_wal_keep_size = '20GB';

-- Create the business/order table
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_name VARCHAR(255) NOT NULL,
    product VARCHAR(255) NOT NULL,
    quantity INTEGER NOT NULL,
    total_amount DECIMAL(10, 2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create the outbox table
CREATE TABLE outbox (
    id SERIAL PRIMARY KEY,
    aggregate_type VARCHAR(255) NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(255) NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for efficient CDC
CREATE INDEX idx_outbox_created_at ON outbox(created_at);

-- Function to automatically create outbox events
CREATE OR REPLACE FUNCTION create_order_event()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
        'Order',
        NEW.id::TEXT,
        TG_OP,
        jsonb_build_object(
            'id', NEW.id,
            'customer_name', NEW.customer_name,
            'product', NEW.product,
            'quantity', NEW.quantity,
            'total_amount', NEW.total_amount,
            'created_at', NEW.created_at
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to capture order changes
CREATE TRIGGER order_outbox_trigger
AFTER INSERT OR UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION create_order_event();

-- Create publication for logical replication
CREATE PUBLICATION outbox_publication FOR TABLE outbox;

-- Grant necessary permissions
-- Make sure to replace 'demo_user' with the actual database user in your .env file
GRANT SELECT ON outbox TO demo_user;
GRANT USAGE ON SEQUENCE outbox_id_seq TO demo_user;
