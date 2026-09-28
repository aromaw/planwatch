# Provider contracts

Research date: 2026-09-26. These are read-only quota queries. No inference requests are made.

## Codex

Official documentation: https://developers.openai.com/codex/app-server/

Start the user's installed `codex app-server` with JSON-RPC over stdio. Initialize, send `initialized`, call `account/rateLimits/read` and `account/read`, then terminate the process group. Authentication and refresh remain owned by Codex. Do not read token files ourselves. Account API errors are not logged.

Parse `rateLimitsByLimitId` when present, otherwise `rateLimits`. Preserve pool names, `usedPercent`, `windowDurationMins`, and `resetsAt`. No assumptions about a monthly Codex allowance. Requires a CLI version exposing these methods and ChatGPT subscription authentication.

## Kimi Code

- `GET https://api.kimi.com/coding/v1/usages` (China)
- `GET https://api.kimi.ai/coding/v1/usages` (international)
- `Authorization: Bearer <Kimi Code API key>`

Parse `usages.limit_5h`, `limit_7d`, `limit_month_total`, each containing `used_ratio` and `reset_time`. Legacy `usage` is weekly; `limits[]` declares its own duration and counters. Accept numeric or string counters. Missing used and remaining counters are unknown, even when limit is known. For mixed legacy responses with placeholder zero ratio pools, use nonzero authoritative counters.

Do not rename membership levels using the V1 catalog when a different goods version is returned. Absence of a weekly window does not by itself prove a plan is unlimited.

Alternatively, capture the user's `kimi-auth` session through an interactive WebKit login. This mode uses a single account session for both `POST /apiv2/kimi.gateway.billing.v1.BillingService/GetUsages` and `POST /apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats` at `www.kimi.com` (or `www.kimi.ai`). Do not combine an unrelated web account with an API key. The first request selects `FEATURE_CODING`; the second provides `subscriptionBalance.amountUsedRatio`, the **shared monthly membership pool**, not `kimiCodeUsedRatio`. Explicit `ratelimitCode7d.enabled=false` is displayed as not applicable. Unknown or non-subscription balances are not represented as subscription monthly usage.

Official rules: https://www.kimi.com/code/docs/kimi-code/membership.html

## Command Code

- `GET https://api.commandcode.ai/internal/billing/credits`
- `GET https://api.commandcode.ai/internal/billing/subscriptions`
- Session cookie from the user's interactive login at `commandcode.ai`.

The internal endpoints are not a versioned public API. `credits.monthlyCredits` is **remaining**, not used; total is `monthlyCreditsGranted`. `windowLimits.fiveHour` and `weekly` contain `used`, `cap`, `resetAt`. The monthly reset comes from subscription `data.currentPeriodEnd`. Only the explicitly identified `individual-goat` plan falls back to the documented 70-credit grant if the API omits the grant; the UI labels this fallback. A failed subscription lookup never implies free or unlimited usage. Treat purchased credits separately.

Official rules: https://commandcode.ai/docs/resources/usage-limits

## OpenCode Go

- `GET https://opencode.ai/zen/go/v1/usage`
- `Authorization: Bearer <OpenCode Go API key>`

Parse explicit `usage.rolling`, `weekly`, `monthly` meters. API `usagePercent` is in percentage units: 0.5 is **0.5%**, not 50%. Also accept counters `usedMicroCents` / `limitMicroCents` for percentage calculation without displaying them as dollars. Countdown reset times are anchored to fetch time. Preserve missing monthly readings as unknown. If `usage.models` is explicitly present, keep its model scopes; the current standard aggregate response must not be presented as model-level coverage.

Official rules: https://opencode.ai/docs/go/

## Research reference

Endpoint and payload compatibility research also consulted the public MIT-licensed [CodexBar source](https://github.com/steipete/CodexBar), specifically `Sources/CodexBarCore/Providers/{Kimi,CommandCode,OpenCodeGo}`. PlanWatch's Go adapters are independently implemented against those observed schemas; no CodexBar implementation files are bundled.

Response schemas were validated with synthetic protocol fixtures, not live customer accounts. Unsupported payloads fail visibly rather than silently showing zero usage. The HTTPS client rejects redirects and hides upstream response bodies from errors.
