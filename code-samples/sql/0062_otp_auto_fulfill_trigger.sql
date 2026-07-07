-- =============================================================================
-- TIPL HUB — Server-side OTP request fulfillment trigger
-- Migration: 0062_otp_auto_fulfill_trigger.sql
-- =============================================================================
-- Belt-and-suspenders attribution: whenever an SMS lands in
-- public.sms_messages, the oldest pending request in public.otp_requests
-- gets auto-fulfilled with it. The client also tries to do this via
-- fulfill_otp_request, but if that call drops (network blip, RLS quirk,
-- stale JWT on the socket), the request would otherwise sit on "pending"
-- forever and the superadmin would never see what satisfied it.
--
-- The trigger:
--   * Picks the SINGLE oldest pending row with `FOR UPDATE SKIP LOCKED`
--     so two SMS landing in the same tick attribute to two different
--     requests instead of fighting over the same one.
--   * Does NOT do limit enforcement — keeping policy on the client is
--     enough for the current UX and avoids re-implementing the SMS
--     classifier in PL/pgSQL.
--   * Is a no-op if no requests are pending (covers the common case
--     where a forwarded SMS is just noise unrelated to any request).
--
-- Safe to re-run; the function + trigger are dropped + recreated.
-- =============================================================================

create or replace function public.tg_attribute_sms_to_otp_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req_id uuid;
begin
  select id
    into v_req_id
    from public.otp_requests
   where status = 'pending'
   order by requested_at asc
   limit 1
   for update skip locked;

  if v_req_id is null then
    return new;
  end if;

  update public.otp_requests
     set status               = 'fulfilled',
         fulfilled_message_id = new.id,
         fulfilled_at         = now()
   where id = v_req_id
     and status = 'pending'; -- guard against a race with the client RPC

  return new;
end $$;

drop trigger if exists tg_attribute_sms on public.sms_messages;
create trigger tg_attribute_sms
  after insert on public.sms_messages
  for each row execute function public.tg_attribute_sms_to_otp_request();
