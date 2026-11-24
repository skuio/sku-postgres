export type Delivery = {
  event: string;
  delivery_id: string;
  occurred_at: string;
  // deno-lint-ignore no-explicit-any
  data: any;
};

const encoder = new TextEncoder();

/** True when `header` is `sha256=<hex HMAC-SHA256 of the raw body>` for one of the secrets. */
export async function matchesAnySecret(raw: Uint8Array, header: string, secrets: string[]): Promise<boolean> {
  const match = /^sha256=([0-9a-f]{64})$/i.exec(header);
  if (!match) return false;
  const signature = Uint8Array.from(match[1].match(/../g)!, (h) => parseInt(h, 16));

  let ok = false;
  for (const secret of secrets) {
    const key = await crypto.subtle.importKey(
      "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
    );
    // crypto.subtle.verify compares in constant time. No early exit, on purpose.
    if (await crypto.subtle.verify("HMAC", key, signature, raw)) ok = true;
  }
  return ok;
}

const UUID = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

export function parseDelivery(raw: Uint8Array): Delivery | null {
  let body: Delivery;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return null;
  }
  if (!body || typeof body.event !== "string" || !UUID.test(body.delivery_id ?? "")) return null;
  if (Number.isNaN(Date.parse(body.occurred_at)) || typeof body.data !== "object" || body.data === null) return null;
  return body;
}
