-- Where the sku-webhook Edge Function stores verified SKU.io webhook deliveries.

create table if not exists sku.webhook_deliveries (
  delivery_id uuid primary key,               -- a retry repeats it, so it is stored once
  event       text not null,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  is_test     boolean generated always as (coalesce((data ->> '_test')::boolean, false)) stored,
  data        jsonb not null
);
create index if not exists webhook_deliveries_event_idx on sku.webhook_deliveries (event, occurred_at desc);
alter table sku.webhook_deliveries enable row level security;   -- no policies: server code only

-- Latest level per product and warehouse. Deliveries can arrive out of order: changed_at decides.
create or replace view sku.stock_changes with (security_invoker = true) as
select distinct on (data ->> 'product_id', data ->> 'warehouse_id')
  (data ->> 'product_id')::bigint      as product_id,
  data ->> 'sku'                       as sku,
  data ->> 'warehouse_id'              as warehouse_id,
  data ->> 'warehouse_name'            as warehouse_name,
  (data ->> 'on_hand')::numeric        as on_hand,
  (data ->> 'available')::numeric      as available,
  (data ->> 'allocated')::numeric      as allocated,
  (data ->> 'in_transit')::numeric     as in_transit,
  (data ->> 'available_change')::numeric as available_change,
  (data ->> 'changed_at')::timestamptz as changed_at
from sku.webhook_deliveries
where event = 'inventory.level_changed' and not is_test
order by data ->> 'product_id', data ->> 'warehouse_id', (data ->> 'changed_at')::timestamptz desc;

create or replace view sku.shipments with (security_invoker = true) as
select delivery_id, occurred_at,
  data ->> 'order_number'       as order_number,
  data ->> 'warehouse_name'     as warehouse_name,
  data ->> 'fulfillment_number' as fulfillment_number,
  data ->> 'carrier'            as carrier,
  data ->> 'shipping_method'    as shipping_method,
  data ->> 'tracking_number'    as tracking_number,
  data ->> 'tracking_url'       as tracking_url,
  data -> 'lines'               as lines
from sku.webhook_deliveries
where event = 'fulfillment.shipped' and not is_test;

grant select on sku.webhook_deliveries, sku.stock_changes, sku.shipments to service_role;
