# SKU.io for Postgres

Read your [SKU.io](https://www.sku.io) stock, products, costs and sales orders as tables in your
own [Supabase](https://supabase.com) database.

If you are building a tool for your team on Supabase, it probably needs to know what is in stock
and what it cost. This puts those numbers in SQL, so your app uses the ones SKU.io already keeps
instead of working them out again.

```sql
select sku, warehouse_name, available, on_hand, inbound
from sku.stock
where available < 10 and inbound = 0
order by available;
```

It is read-only. The API token you give it has read scopes only, and the Postgres wrapper it uses
refuses inserts, updates and deletes.

## What you get

| Table | What is in it | API requests per refresh |
|---|---|---|
| `sku.stock` | One row per product per warehouse: available, allocated, on hold, on hand, in transit, backorder, inbound | 1 per 1,000 rows |
| `sku.products` | Products with brand, supplier, costs, price and stock totals | 1 per 100 products |
| `sku.costs` | Unit cost, average cost, supplier price and stock value per product | None: reads `sku.products` |
| `sku.sales_orders` | The last 90 days of sales orders | 1 per 100 orders |
| `sku.order_lines(id)` | The lines of one order, read live | 1 per call |
| `sku.refresh_status` | When each table was last refreshed, and the error if the last try failed | None |

The tables are materialized views: queries read the copy in your database, and only a refresh calls
SKU.io. If a refresh cannot read everything, the previous copy stays.

With the optional webhook function you also get `sku.stock_changes` and `sku.shipments`, updated as
SKU.io sends them.

## Install

You need a Supabase project on Wrappers 0.6.2 or newer (**Database > Extensions**) and a SKU.io
account.

**1. Create a SKU.io token.** In SKU.io, go to **Settings > Developer > Personal Access Tokens** and
create a token with exactly these scopes: `products:read`, `orders:read`, `reports:read`. Leave the
IP allowlist empty unless your project has a fixed outbound address.

**2. Store it in Vault.** In the Supabase SQL editor, run this on its own and do not save it:

```sql
select vault.create_secret('<your token>', 'sku_api_token');
```

**3. Install.** Open [`sql/01_install.sql`](sql/01_install.sql), replace `YOUR-SUBDOMAIN` with the
part before `.sku.io` in your SKU.io address, and run the whole file. It loads the tables and prints
how many rows each one has.

**4. Keep it fresh.** Run [`sql/02_schedule.sql`](sql/02_schedule.sql). Stock refreshes every 5
minutes, orders every 15, products every hour.

## Use it in your app

Server code with the service role can read the `sku` schema over a Postgres connection. Browsers
cannot see it at all until you decide what to show. Materialized views have no row-level security,
so expose a narrow view, and remove the access Supabase gives `anon` by default:

```sql
create view public.stock_by_sku as
  select sku, sum(available) as available from sku.stock group by sku;

revoke all on public.stock_by_sku from anon, authenticated;
grant select on public.stock_by_sku to authenticated;
```

Every signed-in user can now read that view, so leave costs out of it.

## Webhooks (optional)

Use these when five minutes is too long to wait.

1. Run [`sql/03_webhooks.sql`](sql/03_webhooks.sql).
2. Copy [`supabase/functions/sku-webhook`](supabase/functions/sku-webhook) into your project, and add
   the lines in [`supabase/config.toml.example`](supabase/config.toml.example) to your `config.toml`.
   SKU.io does not send a Supabase JWT. The function checks SKU.io's signature instead.
3. Deploy with `supabase functions deploy sku-webhook`. It answers 500 until step 5.
4. In SKU.io, go to **Settings > Developer > Webhooks** and create one webhook for **Stock Level
   Changed** and one for **Shipment Sent**, both with your function's URL. Copy each signing secret.
   It is shown once.
5. `supabase secrets set SKU_WEBHOOK_SECRETS=<first>,<second>`
6. Open each webhook in SKU.io and click **Send test delivery**.

The function checks the HMAC signature over the raw body, stores each `delivery_id` once, and
answers with an error if it could not store it so that SKU.io retries. Any SKU.io event you point at
it is stored in `sku.webhook_deliveries`.

**Personal data:** order and shipment events include the customer's name and email, and they are
stored as sent. `sku.sales_orders` leaves out customer email, phone and street address.

## Limits

- **Read-only.** To change anything in SKU.io, call the [API](https://developer.sku.io).
- **Orders are the last 90 days** and do not include lines. Change `past_days` in the install file
  for a longer window. `sku.order_lines(id)` makes one API call per order, so use it on a detail
  page and not in a join.
- **Rate limit.** A SKU.io user can make 1,000 API requests a minute across all of their tokens. A
  refresh that is limited waits and tries each request again up to three times.
- **Size.** Against a mock API on the same machine, 60,000 stock rows took 43 seconds to refresh and
  20,000 products took 5. Add your account's response time, roughly half a second per request.
- **Offset paging.** A record deleted while a refresh is reading can make it stop and keep the
  previous copy. The next run picks it up.
- **Do not query the `sku_private` tables with your own `where` clauses.** See below.

## Why not plain foreign tables?

The [OpenAPI wrapper](https://supabase.com/docs/guides/database/extensions/wrappers/openapi) can map
an endpoint straight to a table. We tried that first against the SKU.io API:

| Plain foreign table | What happened |
|---|---|
| `where order_status = 'nonsense'` | Returned every order, all labeled `nonsense`. The wrapper sends `?order_status=`, which is not a SKU.io filter (those are `filter[order_status]`), and then reports your own value back for each row. |
| `where id = 267` | Returned nothing. It asks for `/list/267`, which does not exist, and treats the 404 as no rows. |
| `select count(*)` on stock | Returned the first page only. That endpoint reports page numbers and no next link, so the wrapper stops. |
| `import foreign schema` | Our full OpenAPI file is over the wrapper's 50 MB limit. With a shortened file it imports the page envelope (`data`, `total`) and not the rows. |

So each foreign table here has no filterable columns and returns a whole page as `jsonb`. One
function reads the pages and checks the row count against the total SKU.io reports. Your queries run
on the cached result, where `where` means what it says.

## Change the token

```sql
select vault.update_secret((select id from vault.secrets where name = 'sku_api_token'), '<new token>');
```

## Remove it

Run [`sql/99_uninstall.sql`](sql/99_uninstall.sql), then revoke the token in SKU.io.

## Test

`node --test tests/*.mjs` checks the webhook signature code (Node 22.18 or newer).

Checked on 24 November 2026 with Supabase CLI 3.3.0, Postgres 17, Wrappers 0.6.3 and OpenAPI wrapper
0.2.1. The install file pins the wrapper's version and checksum.

## Help

Open an issue here, or write to [support@sku.io](mailto:support@sku.io). MIT license.
