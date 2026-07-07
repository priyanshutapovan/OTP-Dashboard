# User Access tab — grant, revoke, edit cap

Source: `app/(app)/admin/otp/access-tab.tsx` (anonymised).

The superadmin controls two things per teammate: **access on/off** and **transaction cap (₹)**. Everything is optimistic — the row flips instantly and rolls back if the server rejects it.

```tsx
"use client";

import { useOptimistic, startTransition } from "react";
import { grantOtpAccess, revokeOtpAccess, setOtpLimit } from "@/app/actions/otp";

interface Props {
  users: AccessUser[];
}

export function OtpAccessTab({ users }: Props) {
  const [optimisticUsers, applyOptimistic] = useOptimistic(
    users,
    (state, update: OptimisticUpdate) =>
      state.map((u) =>
        u.id === update.id ? { ...u, ...update.patch } : u,
      ),
  );

  const granted = optimisticUsers.filter((u) => u.can_access_otp);
  const eligible = optimisticUsers.filter((u) => !u.can_access_otp);

  const grant = (id: string) => {
    applyOptimistic({ id, patch: { can_access_otp: true } });
    startTransition(async () => {
      const r = await grantOtpAccess(id);
      if (!r.ok) applyOptimistic({ id, patch: { can_access_otp: false } });
    });
  };

  const revoke = (id: string) => {
    applyOptimistic({ id, patch: { can_access_otp: false, otp_limit: null } });
    startTransition(async () => {
      const r = await revokeOtpAccess(id);
      if (!r.ok) applyOptimistic({ id, patch: { can_access_otp: true } });
    });
  };

  const editLimit = (id: string, next: number | null) => {
    const prev = optimisticUsers.find((u) => u.id === id)?.otp_limit ?? null;
    applyOptimistic({ id, patch: { otp_limit: next } });
    startTransition(async () => {
      const r = await setOtpLimit(id, next);
      if (!r.ok) applyOptimistic({ id, patch: { otp_limit: prev } });
    });
  };

  return (
    <>
      <section>
        <header>Granted access ({granted.length})</header>
        {granted.map((u) => (
          <GrantedRow
            key={u.id}
            user={u}
            onRevoke={() => revoke(u.id)}
            onLimitChange={(v) => editLimit(u.id, v)}
          />
        ))}
      </section>

      <section>
        <header>Assign to others ({eligible.length} eligible)</header>
        <SearchableList
          items={eligible}
          renderItem={(u) => (
            <EligibleRow user={u} onGrant={() => grant(u.id)} />
          )}
        />
      </section>
    </>
  );
}
```

## Server actions (Next.js 15)

The `grantOtpAccess` / `revokeOtpAccess` / `setOtpLimit` are all `"use server"` functions that call SECURITY DEFINER RPCs:

```typescript
// app/actions/otp.ts
"use server";

import { createClient } from "@/lib/supabase/server";

export async function grantOtpAccess(userId: string) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("otp_admin_grant", {
    p_user_id: userId,
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

export async function setOtpLimit(userId: string, limit: number | null) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("otp_admin_set_limit", {
    p_user_id: userId,
    p_limit: limit,
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}
```

The RPCs re-check `current_role() = 'superadmin'` inside the function body — no client-facing role check to trust.

## Search-as-you-type

The "Assign to others" panel is a simple `filter()` over the eligible array. No debounce, no API call. The initial fetch caps at 500 profiles which is well under any performance budget, and the input is controlled by React state.

```tsx
function SearchableList({ items, renderItem }) {
  const [q, setQ] = useState("");
  const filtered = items.filter((u) => {
    const needle = q.toLowerCase();
    return (
      u.full_name.toLowerCase().includes(needle) ||
      (u.email ?? "").toLowerCase().includes(needle) ||
      (u.designation ?? "").toLowerCase().includes(needle)
    );
  });
  return (
    <>
      <input placeholder="Search by name, email, designation" value={q} onChange={(e) => setQ(e.target.value)} />
      {filtered.map(renderItem)}
    </>
  );
}
```
