# Account isolation API contract

**Status:** Backend, browser, and iOS account boundaries implemented locally; native WebRTC build and simulator tests pass. iOS physical-device acceptance passed with no issues, confirmed by the user on October 21, 2026. Hosted two-account verification remains pending.

## Authentication

All learner API routes, including `GET /me`, require a verified Microsoft Entra identity. `GET /health` is public. Browser requests may use the Azure App Service authentication cookie when the deployment sets `TRUST_AZURE_PLATFORM_AUTH=true`, `WEBSITE_AUTH_ENABLED=true`, and `WEBSITE_SITE_NAME`; Azure authentication must require sign-in and remove client-supplied `X-MS-CLIENT-PRINCIPAL` headers before forwarding. Local Uvicorn never trusts that header.

Native clients send `Authorization: Bearer <Entra access token>`. The API validates the v2 issuer and tenant, RS256 signature via the tenant's discovery signing keys, expiry and not-before time, exact `ENTRA_API_AUDIENCE`, delegated `ENTRA_SCOPE`, and `tid` and `oid`. Set `ENTRA_ALLOWED_CLIENT_IDS` to a comma-separated list of approved `azp` client IDs. Set `ENTRA_TENANT_ID` to the admitted tenant GUID. A bearer header takes precedence over the platform cookie.

Absent or invalid authentication returns 401. A valid identity without the API scope or approved client returns 403. Missing configuration returns 503. Tokens and identity claims are excluded from request logs.

## Account and ownership

`GET /me` returns `{ "account_id": "<opaque UUID>" }` with `Cache-Control: no-store`. The value is for client-side partitioning and is never accepted as authority. Verified `(entra, tid, oid)` identities map to one stable internal account UUID.

Every session route scopes its storage lookup to the caller's account. An unknown session, another account's session, or a legacy unowned session returns 404. The check runs in the same transaction as the requested storage operation. Idempotency keys are unique per account: identical keys from different accounts create distinct sessions; retries within one account retain the existing replay and conflict behavior. Existing unowned rows remain unassigned pending an explicit administrative migration.

Browsers and iOS send `X-Expected-Account-ID` with protected requests after `GET /me`. This is a conditional guard, not identity authority: the server first validates the cookie or bearer token, then rejects a mismatched expected ID with 409 and `X-Account-Changed: 1`. It closes the race between checking `/me` and creating a session after a cookie switch. Server-owned timer cleanup can process all sessions. A session owner cannot be changed through an API request.

## Deployment gate

The backend applies database-backed fixed-window limits per verified account:
120 protected requests per minute, 20 session starts per hour, and 20 evaluation
starts per hour by default. `ACCOUNT_REQUESTS_PER_MINUTE`,
`ACCOUNT_SESSIONS_PER_HOUR`, and `ACCOUNT_EVALUATIONS_PER_HOUR` tune them. A
rejected request returns 429 with `Retry-After`; it does not call a provider.
Hosted workers share these counters in PostgreSQL. Each request updates its
applicable counters in one transaction.
The Azure front end still needs an edge limit for anonymous and invalid-token
traffic before public use.

Before allowing multiple accounts, configure the Entra tenant, audience, scope, and allowed client IDs; verify Azure authentication rejects anonymous requests and strips forged identity headers at the actual host; and complete a signed-in browser conversation with two-account denial checks. Backend and browser tests cover route ownership, legacy migration, account switching, expired sign-in, and saved-report scoping. They do not prove the Azure front-end trust boundary.
