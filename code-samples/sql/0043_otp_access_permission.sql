-- =============================================================================
-- TIPL HUB — Per-user OTP access permission
-- Migration: 0043_otp_access_permission.sql
-- =============================================================================
-- Replaces the role-based OTP access from migration 0042 with an explicit
-- per-user permission. Superadmin grants it through the Users & Roles
-- edit dialog (new "Can access OTP requests" toggle), so a manager can
-- have it but a different manager can NOT — instead of every manager
-- silently being able to read every forwarded SMS.
--
-- Superadmin + ghost still have access implicitly (they own everything
-- in the system anyway and explicit grants would just be paperwork).
-- Owners always see their own messages.
--
-- Migration 0042's RLS policy (which extended SELECT to "manager") is
-- replaced here so the only ways to read sms_messages are:
--   1. user_id = auth.uid()                      (owner)
--   2. current_role() in (superadmin, ghost)     (built-in admin scope)
--   3. profiles.can_access_otp = true            (explicitly granted)
--
-- Idempotent — safe to re-run. Defaults to false so no existing user
-- gets the permission by accident.
-- =============================================================================

alter table public.profiles
  add column if not exists can_access_otp boolean not null default false;

-- Replace the SELECT policy. Use a SECURITY DEFINER helper so the
-- policy doesn't trigger an RLS recursion when checking
-- profiles.can_access_otp from inside a sms_messages RLS rule.
create or replace function public.has_otp_access(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(can_access_otp, false)
    from public.profiles
    where id = p_user_id;
$$;

grant execute on function public.has_otp_access(uuid) to authenticated;

drop policy if exists sms_messages_select_own_or_admin on public.sms_messages;
create policy sms_messages_select_own_or_admin
  on public.sms_messages for select
  to authenticated
  using (
    user_id = auth.uid()
    or (public.current_role())::text in ('superadmin', 'ghost')
    or public.has_otp_access(auth.uid())
  );

-- Delete remains owner + superadmin / ghost only. Granted users can
-- READ messages but can't wipe other people's history.
drop policy if exists sms_messages_delete_own_or_admin on public.sms_messages;
create policy sms_messages_delete_own_or_admin
  on public.sms_messages for delete
  to authenticated
  using (
    user_id = auth.uid()
    or (public.current_role())::text in ('superadmin', 'ghost')
  );

-- v_directory is what /admin/users reads to populate the edit dialog.
-- The dialog needs can_access_otp so the checkbox starts with the
-- saved value; without exposing it through the view the checkbox
-- would always render as unchecked even after a save.
-- CREATE OR REPLACE VIEW can only ADD columns at the end of the
-- existing column list — append after employee_type.
create or replace view public.v_directory as
select
  p.id,
  p.email,
  p.full_name,
  p.avatar_url,
  p.role,
  p.department,
  p.designation,
  p.timezone,
  p.is_active,
  p.manager_id,
  m.full_name as manager_name,
  m.email     as manager_email,
  p.employee_type,
  p.can_access_otp
from public.profiles p
left join public.profiles m on m.id = p.manager_id;

alter view public.v_directory set (security_invoker = true);
grant select on public.v_directory to authenticated;
