# Security model

Every gate lives in Postgres. The Next.js layer trusts the database and does not re-implement authorisation logic.

## Access tiers

1. **Superadmin** — implicit. All access via the standard superadmin gate (`public.current_role() in ('superadmin', …)`). Never listed in the "granted access" table because they don't need to be granted.
2. **Granted user** — `profiles.can_access_otp = true`. Optionally has a `profiles.otp_limit` cap. Can see only their own request rows.
3. **Everyone else** — the page 404s / redirects at the layout level. RLS would deny them anyway, but the redirect skips the render entirely.

## What RLS enforces

| resource | select | insert | update | delete |
|---|---|---|---|---|
| `otp_requests` | owner OR superadmin | RPC only (server-side) | RPC only | RPC only |
| `sms_messages` | superadmin only | service-role (webhook) | never | superadmin only |
| `profiles.can_access_otp` | self OR admin+ | — | admin+ | — |
| `profiles.otp_limit` | self OR admin+ | — | superadmin only | — |

**No client SDK call can touch `otp_requests` or `sms_messages` directly** — every path goes through a `SECURITY DEFINER` RPC or the webhook. This means the "server code" you'd write in a Node/Rails app doesn't exist here — it's Postgres functions.

## The webhook (`/api/sms/ingest`)

```typescript
// Node.js runtime (Edge doesn't have subtle-crypto timingSafeEqual)
export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const provided = req.headers.get("x-sms-secret") ?? "";
  const expected = process.env.SMS_INGEST_SECRET!;
  // Constant-time comparison so a timing side-channel can't leak
  // the secret one byte at a time.
  const ok =
    provided.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(expected));
  if (!ok) return new Response("forbidden", { status: 403 });

  const { sender, body, received_at } = await req.json();
  await supabaseAdmin.from("sms_messages").insert({
    sender,
    body,
    received_at: received_at ?? new Date().toISOString(),
  });
  return new Response("ok");
}
```

- Shared secret, not a JWT — the Android forwarder can't run OAuth.
- `nodejs` runtime for `crypto.timingSafeEqual` (Edge runtime lacks it).
- The service-role client is scoped to this route only; nothing else uses `SUPABASE_SERVICE_ROLE_KEY` outside `/api/sms/ingest`, so a leaked route-handler bug doesn't grant broad access.

## Cap enforcement is dual-implemented

The client-side classifier (`lib/sms-classifier.ts`) decides what to display; the server-side classifier (`sms_extract_amount` + `sms_is_pre_auth` in PL/pgSQL) decides whether to transition to `fulfilled` or `over_limit`.

A malicious client could ignore the client classifier and just render whatever they want — but by the time they see the row, the trigger has already decided the status. If the row is `over_limit`, the SMS body is not exposed via the row (the `matched_sms_id` join to `sms_messages` is superadmin-only), so the client has no path to the OTP text either way.

## Reason field is mandatory + logged

`otp_requests.reason` is `NOT NULL` and check-constrained to 3..240 chars. The reason is displayed to the superadmin in the audit log with the exact SMS that satisfied it, so post-hoc "why did you use the card at Amazon at 2 AM" investigations have full context without querying the phone.

## Audit story

Every state transition is a UPDATE on `otp_requests` — the row itself IS the audit log. There is no separate `otp_audit` table because there is no state to reconstruct:

- `requested_at` = when the request was made
- `resolved_at` = when the trigger or user resolved it
- `wait_seconds` = generated column
- `status` = the terminal state
- `matched_sms_id` = the SMS that satisfied it (or null if cancelled)
- `limit_snapshot` = the cap in effect at request time

If the superadmin needs to see what a request looked like before it terminated, they'd need CDC / point-in-time recovery — but for the operational use case (who used the card, when, and for what), the row is enough.

## Delete semantics

- Deleting a `profiles` row cascades to their `otp_requests` (ON DELETE CASCADE).
- Deleting an `sms_messages` row sets `otp_requests.matched_sms_id` NULL (ON DELETE SET NULL). The `otp_requests` row keeps its `status`, `resolved_at`, and reason — you just lose the specific SMS body.

This means "delete this OTP from the audit" leaves behind a null-matched row with a status. That's intentional — the superadmin can see *that* a request was fulfilled without seeing *what* the SMS was.
