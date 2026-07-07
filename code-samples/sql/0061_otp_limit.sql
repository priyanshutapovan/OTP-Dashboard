-- =============================================================================
-- TIPL HUB — Per-user OTP transaction limit
-- Migration: 0061_otp_limit.sql
-- =============================================================================
-- The superadmin can now set a per-person rupee cap on the OTP feature. If
-- the body of an incoming SMS classifies as a pre-authorisation OTP (one
-- that's about to push through a transaction) AND the parsed amount
-- exceeds the user's `otp_limit`, the client refuses to surface it to
-- them — their wait stays active until a smaller-amount OTP or a non-
-- transactional OTP (verification, KYC, balance update, post-transaction
-- info) lands.
--
-- Schema-only here: adds the nullable column + widens v_directory so the
-- admin UI can read it. Filtering itself is implemented client-side using
-- the column value. NULL = no cap.
-- =============================================================================

alter table public.profiles
  add column if not exists otp_limit numeric;

-- v_directory already exposes the other per-user permissions / flags;
-- otp_limit lives here too so the OTP "User Access" tab can read it
-- alongside `can_access_otp` without an extra join.
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
  p.can_access_otp,
  p.can_access_logistics,
  p.can_access_requests,
  p.can_access_reports,
  p.company,
  p.otp_limit
from public.profiles p
left join public.profiles m on m.id = p.manager_id;

alter view public.v_directory set (security_invoker = true);
grant select on public.v_directory to authenticated;
