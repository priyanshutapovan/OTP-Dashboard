# Frontend code excerpts

Selected files from the Next.js implementation, lightly redacted (email addresses, internal role names, deployment URLs). The originals are ~2 250 lines across five files; the snippets below highlight the interesting parts.

## Files

| snippet | source file | what it shows |
|---|---|---|
| [`page-server-component.md`](page-server-component.md) | `app/(app)/admin/otp/page.tsx` | Server-component data fetch with role-based branching. Access-tier logic in one place. |
| [`realtime-wait.md`](realtime-wait.md) | `app/(app)/admin/otp/otp-view.tsx` | The granted-user's "waiting for OTP" experience — Supabase Realtime subscription, countdown timer, blocked-cap fallback. |
| [`access-tab-grant-revoke.md`](access-tab-grant-revoke.md) | `app/(app)/admin/otp/access-tab.tsx` | The User Access tab: search, grant, revoke, edit per-user cap. Optimistic UI with server action rollback. |
| [`sms-classifier.md`](sms-classifier.md) | `lib/sms-classifier.ts` | The client-side SMS categoriser — mirrors the PL/pgSQL functions in migration `0064` byte-for-byte. |

## Tech notes

- **All server components use `force-dynamic` + `noStore()`** so every page load hits Postgres fresh — the log has to be current or it's useless.
- **Realtime channel per user request** — one WebSocket subscription, filter `id=eq.<row-id>`. RLS is honored server-side so filter escape doesn't matter security-wise, but scoped filters keep the payload minimal.
- **Optimistic UI with rollback on server-action failure.** Grant / revoke flips the row instantly and rolls back if the RPC returns an error.
- **No client-side polling anywhere.** Realtime does everything.

## Why anonymised

The originals reference:
- Specific internal role names and cover identifiers (kept obscure per company policy)
- Full deployment URLs (`*.vercel.app` domains) and Supabase project IDs (irrelevant here)
- Internal team names + email addresses in the audit-log demo data

None of that is load-bearing on the architecture, so it's stripped for the public showcase.
