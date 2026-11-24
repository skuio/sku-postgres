-- Removes everything 01, 02 and 03 created, including stored webhook deliveries.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job where jobname in ('sku-stock', 'sku-sales-orders', 'sku-products');
  end if;
end $$;
drop schema if exists sku cascade;
drop server if exists sku_api cascade;
drop schema if exists sku_private cascade;
delete from vault.secrets where name = 'sku_api_token';
