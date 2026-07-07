# Server component with tiered data fetch

Source: `app/(app)/admin/otp/page.tsx` (anonymised).

The `/admin/otp` page decides in one place who sees what, then fetches only the data the visible tabs need. Server-side, force-dynamic, no client-side polling.

```tsx
import { redirect } from "next/navigation";
import { requireSession } from "@/lib/data/session";
import { createClient } from "@/lib/supabase/server";
import { OtpView, type SmsRow } from "./otp-view";
import { OtpTabs, type OtpTabKey } from "./tabs";
import { OtpAccessTab, type AccessUser } from "./access-tab";
import { OtpRequestsLog, type OtpRequestRow } from "./requests-log";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function OtpRequestsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; range?: string }>;
}) {
  const ctx = await requireSession();
  const role = ctx.profile.role as string;

  // Three access tiers with hard deny for anyone else.
  const isAdminScope = role === "superadmin";
  const isGrantedScope = !!ctx.profile.can_access_otp;
  if (!isAdminScope && !isGrantedScope) {
    redirect("/home");
  }

  const sp = await searchParams;
  // Admin-only tabs get silently downgraded to `dashboard` for
  // granted users — no `access denied` interstitial, no leak.
  const requestedTab: OtpTabKey = !isAdminScope
    ? "dashboard"
    : sp.tab === "inbox"
      ? "inbox"
      : sp.tab === "access"
        ? "access"
        : "dashboard";

  let initialMessages: SmsRow[] = [];
  const peopleById: Record<string, ProfileMini> = {};
  let accessUsers: AccessUser[] = [];
  let requests: OtpRequestRow[] = [];

  if (isAdminScope) {
    const supabase = await createClient();

    // Newest 50 SMS for the inbox tab.
    const { data: msgs } = await supabase
      .from("sms_messages")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(50);
    initialMessages = (msgs as SmsRow[] | null) ?? [];

    // Every active teammate who CAN be granted. Superadmin has it
    // implicitly, so we filter them out — showing them with an
    // off-switch would mislead.
    const { data: users } = await supabase
      .from("profiles")
      .select(
        "id, full_name, email, role, department, designation, can_access_otp, avatar_url, otp_limit",
      )
      .eq("is_active", true)
      .not("role", "in", "(superadmin)")
      .order("full_name");
    accessUsers = users ?? [];

    // Recent request log for the audit panel. Range filter is
    // applied at the DB level; "all" caps at 500 rows so a runaway
    // log doesn't blow the page.
    const range = parseRange(sp.range);
    let reqsQuery = supabase
      .from("otp_requests")
      .select(/* ... */)
      .order("requested_at", { ascending: false })
      .limit(range === "all" ? 500 : 200);
    // ... range-scoped date filter added conditionally ...
    const { data: reqs } = await reqsQuery;
    requests = reqs ?? [];
  }

  return (
    <div className="…">
      <OtpTabs
        current={requestedTab}
        adminScope={isAdminScope}
      />
      {requestedTab === "dashboard" && (
        <>
          {/* Granted-user view = wait flow. Superadmin view = live inbox. */}
          <OtpView
            initialMessages={initialMessages}
            peopleById={peopleById}
            ephemeralOnly={!isAdminScope}
          />
          {isAdminScope && (
            <OtpRequestsLog
              rows={requests}
              messagesById={messagesById}
              peopleById={peopleById}
            />
          )}
        </>
      )}
      {requestedTab === "access" && (
        <OtpAccessTab users={accessUsers} />
      )}
    </div>
  );
}
```

## Why it's server-side

- The `redirect` runs **before** any HTML ships to a not-allowed user — no flash of forbidden content.
- The data fetch is one round-trip per tab, no waterfall on the client.
- `force-dynamic` guarantees a fresh read on every navigation. The Log tab isn't useful if it's stale.

## The `peopleById` index

Every fulfilled request references an `sms_messages` row, and every SMS row references the user who was waiting when it landed. Rather than three joins in a view, we fetch profiles once and hand a `Record<uuid, ProfileMini>` to the log component. Client-side `peopleById[row.user_id]` is O(1) and doesn't need a `useEffect` fetch.
