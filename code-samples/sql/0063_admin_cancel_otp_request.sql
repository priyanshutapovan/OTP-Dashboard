-- =============================================================================
-- TIPL HUB — Superadmin / ghost can cancel any pending OTP request
-- Migration: 0063_admin_cancel_otp_request.sql
-- =============================================================================
-- The original cancel_otp_request from 0060 was owner-only — a granted user
-- could clean up their own stuck wait, but the superadmin had no way to
-- clear a request that got abandoned (user closed the tab, navigated
-- away, etc.) and was sitting on "pending" forever.
--
-- Widens the existing function so superadmin / ghost can cancel any row.
-- Body otherwise unchanged (still idempotent, still locks for update,
-- still safe to re-run).
-- =============================================================================

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
  v_role    text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select user_id, status
    into v_owner, v_status
    from public.otp_requests
   where id = p_id
   for update;
  if v_owner is null then raise exception 'request_not_found'; end if;

  select (public.current_role())::text into v_role;
  -- Owner OR superadmin / ghost.
  if v_owner <> v_uid
     and v_role not in ('superadmin','ghost') then
    raise exception 'forbidden';
  end if;

  if v_status <> 'pending' then return; end if;
  update public.otp_requests
     set status = 'cancelled'
   where id = p_id;
end $$;

grant execute on function public.cancel_otp_request(uuid)
  to authenticated;
