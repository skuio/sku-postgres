// node --test tests/*.mjs   (Node 22.18+ runs the .ts file directly)
import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { matchesAnySecret, parseDelivery } from "../supabase/functions/sku-webhook/verify.ts";

const body = Buffer.from(JSON.stringify({
  event: "inventory.level_changed",
  delivery_id: "9f1c4a6e-2f4d-4b21-9a8e-6c0a1d3e5f70",
  occurred_at: "2026-11-13T14:02:11+00:00",
  data: { product_id: 164, available: 252 },
}));
const sign = (b, secret) => "sha256=" + createHmac("sha256", secret).update(b).digest("hex");

test("accepts the right secret, including as the second of two", async () => {
  assert.equal(await matchesAnySecret(body, sign(body, "b"), ["b"]), true);
  assert.equal(await matchesAnySecret(body, sign(body, "b"), ["a", "b"]), true);
});
test("refuses a wrong secret, a changed body, and missing or malformed headers", async () => {
  assert.equal(await matchesAnySecret(body, sign(body, "x"), ["a", "b"]), false);
  assert.equal(await matchesAnySecret(Buffer.concat([body, Buffer.from(" ")]), sign(body, "a"), ["a"]), false);
  for (const h of ["", "sha256=", "sha256=zz", sign(body, "a").slice(7)]) {
    assert.equal(await matchesAnySecret(body, h, ["a"]), false);
  }
});
test("parses a delivery and refuses anything else", () => {
  assert.equal(parseDelivery(body).event, "inventory.level_changed");
  for (const bad of ["nope", "null", "{}", '{"event":"x","delivery_id":"1","occurred_at":"2026-01-01","data":{}}']) {
    assert.equal(parseDelivery(Buffer.from(bad)), null);
  }
});
