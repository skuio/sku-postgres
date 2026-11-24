-- SKU.io for Postgres: read-only tables over the SKU.io API.
--
-- Before you run this file, store your read-only SKU.io token in Vault, in its own
-- query, so it never ends up in a saved script:
--
--   select vault.create_secret('<your SKU.io token>', 'sku_api_token');
--
-- Then set your subdomain on the line marked below and run the whole file.
-- Running it again rebuilds the tables below and keeps webhook deliveries. It also drops
-- any view of your own that reads them, so keep those views in a script you can rerun.

create extension if not exists wrappers with schema extensions;

do $$
begin
  if not exists (select 1 from pg_foreign_data_wrapper where fdwname = 'wasm_wrapper') then
    create foreign data wrapper wasm_wrapper
      handler extensions.wasm_fdw_handler
      validator extensions.wasm_fdw_validator;
  end if;
end $$;

-- sku          the tables you query
-- sku_private  the API plumbing. Never add this schema to your project's exposed schemas.
create schema if not exists sku;
create schema if not exists sku_private;
revoke all on schema sku, sku_private from public, anon, authenticated;

do $$
declare
  v_subdomain text := 'YOUR-SUBDOMAIN';   -- <-- acme, if you sign in at https://acme.sku.io
  v_secret    uuid;
begin
  if v_subdomain !~ '^[a-z0-9-]+(\.[a-z0-9-]+)*$' then
    raise exception 'Set v_subdomain to the part before .sku.io in your SKU.io address (got %)', v_subdomain;
  end if;

  select id into v_secret from vault.secrets where name = 'sku_api_token';
  if v_secret is null then
    raise exception 'No Vault secret named sku_api_token. Create it first: see the top of this file.';
  end if;

  drop server if exists sku_api cascade;

  execute format($sql$
    create server sku_api foreign data wrapper wasm_wrapper options (
      fdw_package_url      'https://github.com/supabase/wrappers/releases/download/wasm_openapi_fdw_v0.2.1/openapi_fdw.wasm',
      fdw_package_name     'supabase:openapi-fdw',
      fdw_package_version  '0.2.1',
      fdw_package_checksum '12c902f3089e18142a1d8d35c66b9ceb85c193224229687bd929aff6b44cddde',
      base_url             %L,
      bearer_token_id      %L,
      accept               'application/json',
      user_agent           'sku-postgres/0.1',
      max_pages            '10000'
    )$sql$, 'https://' || v_subdomain || '.sku.io', v_secret);
end $$;

-- Raw pages ------------------------------------------------------------------------------
--
-- One row per page: response_path '' hands over the whole response, so a page arrives with
-- its own totals. Products and orders return a link to the next page, which the wrapper
-- follows inside one scan. The stock endpoint returns page numbers and no link, so it has a
-- `page` column, which the wrapper sends to the API as ?page=.
--
-- Do not add more columns here. The wrapper sends any `where column = value` as a plain
-- ?column=value parameter and then reports that value back for every row, whether or not
-- the API filtered on it. SKU.io filters use filter[column], so an added `order_status`
-- column would make `where order_status = 'closed'` return every order, all labeled closed.

create foreign table sku_private.stock_pages (page integer, attrs jsonb)
  server sku_api options (
    endpoint '/api/reporting/realtime-inventory?per_page=1000', response_path '');

create foreign table sku_private.product_pages (attrs jsonb)
  server sku_api options (
    endpoint '/api/v2/products?per_page=100&sort=id', response_path '', cursor_path '/next_page_url');

-- Orders from the last 90 days. Change past_days to keep more or fewer.
create foreign table sku_private.sales_order_pages (attrs jsonb)
  server sku_api options (
    endpoint '/api/sales-orders/list?per_page=100&sort=id&filter[order_date.past_days]=90',
    response_path '', cursor_path '/next_page_url');

create foreign table sku_private.sales_order_line_pages (sales_order_id bigint, attrs jsonb)
  server sku_api options (
    endpoint '/api/sales-orders/{sales_order_id}/line-items', response_path '');

-- Page walker ----------------------------------------------------------------------------
--
-- Reads every page and raises if it ends up with fewer different rows than the API said
-- there were. A failed read therefore never replaces a good cached copy with a short one.
-- A row can come back twice when something is added mid-read: the tables below use
-- `distinct on` to keep one.

create or replace function sku_private.fetch_rows(
  source     regclass,
  items_path text[],      -- where the rows are in a response
  meta_path  text[],      -- where total and last_page are
  key_paths  text[],      -- the fields that identify a row, each as 'a' or 'a,b' for a nested one
  by_number  boolean default false  -- ask for pages one by one, when the API returns no next link
) returns setof jsonb
language plpgsql volatile
set search_path = ''
as $$
declare
  v_page     integer := 1;
  v_last     integer;
  v_total    bigint := 0;
  v_envelope jsonb;
  v_keys     text[] := '{}';
  v_count    bigint;
