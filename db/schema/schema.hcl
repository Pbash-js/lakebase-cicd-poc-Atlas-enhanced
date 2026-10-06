// Desired state: tables, columns, indexes, constraints, enums.
// Atlas CE plans changes between db/migrations replay and this state.
// Code objects (views, functions, procedures, triggers) stay in db/objects.
schema "public" {}

enum "order_status" {
  schema = schema.public
  values = ["new", "shipped", "cancelled"]
}

table "customers" {
  schema = schema.public
  column "customer_id" {
    type = bigint
    identity {
      generated = "ALWAYS"
    }
  }
  column "name" {
    type = text
    null = false
  }
  column "status" {
    type    = text
    null    = false
    default = "active"
  }
  primary_key {
    columns = [column.customer_id]
  }
}

table "orders" {
  schema = schema.public
  column "order_id" {
    type = bigint
    identity {
      generated = "ALWAYS"
    }
  }
  column "customer_id" {
    type = bigint
    null = false
  }
  column "status" {
    type    = text
    null    = false
    default = "new"
  }
  column "total_cents" {
    type    = bigint
    null    = false
    default = 0
  }
  column "created_at" {
    type    = timestamptz
    null    = false
    default = sql("now()")
  }
  column "note" {
    type    = text
    null    = false
    default = ""
  }
  primary_key {
    columns = [column.order_id]
  }
  foreign_key "orders_customer_id_fkey" {
    columns     = [column.customer_id]
    ref_columns = [table.customers.column.customer_id]
  }
  index "idx_orders_customer" {
    columns = [column.customer_id]
  }
}

table "shipments" {
  schema = schema.public
  column "shipment_id" {
    type = bigint
    identity {
      generated = "ALWAYS"
    }
  }
  column "order_id" {
    type = bigint
    null = false
  }
  column "carrier" {
    type    = text
    null    = false
    default = "blue-dart"
  }
  column "status" {
    type    = text
    null    = false
    default = "pending"
  }
  column "shipped_at" {
    type = timestamptz
    null = true
  }
  primary_key {
    columns = [column.shipment_id]
  }
  foreign_key "shipments_order_id_fkey" {
    columns     = [column.order_id]
    ref_columns = [table.orders.column.order_id]
  }
}
