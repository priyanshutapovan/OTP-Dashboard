# Architecture

The OTP module is a **three-tier request/response pipeline** with a database-level auto-attribution safety net.

## Actors

| actor | permission | what they do |
|---|---|---|
| **Superadmin** | implicit; not listed in the grant table | grants/revokes access, sets caps, watches the full inbox, reads the audit log |
| **Granted user** | `profiles.can_access_otp = true` (+ optional `otp_limit`) | requests an OTP with a reason, sees only their own row's status |
| **SMS forwarder** | shared-secret header on `/api/sms/ingest` | POSTs every arriving SMS to the platform; no interactive login |
| **Everyone else** | — | 404 / redirect to `/home` |

## Data flow (happy path)

1. **User request**
   ```
   Client → RPC: create_otp_request(reason, limit_snapshot)
   Server → INSERT INTO otp_requests
              (user_id, reason, status='pending', requested_at=now())
   Client ← { id, requested_at }
   ```
   The RPC is `SECURITY DEFINER` — the user never has direct INSERT on `otp_requests`. This guarantees the row can't skip fields or forge a status.

2. **Wait**
   ```
   Client subscribes to Realtime:
     table = otp_requests, filter = id=eq.<row-id>
   ```
   A local countdown ticks. If the tab is closed and reopened, the client re-subscribes and immediately re-reads the row (any state transition that happened while offline is instantly reflected).

3. **SMS arrives on the phone**
   ```
   Android forwarder → POST /api/sms/ingest
     Headers:
       X-Sms-Secret: <shared-secret>
     Body:
       { sender, body, received_at }
   API route (Vercel):
     verify header
     supabaseAdmin.from('sms_messages').insert({sender, body, received_at})
   ```
   The service-role key is scoped to this route only.

4. **Auto-attribution trigger** (server-side, always fires)
   ```
   AFTER INSERT ON sms_messages
   FOR EACH ROW
   EXECUTE FUNCTION tg_attribute_sms_to_otp_request();
   ```
   The trigger:
   - `SELECT * FROM otp_requests WHERE status='pending' ORDER BY requested_at ASC LIMIT 1 FOR UPDATE SKIP LOCKED`
   - Reads the owner's `profiles.otp_limit`
   - Runs `sms_extract_amount(body)` + `sms_is_pre_auth(body)` (both PL/pgSQL — mirror the TS classifier in `lib/sms-classifier.ts`)
   - If pre-auth amount > cap → `UPDATE otp_requests SET status='over_limit', matched_sms_id=NEW.id`
   - Otherwise → `UPDATE ... SET status='fulfilled', matched_sms_id=NEW.id`

5. **Client sees the update**
   Realtime pushes the changed row. If `fulfilled`, the client renders the SMS body. If `over_limit`, an explicit "OTP blocked — waiting for a smaller one" notice appears and the wait resumes.

## Why the trigger, when the client also claims

The client-side flow **also** calls a `fulfill_otp_request` RPC when it sees an incoming SMS via realtime. Two claim paths sound redundant — they aren't:

- The trigger is the **authoritative** claim. It runs in the same transaction as the SMS insert, uses `FOR UPDATE SKIP LOCKED` so concurrent inserts attribute to different rows deterministically, and cannot be bypassed.
- The client RPC exists only for **latency**. If the tab is active, the RPC often lands a few ms before the trigger, so the row is already fulfilled by the time the trigger tries to claim it — the trigger's `WHERE status='pending'` short-circuits harmlessly.

If the client tab is closed / offline, the trigger is the only path, and it always fires because the SMS insert always fires. Result: no request can ever sit `pending` forever if an SMS was received.

## Cancellation paths

- The **user** can cancel their own pending row (RPC `cancel_otp_request(id)` — RLS-gated so they can only cancel their own).
- The **superadmin** can cancel *any* pending row (RPC widened in migration `0063` to allow non-owner cancel for superadmin+). Used to clear stuck rows when the phone is offline or the SIM is inactive.

## Realtime scoping

RLS is honored by realtime. The subscription filter `id=eq.<row-id>` only receives the row the user owns; other pending rows from other users don't leak into the subscription because they'd fail the RLS predicate.

The superadmin subscription is unfiltered — they see every transition.

## Wait duration accounting

The `otp_requests` table stores `requested_at` and `resolved_at`. `wait_seconds` is a generated column: `EXTRACT(EPOCH FROM (resolved_at - requested_at))::int`. The audit-log tab surfaces it as a right-aligned tabular number so patterns (median wait, worst wait) pop when sorted.

## Rate-limit / abuse story

Each user can only have **one pending row at a time** (unique partial index `WHERE status='pending'`). This is enforced at the schema level, so a client that hammers the RPC just sees `23505: duplicate key value violates unique constraint`.

There is no throttle beyond this — the SIM inbox is the natural bottleneck.

## What's deliberately NOT here

- **No OTP storage.** The SMS body is stored, but the OTP is not extracted, indexed, or made searchable. Deleting an `sms_messages` row deletes the OTP.
- **No SMS forwarding to external services.** Everything happens inside Supabase; no third-party OTP router.
- **No password / 2FA integration.** This isn't for user authentication — it's for shared-card transaction OTPs the finance team hands out.
