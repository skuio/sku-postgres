-- Refresh the cached tables on a schedule. Needs pg_cron (Database > Extensions).
--
-- API requests per refresh: stock 1 per 1,000 product-warehouse rows, products 1 per 100
-- products, sales orders 1 per 100 orders. Your SKU.io account allows 1,000 a minute.
-- With 20,000 products, the hourly products refresh is 200 requests.
--
-- A refresh that SKU.io rate limits waits and carries on, so give it time to finish.

create extension if not exists pg_cron;

select cron.schedule('sku-stock',        '*/5 * * * *',  $$ set statement_timeout = '10min'; select sku.refresh('stock') $$);
select cron.schedule('sku-sales-orders', '*/15 * * * *', $$ set statement_timeout = '10min'; select sku.refresh('sales_orders') $$);
select cron.schedule('sku-products',     '7 * * * *',    $$ set statement_timeout = '30min'; select sku.refresh('products') $$);

-- To stop: select cron.unschedule('sku-stock'); and the same for the other two.
