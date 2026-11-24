// Receives SKU.io webhooks, checks the signature, and stores each delivery once.
//
// Secret: SKU_WEBHOOK_SECRETS, the signing secrets of your SKU.io subscriptions, comma
// separated. Each subscription has its own secret, shown once when you create it.
// SUPABASE_DB_URL is set for you.

import postgres from "npm:postgres@3.4.7";
import { matchesAnySecret, parseDelivery } from "./verify.ts";

const secrets = (Deno.env.get("SKU_WEBHOOK_SECRETS") ?? "")
  .split(",").map((s) => s.trim()).filter(Boolean);
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1, prepare: false });

const MAX_BYTES = 1_000_000;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (secrets.length === 0) return new Response("SKU_WEBHOOK_SECRETS is not set", { status: 500 });
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BYTES) {
    return new Response("Too large", { status: 413 });
  }

  // The signature covers the exact bytes sent, so read them before parsing.
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_BYTES) return new Response("Too large", { status: 413 });

  if (!await matchesAnySecret(raw, req.headers.get("x-sku-signature") ?? "", secrets)) {
    return new Response("Bad signature", { status: 401 });
  }

  const delivery = parseDelivery(raw);
  if (!delivery) return new Response("Not a SKU.io delivery", { status: 422 });

  try {
    await sql`
      insert into sku.webhook_deliveries (delivery_id, event, occurred_at, data)
      values (${delivery.delivery_id}, ${delivery.event}, ${delivery.occurred_at}, ${sql.json(delivery.data)})
      on conflict (delivery_id) do nothing`;
  } catch (e) {
    // A non-2xx answer makes SKU.io retry after 30 seconds, then 5 minutes.
    console.error("not stored", delivery.delivery_id, e instanceof Error ? e.message : e);
    return new Response("Not stored", { status: 500 });
  }

  return new Response("ok");
});
