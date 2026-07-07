# SMS classifier (client + server mirror)

Source: `lib/sms-classifier.ts` + `sms_extract_amount` / `sms_is_pre_auth` in migration `0064`.

The classifier answers one question:

> Is this SMS a **pre-authorisation OTP** whose amount exceeds the user's cap?

If the answer is "yes", the server-side trigger transitions the request to `over_limit` (not `fulfilled`), the client hides the SMS body, and the user is told to talk to the superadmin.

## Categories

| kind | what it is | capped? |
|---|---|---|
| `non_otp` | No 4-8 digit token detected. Not an OTP at all. | n/a — no request would ever satisfy from this SMS |
| `info_otp` | Past-tense / status: "debited", "credited", "successful", "balance is". Always allowed. | **no** |
| `plain_otp` | Verification, KYC, login, signup. No transaction context. | **no** |
| `pre_auth` | About to authorise a transaction + carries an amount. | **yes — checked against user's cap** |

## TypeScript (client)

```typescript
export type SmsKind = "non_otp" | "info_otp" | "plain_otp" | "pre_auth";

export interface SmsClassification {
  kind: SmsKind;
  amount: number | null;      // highest amount found, in rupees
  otp: string | null;         // 4-8 digit token extracted
}

// Scanned globally — a transaction SMS often quotes the amount twice
// (Rs.40,000 in prose and 40000 in a summary). Take the MAX so a
// planted "Rs.1" in a footnote can't downgrade a real Rs.40,000 charge.
const AMOUNT_PATTERNS = [
  /(?:Rs\.?|INR|₹)\s*([\d,]+(?:\.\d{1,2})?)/gi,
  /([\d,]+(?:\.\d{1,2})?)\s*(?:Rs\.?|rupees|INR)/gi,
];

const INFO_KEYWORDS = [
  "debited", "credited", "successful", "successfully",
  "balance", "avl bal", "available balance", "has been sent",
];

const PRE_AUTH_KEYWORDS = [
  "transfer", "purchase", "spent", "payment", "authorise", "authorize",
  "authorising", "authorizing", "otp for transfer",
];

export function classify(body: string): SmsClassification {
  const otp = extractOtp(body);
  if (!otp) return { kind: "non_otp", amount: null, otp: null };

  const amount = extractMaxAmount(body);
  const lower = body.toLowerCase();

  if (INFO_KEYWORDS.some((k) => lower.includes(k))) {
    return { kind: "info_otp", amount, otp };
  }
  if (PRE_AUTH_KEYWORDS.some((k) => lower.includes(k))) {
    return { kind: "pre_auth", amount, otp };
  }
  return { kind: "plain_otp", amount, otp };
}

export function shouldBlock(body: string, limit: number | null): boolean {
  if (limit == null) return false;
  const c = classify(body);
  return c.kind === "pre_auth" && (c.amount ?? 0) > limit;
}
```

## PL/pgSQL (server, migration 0064)

```sql
create or replace function public.sms_extract_amount(p_body text)
returns numeric language plpgsql immutable as $$
declare
  m       text;
  best    numeric := 0;
  candidate numeric;
begin
  -- Loop over both patterns, keep the max
  for m in
    select (regexp_matches(p_body,
      '(?:Rs\.?|INR|₹)\s*([\d,]+(?:\.\d{1,2})?)', 'gi'))[1]
  loop
    candidate := replace(m, ',', '')::numeric;
    if candidate > best then best := candidate; end if;
  end loop;
  for m in
    select (regexp_matches(p_body,
      '([\d,]+(?:\.\d{1,2})?)\s*(?:Rs\.?|rupees|INR)', 'gi'))[1]
  loop
    candidate := replace(m, ',', '')::numeric;
    if candidate > best then best := candidate; end if;
  end loop;
  return case when best = 0 then null else best end;
end $$;

create or replace function public.sms_is_pre_auth(p_body text)
returns boolean language sql immutable as $$
  select
    -- MUST have an OTP-shaped token
    p_body ~ '[^0-9]([0-9]{4,8})[^0-9]?'
    -- AND at least one pre-auth keyword
    and lower(p_body) ~ '\y(transfer|purchase|spent|payment|authori[sz]e|authori[sz]ing)\y'
    -- AND NOT an info-status message
    and lower(p_body) !~ '\y(debited|credited|successful|balance|avl bal)\y';
$$;
```

## How they stay in sync

There is **no shared source** — the regexes are duplicated intentionally. Two implementations force a code-review conversation whenever either changes.

The safeguard is a snapshot test at CI time (not shown): a fixture of ~200 anonymised real SMS bodies is run through the TypeScript classifier client-side and the SQL functions server-side; both are expected to return identical `(kind, amount)` for every fixture. A mismatch fails CI.

This trades DRY for isolation: a change in one language cannot silently drift from the other. When you're deciding whether to unblock a ₹40 000 transaction, that isolation is worth the maintenance cost.
