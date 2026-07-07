# Database schema

All migrations for this module, in dependency order. Copies live in [`../code-samples/sql/`](../code-samples/sql).

## Tables

### `otp_requests`

The core row — one per user request.

```sql
create table public.otp_requests (
  id              uuid primary key default uuid_generate_v4(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  reason          text not null check (length(trim(reason)) between 3 and 240),
  status          text not null default 'pending'
                  check (status in ('pending','fulfilled','over_limit','cancelled')),
  matched_sms_id  uuid references public.sms_messages(id) on delete set null,
  requested_at    timestamptz not null default now(),
  resolved_at     timestamptz,
  wait_seconds    integer generated always as
                  (case when resolved_at is null then null
                        else extract(epoch from (resolved_at - requested_at))::int
                   end) stored,
  -- Snapshot the cap in effect when the request was created — the
  -- superadmin may raise/lower it later, so we anchor to what the
  -- user actually saw at request time for the audit story.
  limit_snapshot  numeric,
  created_at      timestamptz not null default now()
);

-- One pending row per user at a time.
create unique index otp_requests_one_pending_per_user
  on public.otp_requests (user_id)
  where status = 'pending';

create index otp_requests_status_time
  on public.otp_requests (status, requested_at desc);
```

### `sms_messages`

Every forwarded SMS, superadmin-visible only.

```sql
create table public.sms_messages (
  id            uuid primary key default uuid_generate_v4(),
  sender        text not null,
  body          text not null,
  received_at   timestamptz not null default now(),
  matched_to    uuid references public.otp_requests(id) on delete set null,
  matched_user  uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index sms_messages_received_desc
  on public.sms_messages (received_at desc);
```

### `profiles.otp_limit`, `profiles.can_access_otp`

Not their own tables — they're columns on the existing profile row:

```sql
alter table public.profiles
  add column can_access_otp boolean not null default false;

alter table public.profiles
  add column otp_limit numeric;  -- null = no cap
```

`v_directory` is widened to expose both so the User Access tab can render them without extra queries.

## RPCs (SECURITY DEFINER)

Users never hit the tables directly — every mutation is a function call.

### `create_otp_request(reason text)` → `otp_requests`

- Checks `auth.uid()` has `can_access_otp = true`
- Inserts a new row with `status='pending'`, snapshots current `otp_limit` into `limit_snapshot`
- Raises `unique_violation` if the user already has a pending row (client shows a friendlier "you have a pending request" toast)

### `fulfill_otp_request(id uuid, sms_id uuid)` → `otp_requests`

- Updates the row to `fulfilled` if `status='pending'`, otherwise no-op
- Only callable by superadmin+ (RLS on the function, not the table)
- Idempotent — safe for the client to call after realtime observation

### `cancel_otp_request(id uuid)` → `otp_requests`

- If caller is the row owner: updates to `cancelled` only when `status='pending'`
- If caller is superadmin+: same, regardless of ownership (widened in `0063`)
- No-op if already terminal

## Triggers

### `tg_attribute_sms_to_otp_request()` — after INSERT on `sms_messages`

The load-bearing piece. Full body in [`../code-samples/sql/0062_otp_auto_fulfill_trigger.sql`](../code-samples/sql/0062_otp_auto_fulfill_trigger.sql). Summary:

```sql
create or replace function public.tg_attribute_sms_to_otp_request()
returns trigger language plpgsql security definer as $$
declare
  v_req_id uuid;
  v_owner  uuid;
  v_cap    numeric;
  v_amount numeric;
  v_is_pre boolean;
begin
  select id, user_id into v_req_id, v_owner
    from public.otp_requests
   where status = 'pending'
   order by requested_at asc
   for update skip locked
   limit 1;

  if v_req_id is null then return NEW; end if;

  select otp_limit into v_cap
    from public.profiles where id = v_owner;

  v_amount := public.sms_extract_amount(NEW.body);
  v_is_pre := public.sms_is_pre_auth(NEW.body);

  if v_is_pre and v_cap is not null and v_amount > v_cap then
    update public.otp_requests
       set status = 'over_limit', matched_sms_id = NEW.id,
           resolved_at = now()
     where id = v_req_id;
  else
    update public.otp_requests
       set status = 'fulfilled', matched_sms_id = NEW.id,
           resolved_at = now()
     where id = v_req_id;
  end if;

  return NEW;
end $$;
```

Key details:

- `FOR UPDATE SKIP LOCKED` — if two SMS rows land in the same instant, they attribute to *different* pending requests instead of fighting for the same one.
- `SECURITY DEFINER` — the trigger runs as the table owner, sidestepping the caller's RLS.
- The `over_limit` branch was added in migration `0064` after the earlier version silently marked capped OTPs as `fulfilled` — that lied to the audit log.

### `sms_extract_amount(body text) → numeric` + `sms_is_pre_auth(body text) → boolean`

Two helper functions that mirror the TypeScript classifier in `lib/sms-classifier.ts`. The regex families are:

- **Pre-auth**: `/(?:Rs\.?|INR|₹)\s?([\d,]+\.?\d*)\s+spent/i`, `/authorised for (?:Rs\.?|INR)\s?([\d,]+)/i`, etc.
- **Amount extraction**: same match groups, strip commas, cast to numeric.

The two implementations are tested against a snapshot of ~200 anonymised real SMS messages to guarantee they agree.

## RLS policies

Everything RLS-gated. The interesting ones:

```sql
-- otp_requests: owner reads own; superadmin reads all
create policy otp_req_select_own
  on public.otp_requests for select
  to authenticated
  using (
    user_id = auth.uid()
    or (public.current_role())::text in ('superadmin','ghost')
  );

-- No direct INSERT / UPDATE from the client — only RPCs.
-- (Absence of matching policies is deny-by-default.)

-- sms_messages: superadmin only (ingestion goes via service role).
create policy sms_msg_select_admin
  on public.sms_messages for select
  to authenticated
  using ((public.current_role())::text in ('superadmin','ghost'));
```

`(public.current_role())::text in ('superadmin','ghost')` is the standard superadmin gate used across every table in the platform.

## Realtime publication

```sql
alter publication supabase_realtime add table public.otp_requests;
```

`sms_messages` is intentionally **not** added — the raw inbox streams only to the superadmin view via a separate server-sent-events endpoint that's already gated by role.

## Migration order

1. `0043_otp_access_permission.sql` — `profiles.can_access_otp`
2. `0060_otp_requests.sql` — the main table + `create_otp_request` / `fulfill_otp_request` / `cancel_otp_request`
3. `0061_otp_limit.sql` — `profiles.otp_limit` + widen `v_directory`
4. `0062_otp_auto_fulfill_trigger.sql` — the after-insert trigger
5. `0063_admin_cancel_otp_request.sql` — widen cancel RPC to any pending row for superadmin+
6. `0064_otp_over_limit_status.sql` — add `over_limit` to status enum + rewrite trigger with cap logic
