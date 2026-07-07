# SQL — every migration for the OTP module

Applied in numeric order. Each file is idempotent (`create or replace` / `if not exists`) so re-running is safe.

| file | what it does |
|---|---|
| [`0043_otp_access_permission.sql`](0043_otp_access_permission.sql) | Adds `profiles.can_access_otp boolean` + RLS so the column can be read by the owner. Widens `v_directory` to expose it. |
| [`0060_otp_requests.sql`](0060_otp_requests.sql) | Main table + `create_otp_request` / `fulfill_otp_request` / `cancel_otp_request` RPCs (all `SECURITY DEFINER`) + RLS. Adds to `supabase_realtime`. |
| [`0061_otp_limit.sql`](0061_otp_limit.sql) | Adds `profiles.otp_limit numeric` cap column. |
| [`0062_otp_auto_fulfill_trigger.sql`](0062_otp_auto_fulfill_trigger.sql) | The load-bearing after-INSERT trigger on `sms_messages` that auto-attributes to the oldest pending request. Uses `FOR UPDATE SKIP LOCKED` so concurrent inserts attribute to different requests. |
| [`0063_admin_cancel_otp_request.sql`](0063_admin_cancel_otp_request.sql) | Widens `cancel_otp_request` so superadmin+ can clear stuck pending rows. |
| [`0064_otp_over_limit_status.sql`](0064_otp_over_limit_status.sql) | Adds `over_limit` status + PL/pgSQL classifier helpers (`sms_extract_amount`, `sms_is_pre_auth`) mirroring the client-side TS classifier. Rewrites the trigger so pre-auth OTPs above the cap end up `over_limit`, not silently `fulfilled`. |

## Reading order for reviewers

If you're reading this as an interview / audit exercise, start with:

1. `0060_otp_requests.sql` — the shape of the world
2. `0062_otp_auto_fulfill_trigger.sql` — the interesting bit
3. `0064_otp_over_limit_status.sql` — the "we didn't get this right the first time" bit (and the fix)

Then `0063` (cancel widening) and `0061` (cap column) are trivial one-liners.
