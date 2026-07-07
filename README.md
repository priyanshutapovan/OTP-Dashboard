# OTP Requests Dashboard

A per-user OTP distribution + audit console built on Supabase + Next.js.

Team members who don't own the shared card can request a one-time password through the app; the dashboard forwards the arriving SMS to them the moment it lands, enforces a per-user amount cap, and keeps a complete audit log of who asked for what, when, and which SMS satisfied the request.

Built as one module of a private internal HR + operations platform. This repository is a standalone showcase of just the OTP subsystem — the surrounding auth, chat, attendance, and reports modules are not included.

---

## Screenshots

The three views a superadmin cycles through, each rendered against the platform's animated network background.

| view | purpose |
|---|---|
| ![Dashboard](screenshots/dashboard.png) | Rolling counters (today / 7 days / all time) split by status: pending, fulfilled, over-limit, cancelled. |
| ![Recent inbox](screenshots/recent-inbox.png) | Every forwarded SMS the platform has received — searchable, timestamped, attributed to the person who was waiting when it arrived. |
| ![User access](screenshots/user-access.png) | Grant / revoke OTP feature access, set a per-user transaction cap (₹ limit), and search 40+ eligible teammates. |

---

## What the module does

1. **Superadmin grants access** to specific people through a simple grant/revoke UI. Each grant can optionally carry a **transaction cap in INR** (e.g. `10 000`) — pre-authorisation OTPs above the cap will not be surfaced to the granted user.
2. **A granted user opens the OTP page** and taps **"Request an OTP"** with a mandatory free-text reason (e.g. *"Amazon order for stationery"*). This inserts a row into `otp_requests` with `status = 'pending'` and starts a countdown timer.
3. **The physical SIM device** (an Android phone with an SMS-forwarder installed) POSTs every arriving SMS to an authenticated webhook. The row lands in `sms_messages` — visible only to superadmins and forwarded to the correct waiting requester via Supabase Realtime.
4. **Auto-fulfillment**: an after-INSERT trigger on `sms_messages` finds the oldest pending `otp_requests` row and marks it `fulfilled` — even if the client-side "claim" call drops. Belt-and-suspenders so no request ever gets stuck pending.
5. **Cap enforcement**: if the incoming SMS is a pre-authorisation OTP (`Rs X spent...`) whose amount exceeds the user's cap, the row is marked `over_limit` instead of `fulfilled`. The user sees an explicit "OTP blocked" notice and keeps waiting for a smaller one.
6. **Audit log**: every state transition (pending → fulfilled / over_limit / cancelled) is persisted with the exact SMS that satisfied it, the wait duration, and the reason.

---

## Tech stack

| layer | choice | why |
|---|---|---|
| Frontend | **Next.js 15** (App Router, React 19, Server Components) | Native `force-dynamic` per-request rendering so the log always reflects the newest row |
| Realtime | **Supabase Realtime** | `otp_requests` is added to `supabase_realtime` so the granted user's screen and the superadmin dashboard both update the moment a row changes |
| Data | **Supabase Postgres 15** | Row-level security drives the whole authorisation model — no server-side gate code |
| Ingress | **Vercel API route** with a shared-secret header | Signs the SMS payload from the phone forwarder and inserts into `sms_messages` via the service-role client |
| Type safety | **TypeScript strict**, generated Postgrest types | Compile-time guarantees on every column reference |
| Styling | **Tailwind** + CSS variables | Theme picker (15 palettes) switches every accent in the OTP UI atomically |

---

## Architecture

```
┌────────────────────────────┐
│  Granted teammate's screen │
│  1. Enter reason           │
│  2. Tap "Request OTP"      │       insert
└─────────────┬──────────────┘         │
              │ RPC                    ▼
              │             ┌────────────────────┐
              └────────────▶│  otp_requests      │
                            │  status = pending  │
                            └─────────┬──────────┘
                                      │ RLS lets the row's
                                      │ owner + superadmins read it
                                      ▼
                            ┌────────────────────┐
                            │ Supabase Realtime  │
                            │ (WS to browser)    │
                            └─────────┬──────────┘
                                      │
     ┌────────────────────────────────┼──────────────────────────────┐
     │                                │                              │
     ▼                                ▼                              ▼
┌──────────────┐              ┌───────────────┐            ┌────────────────┐
│ user's page  │              │ superadmin    │            │ audit log tab  │
│ shows spinner│              │ dashboard tab │            │ (with reason,  │
│ / timer      │              │ (live count)  │            │  wait duration,│
└──────────────┘              └───────────────┘            │  SMS matched)  │
                                                            └────────────────┘

           MEANWHILE, on the SIM-holder's Android phone…
                              │
    SMS arrives                │
     ▼                        │ POST /api/sms/ingest
┌──────────────────┐    ┌─────▼───────────────────┐
│ Forwarder app    │───▶│ Vercel API route        │
│ (matches sender  │    │ verifies shared-secret  │
│  patterns)       │    │ header + inserts row    │
└──────────────────┘    └────────────┬────────────┘
                                     │
                                     ▼
                        ┌────────────────────────┐
                        │  sms_messages          │
                        │  AFTER INSERT trigger  │
                        └────────────┬───────────┘
                                     │
                                     │  finds oldest pending
                                     │  otp_requests row,
                                     │  reads owner's otp_limit,
                                     │  classifies the SMS
                                     ▼
                        ┌────────────────────────────┐
                        │  UPDATE otp_requests SET   │
                        │  status = fulfilled |      │
                        │           over_limit,      │
                        │  matched_sms_id = X,       │
                        │  wait_seconds = elapsed    │
                        └────────────────────────────┘
```

Full detail in [`docs/architecture.md`](docs/architecture.md).

---

## Repository layout

```
otp-dashboard-showcase/
├── README.md                         ← you are here
├── docs/
│   ├── architecture.md               ← full system walkthrough
│   ├── database-schema.md            ← tables, RPCs, triggers, RLS
│   ├── security-model.md             ← the tiered access story
│   └── setup.md                      ← run it locally
├── screenshots/
│   ├── dashboard.png
│   ├── recent-inbox.png
│   └── user-access.png
└── code-samples/
    ├── frontend/                     ← anonymised React / TS excerpts
    └── sql/                          ← every migration for this module
```

---

## Highlights

- **All authorisation is Postgres RLS + SECURITY DEFINER RPCs.** No `if (user.role === ...)` code path anywhere — the database is the source of truth.
- **Realtime by default.** Every state transition streams to both the requester and the superadmin without polling.
- **The client cannot lie.** The auto-fulfillment trigger is server-side; if the browser tab is killed mid-request the row still transitions correctly when the SMS lands.
- **Server-side classifier mirrors client-side classifier.** SMS categorisation (`non_otp` / `info_otp` / `plain_otp` / `pre_auth`) is duplicated in TypeScript for the display layer and PL/pgSQL for the trigger — same rules, two implementations, so a client-side bypass can't grant an over-limit OTP.
- **Zero-config PWA.** The UI is served from the same Next.js app as the rest of the platform; installing it on a phone is a two-tap Add-to-Home-Screen.

---

## Author

**Priyanshu Sharma** — AI Automation Developer, Tapovan Impex Private Limited.

Portfolio · [https://portfolio-7dx6.vercel.app/](https://portfolio-7dx6.vercel.app/)

---

## License

MIT. See [`LICENSE`](LICENSE) if bundled, otherwise treat this as illustrative code — the module runs against a specific internal deployment and isn't shipped as a library.
