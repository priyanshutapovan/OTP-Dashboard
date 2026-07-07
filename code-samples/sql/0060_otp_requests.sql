-- =============================================================================
-- TIPL HUB — OTP requests log + RPCs
-- Migration: 0060_otp_requests.sql
-- =============================================================================
-- Until now the granted-user OTP flow was fire-and-forget: the SMS landed in
-- sms_messages, the granted user saw it, and nobody recorded why the OTP was
-- needed in the first place. The new admin dashboard wants to surface "who
-- requested an OTP, with what reason, which forwarded message satisfied it,
-- and at what time". This migration adds the persistence + the RPCs that
-- wire the granted-user flow to it.
--
-- Table: otp_requests
--   id                    primary key
--   user_id               who clicked Wait (FK -> profiles)
--   reason                free text, >= 3 chars
--   status                pending | fulfilled | cancelled
--   fulfilled_message_id  FK -> sms_messages, set when the wait resolves
--   fulfilled_at          when the wait resolved
--   requested_at          when Wait was clicked (server clock)
--
-- RLS:
--   SELECT  - own rows OR superadmin / ghost
--   INSERT/UPDATE/DELETE - revoked. All writes flow through the RPCs below.
--
-- RPCs (SECURITY DEFINER so the policy stays simple):
--   create_otp_request(reason)             -> uuid     granted user only
--   fulfill_otp_request(id, message_id)    -> void     idempotent, owner only
--   cancel_otp_request(id)                 -> void     idempotent, owner only
--
-- Idempotent: re-running drops + recreates the function bodies and is a
-- no-op against the table if it already exists.
-- =============================================================================

create table if not exists public.otp_requests (
  id                    uuid        primary key default gen_random_uuid(),
  user_id               uuid        not null references public.profiles(id) on delete cascade,
  reason                text        not null check (length(trim(reason)) >= 3),
  status                text        not null default 'pending'
                                    check (status in ('pending','fulfilled','cancelled')),
  fulfilled_message_id  uuid        references public.sms_messages(id) on delete set null,
  fulfilled_at          timestamptz,
  requested_at          timestamptz not null default now(),
  created_at            timestamptz not null default now()
);

create index if not exists otp_requests_user_id_idx
  on public.otp_requests(user_id);
create index if not exists otp_requests_requested_at_idx
  on public.otp_requests(requested_at desc);
create index if not exists otp_requests_status_idx
  on public.otp_requests(status);

alter table public.otp_requests enable row level security;

drop policy if exists otp_requests_read on public.otp_requests;
create policy otp_requests_read
  on public.otp_requests for select
  to authenticated
  using (
    user_id = auth.uid()
    or (public.current_role())::text in ('superadmin','ghost')
  );

-- All writes go through the SECURITY DEFINER RPCs below — never let
-- the client INSERT/UPDATE/DELETE directly.
revoke insert, update, delete on public.otp_requests from authenticated;

-- ---------------------------------------------------------------------------
-- create_otp_request: granted user (or superadmin/ghost) opens a request
-- with their reason. Returns the new id so the client can later mark it
-- fulfilled with the SMS that resolved the wait.
-- ---------------------------------------------------------------------------
create or replace function public.create_otp_request(p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_can    boolean;
  v_role   text;
  v_id     uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'reason_required';
  end if;
  select coalesce(can_access_otp, false), (role)::text
    into v_can, v_role
    from public.profiles
   where id = v_uid;
  if not v_can and v_role not in ('superadmin','ghost') then
    raise exception 'forbidden';
  end if;
  insert into public.otp_requests (user_id, reason)
  values (v_uid, trim(p_reason))
  returning id into v_id;
  return v_id;
end $$;

grant execute on function public.create_otp_request(text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- fulfill_otp_request: link an incoming SMS to a pending request. Called
-- from the client when the wait resolves. Idempotent: a non-pending
-- request just returns silently so a duplicate fulfill (Realtime + REST
-- poll racing each other) is a no-op.
-- ---------------------------------------------------------------------------
create or replace function public.fulfill_otp_request(
  p_id          uuid,
  p_message_id  uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_owner   uuid;
  v_status  text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select user_id, status
    into v_owner, v_status
    from public.otp_requests
   where id = p_id
   for update;
  if v_owner is null then raise exception 'request_not_found'; end if;
  if v_owner <> v_uid then raise exception 'forbidden'; end if;
  if v_status <> 'pending' then return; end if;
  update public.otp_requests
     set status               = 'fulfilled',
         fulfilled_message_id = p_message_id,
         fulfilled_at         = now()
   where id = p_id;
end $$;

grant execute on function public.fulfill_otp_request(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- cancel_otp_request: owner cancels a pending request (clicked Cancel or
-- closed the page). Idempotent for the same race-tolerance reasons.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_otp_request(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_owner   uuid;
  v_status  text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select user_id, status
    into v_owner, v_status
    from public.otp_requests
   where id = p_id
   for update;
  if v_owner is null then raise exception 'request_not_found'; end if;
  if v_owner <> v_uid then raise exception 'forbidden'; end if;
  if v_status <> 'pending' then return; end if;
  update public.otp_requests
     set status = 'cancelled'
   where id = p_id;
end $$;

grant execute on function public.cancel_otp_request(uuid)
  to authenticated;
