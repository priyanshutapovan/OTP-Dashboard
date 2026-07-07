-- =============================================================================
-- TIPL HUB — Server-side OTP transaction-cap enforcement
-- Migration: 0064_otp_over_limit_status.sql
-- =============================================================================
-- The trigger from 0062 always marked the fulfilling SMS as 'fulfilled',
-- which lied to the superadmin dashboard: it showed an OTP as
-- "delivered" even when the granted user never actually got to see it
-- (their client-side classifier had blocked it because the parsed
-- amount exceeded their per-user otp_limit).
--
-- This migration:
--   * Adds 'over_limit' to the otp_requests.status check constraint so
--     blocked rows have a distinct, queryable state.
--   * Implements two PL/pgSQL helpers — sms_extract_amount() and
--     sms_is_pre_auth() — that mirror the rules in
--     lib/sms-classifier.ts. PL/pgSQL is the only place we re-state
--     them; keep both in lockstep when either side changes.
--   * Rewrites the trigger to read the requesting user's otp_limit
--     and, when the SMS is a pre-auth OTP whose amount exceeds the
--     cap, mark the row 'over_limit' instead of 'fulfilled'. The
--     matched message_id + fulfilled_at are still recorded so the
--     dashboard can show WHAT was blocked.
--
-- Idempotent: drop/recreate of the constraint, functions, trigger.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Widen the status enum
-- ---------------------------------------------------------------------------
alter table public.otp_requests
  drop constraint if exists otp_requests_status_check;
alter table public.otp_requests
  add constraint otp_requests_status_check
  check (status in ('pending','fulfilled','cancelled','over_limit'));


-- ---------------------------------------------------------------------------
-- sms_extract_amount(body)
--   Returns the largest currency amount (rupees) found anywhere in the
--   body, or NULL if none. Matches both "Rs.40,000 / INR 40000 / ₹40000"
--   and "40000 rupees / 40,000 Rs" shapes. Greatest-amount-wins so a
--   stray "Rs.1" footnote can't downgrade a real "Rs.40,000" charge.
-- ---------------------------------------------------------------------------
create or replace function public.sms_extract_amount(body text)
returns numeric
language plpgsql
immutable
as $$
declare
  v_lower text := lower(coalesce(body, ''));
  v_max   numeric := null;
  v_n     numeric;
  v_match text[];
begin
  -- Rs/INR/₹ followed by amount
  for v_match in
    select regexp_matches(
      v_lower,
      '(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      'g'
    )
  loop
    begin
      v_n := replace(v_match[1], ',', '')::numeric;
      if v_max is null or v_n > v_max then v_max := v_n; end if;
    exception when others then
      null;
    end;
  end loop;

  -- amount followed by Rs/rupees/INR
  for v_match in
    select regexp_matches(
      v_lower,
      '([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:rs\.?|rupees|inr)',
      'g'
    )
  loop
    begin
      v_n := replace(v_match[1], ',', '')::numeric;
      if v_max is null or v_n > v_max then v_max := v_n; end if;
    exception when others then
      null;
    end;
  end loop;

  return v_max;
end $$;


-- ---------------------------------------------------------------------------
-- sms_is_pre_auth(body)
--   True iff the SMS looks like a pre-authorisation OTP — has an OTP
--   code, has a transaction keyword, AND is NOT an informational /
--   post-transaction message. Mirrors lib/sms-classifier.ts classify()
--   for the 'pre_auth' bucket.
-- ---------------------------------------------------------------------------
create or replace function public.sms_is_pre_auth(body text)
returns boolean
language sql
immutable
as $$
  select
    coalesce(body, '') ~ '[0-9]{4,8}'
    and lower(coalesce(body, '')) !~
        '(debited|credited|successful|successfully|has been processed|was processed|received from|your balance|available balance|avbl bal|current balance|balance is|is credited|is debited)'
    and lower(coalesce(body, '')) ~
        '(transaction|transfer|purchase|payment|paying|withdraw|withdrawal|to pay|to send|to transfer|imps|neft|rtgs|upi)';
$$;


-- ---------------------------------------------------------------------------
-- Rewritten trigger: limit-aware attribution
-- ---------------------------------------------------------------------------
create or replace function public.tg_attribute_sms_to_otp_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req         record;
  v_limit       numeric;
  v_amount      numeric;
  v_new_status  text := 'fulfilled';
begin
  -- Pick + lock the oldest pending request. SKIP LOCKED so two SMS
  -- landing in the same tick attribute to two different requests
  -- rather than fighting over the same one.
  select *
    into v_req
    from public.otp_requests
   where status = 'pending'
   order by requested_at asc
   limit 1
   for update skip locked;

  if v_req.id is null then
    return new;
  end if;

  -- Limit check: only matters when the user has a positive cap AND
  -- the SMS looks like a pre-authorisation OTP. Informational
  -- "debited/credited/successful" messages flow through regardless.
  select otp_limit into v_limit
    from public.profiles
   where id = v_req.user_id;

  if v_limit is not null
     and v_limit > 0
     and public.sms_is_pre_auth(new.body)
  then
    v_amount := public.sms_extract_amount(new.body);
    if v_amount is not null and v_amount > v_limit then
      v_new_status := 'over_limit';
    end if;
  end if;

  update public.otp_requests
     set status               = v_new_status,
         fulfilled_message_id = new.id,
         fulfilled_at         = now()
   where id = v_req.id
     and status = 'pending'; -- guard against a race with the client RPC

  return new;
end $$;

drop trigger if exists tg_attribute_sms on public.sms_messages;
create trigger tg_attribute_sms
  after insert on public.sms_messages
  for each row execute function public.tg_attribute_sms_to_otp_request();