begin
  loop
    v_last := null;

    for v_envelope in execute
      format('select attrs from %s', source) || case when by_number then format(' where page = %L', v_page) else '' end
    loop
      v_last := (v_envelope #>> (meta_path || '{last_page}'::text[]))::integer;
      if v_last is null or jsonb_typeof(v_envelope #> items_path) is distinct from 'array' then
        raise exception 'SKU.io: unexpected response from %', source;
      end if;
      v_total := greatest(v_total, (v_envelope #>> (meta_path || '{total}'::text[]))::bigint);

      return query select jsonb_array_elements(v_envelope #> items_path);

      v_keys := v_keys || array(
        select (select string_agg(coalesce(r #>> string_to_array(k, ','), ''), '|' order by n)
                from unnest(key_paths) with ordinality as u(k, n))
        from jsonb_array_elements(v_envelope #> items_path) as r);
    end loop;

    if v_last is null then
      raise exception 'SKU.io: no data from %. The endpoint may not be available to this account.', source;
    end if;

    exit when not by_number or v_page >= v_last;
    v_page := v_page + 1;
  end loop;

  select count(distinct k) into v_count from unnest(v_keys) as k;
  if v_count < v_total then
    raise exception 'SKU.io: read % of % rows from %. Nothing was replaced; the next refresh will try again.', v_count, v_total, source;
  end if;
end $$;

revoke all on function sku_private.fetch_rows(regclass, text[], text[], text[], boolean) from public, anon, authenticated;

-- Cached tables --------------------------------------------------------------------------

drop materialized view if exists sku.stock;
create materialized view sku.stock as
select distinct on (r #>> '{product,id}', r #>> '{warehouse,id}')
  (r #>> '{product,id}')::bigint                       as product_id,
  r #>> '{product,sku}'                                as sku,
  r #>> '{product,name}'                               as product_name,
  r #>> '{warehouse,id}'                               as warehouse_id,
  r #>> '{warehouse,name}'                             as warehouse_name,
  (r #>> '{inventory,available}')::numeric             as available,
  (r #>> '{inventory,allocated}')::numeric             as allocated,
  (r #>> '{inventory,on_hold}')::numeric               as on_hold,
  (r #>> '{inventory,available}')::numeric
    + (r #>> '{inventory,allocated}')::numeric
    + (r #>> '{inventory,on_hold}')::numeric           as on_hand,
  (r #>> '{inventory,in_transit}')::numeric            as in_transit,
  (r #>> '{inventory,backorder}')::numeric             as backorder,
  (r #>> '{inventory,inbound}')::numeric               as inbound,
  (r #>> '{inventory,projected_total}')::numeric       as projected_total
from sku_private.fetch_rows('sku_private.stock_pages', '{data,items}', '{data,pagination}',
                            '{"product,id","warehouse,id"}', by_number => true) as r
with no data;
create unique index on sku.stock (product_id, warehouse_id);
create index on sku.stock (sku);

drop view if exists sku.costs;
drop materialized view if exists sku.products;
create materialized view sku.products as
select distinct on (r ->> 'id')
  (r ->> 'id')::bigint                    as id,
  r ->> 'sku'                             as sku,
  r ->> 'name'                            as name,
  r ->> 'type'                            as type,
  r ->> 'barcode'                         as barcode,
  r ->> 'mpn'                             as mpn,
  r ->> 'brand_name'                      as brand,
  r ->> 'default_supplier_name'           as default_supplier,
  r ->> 'default_supplier_sku'            as default_supplier_sku,
  (r ->> 'weight')::numeric               as weight,
  r ->> 'weight_unit'                     as weight_unit,
  (r ->> 'unit_cost')::numeric            as unit_cost,
  (r ->> 'average_cost')::numeric         as average_cost,
  (r ->> 'default_supplier_price')::numeric as default_supplier_price,
  (r ->> 'default_price')::numeric        as default_price,
  (r ->> 'inventory_total')::numeric      as inventory_total,
  (r ->> 'inventory_available')::numeric  as inventory_available,
  (r ->> 'inventory_incoming')::numeric   as inventory_incoming,
  (r ->> 'inventory_stock_value')::numeric as inventory_stock_value,
  r ->> 'lifecycle_state'                 as lifecycle_state,
  (r ->> 'created_at')::timestamptz       as created_at,
  (r ->> 'updated_at')::timestamptz       as updated_at
from sku_private.fetch_rows('sku_private.product_pages', '{data}', '{}', '{id}') as r
with no data;
create unique index on sku.products (id);
create index on sku.products (sku);

-- Same API calls as sku.products, so it costs nothing extra.
create view sku.costs as
select id as product_id, sku, name, unit_cost, average_cost, default_supplier_price,
       default_price, inventory_total, inventory_stock_value
from sku.products;

-- Customer email, phone and street address are in the API response and left out on purpose.
drop materialized view if exists sku.sales_orders;
create materialized view sku.sales_orders as
select distinct on (r ->> 'id')
  (r ->> 'id')::bigint                    as id,
  r ->> 'sales_order_number'              as sales_order_number,
  r ->> 'order_status'                    as order_status,
  r ->> 'fulfillment_status'              as fulfillment_status,
  r ->> 'payment_status'                  as payment_status,
  r ->> 'sales_channel_name'              as sales_channel,
  r #>> '{store,name}'                    as store,
  r #>> '{customer_name,name}'            as customer_name,
  r ->> 'shipping_province'               as ship_to_province,
  r ->> 'shipping_country'                as ship_to_country,
  (r ->> 'order_date')::timestamptz       as order_date,
  (r ->> 'fulfilled_at')::timestamptz     as fulfilled_at,
  r ->> 'currency_code'                   as currency_code,
  (r ->> 'subtotal')::numeric             as subtotal,
  (r ->> 'tax_total')::numeric            as tax_total,
  (r ->> 'discount_total')::numeric       as discount_total,
  (r ->> 'total')::numeric                as total,
  (r ->> 'line_item_count')::integer      as line_item_count,
  (r ->> 'total_quantity')::numeric       as total_quantity,
  r ->> 'warehouse_names'                 as warehouses,
  r ->> 'tracking_number'                 as tracking_number,
  (r ->> 'created_at')::timestamptz       as created_at,
  (r ->> 'updated_at')::timestamptz       as updated_at
from sku_private.fetch_rows('sku_private.sales_order_pages', '{data}', '{}', '{id}') as r
with no data;
create unique index on sku.sales_orders (id);
create index on sku.sales_orders (order_date);

-- One live API call per order: the order list has no lines. Use it for a detail page, not a join.
create or replace function sku.order_lines(p_order_id bigint)
returns table (line_id bigint, product_id bigint, sku text, description text, quantity numeric,
               fulfilled_quantity numeric, amount numeric, line_total numeric, warehouse_name text)
language plpgsql volatile security definer
set search_path = ''
as $$
declare v_envelope jsonb;
begin
  execute format('select attrs from sku_private.sales_order_line_pages where sales_order_id = %L', p_order_id)
    into v_envelope;
  return query
    select (l ->> 'id')::bigint, (l ->> 'product_id')::bigint, l ->> 'sku', l ->> 'description',
           (l ->> 'quantity')::numeric, (l ->> 'fulfilled_quantity')::numeric,
           (l ->> 'amount')::numeric, (l ->> 'line_total')::numeric, l ->> 'warehouse_name'
    from jsonb_array_elements(v_envelope -> 'data') as l;
end $$;
revoke all on function sku.order_lines(bigint) from public, anon, authenticated;

-- Refresh --------------------------------------------------------------------------------

create table if not exists sku_private.refresh_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  started_at  timestamptz not null,
  finished_at timestamptz not null,
  ok          boolean not null,
  row_count   bigint,
  error       text
);

-- Returns false, and leaves the cached copy as it was, when SKU.io could not be read in full.
create or replace function sku.refresh(p_table text) returns boolean
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_start timestamptz := clock_timestamp();
  v_rows  bigint;
begin
  if p_table not in ('stock', 'products', 'sales_orders') then
    raise exception 'sku.refresh takes stock, products or sales_orders (got %)', p_table;
  end if;

  begin
    if (select ispopulated from pg_catalog.pg_matviews where schemaname = 'sku' and matviewname = p_table) then
      execute format('refresh materialized view concurrently sku.%I', p_table);
    else
      execute format('refresh materialized view sku.%I', p_table);
    end if;
    execute format('select count(*) from sku.%I', p_table) into v_rows;
  exception when others then
    insert into sku_private.refresh_log (table_name, started_at, finished_at, ok, error)
      values (p_table, v_start, clock_timestamp(), false, sqlerrm);
    raise warning 'sku.% not refreshed: %', p_table, sqlerrm;
    return false;
  end;

  insert into sku_private.refresh_log (table_name, started_at, finished_at, ok, row_count)
    values (p_table, v_start, clock_timestamp(), true, v_rows);
  delete from sku_private.refresh_log where started_at < now() - interval '14 days';
  return true;
end $$;
revoke all on function sku.refresh(text) from public, anon, authenticated;

-- How fresh each table is, and why the last try failed if it did.
create or replace view sku.refresh_status as
select t.table_name,
       (select max(finished_at) from sku_private.refresh_log l where l.table_name = t.table_name and l.ok) as last_refreshed_at,
       last.ok as last_try_ok, last.row_count, last.error,
       round(extract(epoch from last.finished_at - last.started_at)::numeric, 1) as seconds
from (values ('stock'), ('products'), ('sales_orders')) as t(table_name)
left join lateral (
  select * from sku_private.refresh_log l where l.table_name = t.table_name order by id desc limit 1
) as last on true;

-- Your server code (the service_role key) can read. Browsers cannot: grant that per app.
grant usage on schema sku to service_role;
grant select on all tables in schema sku to service_role;
grant execute on function sku.order_lines(bigint), sku.refresh(text) to service_role;

-- First load.
select sku.refresh('stock') as stock, sku.refresh('products') as products, sku.refresh('sales_orders') as sales_orders;
select * from sku.refresh_status;
