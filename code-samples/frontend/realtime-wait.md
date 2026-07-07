# Realtime wait flow

Source: `app/(app)/admin/otp/otp-view.tsx` (anonymised, ~40-line excerpt from the ~770-line component).

The granted user's experience: tap **Request an OTP**, type a reason, watch the countdown, and get the SMS the moment it lands — even if the tab was backgrounded for the entire wait.

## Client-side

```tsx
"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";

interface Props {
  ephemeralOnly: boolean;
}

export function OtpView({ ephemeralOnly }: Props) {
  const [reason, setReason] = useState("");
  const [row, setRow] = useState<OtpRequestRow | null>(null);
  const [waitStarted, setWaitStarted] = useState<number | null>(null);

  // Kick off a request via the SECURITY DEFINER RPC.
  const request = async () => {
    const trimmed = reason.trim();
    if (trimmed.length < 3) return;
    const { data, error } = await supabase.rpc("create_otp_request", {
      p_reason: trimmed,
    });
    if (error) return; // toast handled elsewhere
    setRow(data);
    setWaitStarted(Date.now());
  };

  // Subscribe to changes on our own row only. RLS ensures we don't
  // receive updates for other users' rows even if we tried to.
  useEffect(() => {
    if (!row) return;
    const channel = supabase
      .channel(`otp-wait-${row.id}`)
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "otp_requests",
          filter: `id=eq.${row.id}`,
        },
        (payload) => setRow(payload.new as OtpRequestRow),
      )
      .subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [row?.id]);

  if (!ephemeralOnly) {
    return <SuperadminLiveInbox />;
  }

  // Idle: show the "Request an OTP" form.
  if (!row) {
    return <RequestForm reason={reason} setReason={setReason} onRequest={request} />;
  }

  // Waiting: show the countdown + reason echo.
  if (row.status === "pending") {
    const seconds = waitStarted
      ? Math.floor((Date.now() - waitStarted) / 1000)
      : 0;
    return <WaitingCard reason={row.reason} seconds={seconds} />;
  }

  // Fulfilled: reveal the SMS body.
  if (row.status === "fulfilled") {
    return <FulfilledCard sms={row.matched_sms_body} />;
  }

  // Over-limit: block, tell the user why, offer to keep waiting.
  if (row.status === "over_limit") {
    return <OverLimitCard cap={row.limit_snapshot} />;
  }

  // Cancelled by user or superadmin.
  return <CancelledCard />;
}
```

## What makes it robust

- **RLS on the subscription filter.** The channel's `filter: id=eq.<row-id>` is honored server-side. Even if we forgot the filter, the RLS policy on `otp_requests` would deny reads of other users' rows and the payload would be empty.
- **Idempotent cleanup.** `supabase.removeChannel` is safe if the channel is already closed. React 19's strict-mode double-invoke does the setup twice; the cleanup keeps it clean.
- **No polling.** If the trigger takes 2s or 20s, the client just sits on the WebSocket. No visible difference in code path.
- **Backgrounded-tab safe.** If the user backgrounds the tab, mobile browsers pause `setInterval` but Supabase's realtime channel stays open. When they come back the row is already `fulfilled` and the UI reflects it on the next render.

## The blocked-cap case

When the trigger sets `status='over_limit'`, the client shows an explicit "OTP blocked — over your ₹<cap> limit" card and the user's wait is over. They cannot see the SMS body (the RLS join to `sms_messages` fails for non-superadmin) and they need to talk to the superadmin to get past it. This is deliberate — the cap exists to *prevent* certain transactions, not to make them "harder."
