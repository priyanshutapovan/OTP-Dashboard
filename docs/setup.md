# Setup

This showcase is illustrative — the code is anonymised excerpts of a private production platform, not a self-contained runnable app. If you want to spin up the OTP subsystem in isolation, these are the pieces you need to assemble.

## Prerequisites

- **Supabase project** (free tier fine)
- **Next.js 15** app with Supabase auth already wired up
- **An Android phone with an SMS forwarder** — the platform uses [SMS Forwarder](https://github.com/keinerweiss/smsforwarder) with regex filters for banking senders. Any tool that can POST JSON works.

## Environment variables

```bash
NEXT_PUBLIC_SUPABASE_URL=https://<project>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon-key>
SUPABASE_SERVICE_ROLE_KEY=<service-role-key>    # server-only
SMS_INGEST_SECRET=<random-256-bit-hex>          # shared with the phone
```

Generate `SMS_INGEST_SECRET` with `openssl rand -hex 32`. Store it in Vercel + on the phone forwarder's config — nowhere else.

## Database

Apply migrations in this order (all in [`../code-samples/sql/`](../code-samples/sql)):

1. `0043_otp_access_permission.sql` — adds `profiles.can_access_otp`
2. `0060_otp_requests.sql` — creates the table + RPCs
3. `0061_otp_limit.sql` — adds the per-user cap
4. `0062_otp_auto_fulfill_trigger.sql` — the auto-attribution trigger
5. `0063_admin_cancel_otp_request.sql` — widens the cancel RPC
6. `0064_otp_over_limit_status.sql` — adds the `over_limit` status + cap logic

Each is idempotent — re-running is safe.

## Phone forwarder config

The forwarder POSTs to your Vercel deployment:

```
URL:      https://<your-domain>/api/sms/ingest
Method:   POST
Headers:  X-Sms-Secret: <same value as SMS_INGEST_SECRET>
          Content-Type: application/json
Body:     {
            "sender": "{sender}",
            "body":   "{body}",
            "received_at": "{timestamp}"
          }
```

Filter senders to your bank + payment gateway shortcodes so the forwarder doesn't ship every promotional SMS to the platform.

## Local dev

```bash
npm install
npm run dev
```

Sign in as a superadmin, go to `/admin/otp`, grant access to a test user with a small cap (e.g. 1000). Impersonate the test user, tap "Request OTP", and either:

- Send the phone a real SMS (best e2e verification)
- Or POST directly to your local `/api/sms/ingest` with a synthetic body:

  ```bash
  curl -X POST http://localhost:3000/api/sms/ingest \
    -H "X-Sms-Secret: $SMS_INGEST_SECRET" \
    -H "Content-Type: application/json" \
    -d '{"sender":"BANK","body":"Rs 250 spent using ICICI Bank Card XX6303 on Amazon. OTP: 439201"}'
  ```

The trigger will attribute the SMS to your pending row within a few ms; realtime pushes the transition to the user's browser.

To test the cap: set `otp_limit=100`, request an OTP, then POST an SMS with amount > 100. The row should end up `over_limit`, not `fulfilled`.

## Deploying

Nothing OTP-specific. Deploy the parent Next.js app to Vercel; the migrations land via Supabase CLI (`supabase db push`) or the SQL editor. The phone forwarder is a one-time setup per SIM device.
