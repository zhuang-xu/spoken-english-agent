# Account isolation implementation plan

**Status:** Backend, browser, and native sign-in implemented and tested locally; hosted auth-boundary and physical-device verification remain pending.  
**Order:** Backend identity and ownership → hosted browser migration → iOS sign-in and account binding → hosted verification.  
**Related:** [backend account isolation API contract](account-isolation-api-contract.md), [architecture](architecture.md), [browser WebRTC contract](browser-webrtc-api-contract.md), [iOS app plan](ios-app-plan.md), and [hosted storage contract](hosted-storage-api-contract.md).

## Goal and current boundary

Each authenticated learner can create, upload to, end, and evaluate only their own sessions. The same learner reaches the same backend account from the hosted browser and iOS app. The server derives identity from a validated sign-in; `account_id` in a request body, URL, or arbitrary header is never authority.

Today Azure platform Microsoft sign-in protects the hosted browser and supplies a session cookie, but FastAPI stores no session owner and performs no per-session authorization. The Function trigger is anonymous only behind platform authentication. Local Uvicorn has no authentication. The iOS app has a local account partition defaulting to `local`, but sends no authenticated API request. Hosted Blob-backed SQLite shares state across instances at low volume; it does not isolate accounts. Existing session IDs are therefore not safe multi-user capabilities.

## Identity contract to establish before code changes

- Register the Spoken Agents API as a Microsoft Entra resource with a delegated learner scope. Configure an allowed tenant, API audience, and approved browser and iOS client IDs. Start with one tenant; supporting other organizations or personal Microsoft accounts requires an explicit tenant admission policy and tests.
- For iOS bearer requests, the backend validates a version-appropriate Entra access token using the issuer's discovery document and signing keys. Require signature, expiry/not-before, exact issuer and tenant, API audience, delegated scope, an approved client where configured, and nonempty `tid` and `oid`. Reject ID tokens, tokens for Microsoft Graph, app-only tokens, unsigned tokens, and unsupported algorithms. Cache signing keys with rotation support; never log tokens.
- For the hosted browser, accept the Azure authentication principal only when the deployment guarantees that all requests pass through platform authentication and client-supplied identity headers cannot reach FastAPI as trusted claims. Verify that boundary in the deployed app. Local tests inject a principal through a test dependency, not through a production bypass setting.
- Both paths normalize a verified `(provider, tenant_id, object_id)` identity. A unique `account_identities` row maps it to an opaque internal account UUID. Email and display name are optional presentation data, never ownership keys. Add `GET /me` to return the current opaque account ID for client partitioning; the server never accepts that value back as proof of identity.
- Return 401 for absent/invalid authentication, 403 for a valid identity without the required API permission, and 404 for an unknown or other-account session. Keep `/health` and browser assets public only if the hosting policy explicitly permits them.

## Backend increment: enforce ownership in storage transactions

1. Add `owner_account_id` to `practice_sessions` and a unique account identity mapping. Existing rows remain unowned and inaccessible through learner routes. Do not assign them to the first person who signs in. Decide any one-time administrative migration separately, with evidence of ownership.
2. Replace the global unique idempotency-key index with uniqueness on `(owner_account_id, idempotency_key)` for nonnull keys. A replay can find only the caller's session. Preserve the existing same-owner replay and conflict behavior.
3. Add a `current_account` dependency to session creation, heartbeat, end, learner audio and transcript upload, agent transcript upload, manifest, data status, and evaluation POST/GET. Pass `account_id` into services and include it in the session lookup **inside the same database transaction** as each read or write. Do not authorize from a separate preliminary query that can race or be forgotten by a new route.
4. Keep timer cleanup and provider work server-owned; they may operate on all rows without a learner request. Any new list or delete route must apply the same owner filter. Use route-template logging only; exclude identity tokens, audio, transcripts, and personal claims.
5. Add a database migration test from the current schema. Test two accounts using the same idempotency key and session/turn IDs; attempt every route against another account's session; test forged/missing/expired/wrong-audience/wrong-tenant/wrong-scope tokens and unsigned identity headers. Confirm failures do not mutate data or call providers.

**Backend gate:** Cross-account route tests pass; old unowned rows are not exposed; the hosted auth boundary rejects forged identity; and one signed-in browser account can still complete a conversation. Publish a stable backend authentication and ownership API contract under `docs/` before changing client request behavior.

## Browser increment: bind local recovery to the signed-in account

- Keep the hosted browser's platform sign-in cookie and same-origin API requests. Load `GET /me` before enabling practice or showing a saved feedback reference. Show a sign-in/session-expired state on 401 and do not turn an authentication error into a new anonymous session.
- The browser currently stores the last completed report's session ID and goal in local storage. Namespace that reference by the verified account ID or clear it on account change/sign-out. Ignore or remove the existing unscoped key; do not display its saved goal for a different account. A server-side 404 remains authoritative if the reference is stale or owned by someone else.
- Preserve exact upload bytes, manifest and evaluation retry behavior through an expired browser session. After reauthentication, resume only work that is still available in memory for the same account; never replay it under a different account. Add browser tests for account switch, expired sign-in, stale saved report, and a 404 on a foreign session.

**Browser gate:** Two hosted test accounts cannot read or modify each other's sessions or display each other's locally remembered report metadata. Existing single-account conversation and feedback tests still pass.

## iOS increment: acquire API access and bind local history

- Register a native public client and use MSAL's authorization-code flow with PKCE to obtain an access token for the Spoken Agents API. Keep tokens in the authentication library's protected cache; do not ship a Function key, provider secret, or a hard-coded user ID.
- Add an authentication owner above the HTTP clients. Acquire or refresh the token before API requests, attach it as `Authorization: Bearer`, and stop retrying with the old identity after sign-out or account change. A 401 offers sign-in again; a 403 reports denied access; a foreign-session 404 does not trigger a new upload under another account.
- Use authenticated `GET /me` to select the SwiftData account partition. The existing `local` partition is legacy device data and must not be silently assigned to the first signed-in account. Keep it inaccessible while another account is active unless an explicit migration flow is designed. Prevent queued uploads and cached reports from crossing account boundaries.
- Run simulator tests with two identities, token expiry, sign-out during a pending upload, relaunch, and offline report reading. Then include sign-in, account switching, token refresh, and cross-account denial in the consolidated physical-iPhone pass.

**iOS gate:** The app makes protected API calls without bundled secrets; only the verified account's local history and queued work are visible; a real-device hosted conversation produces a report that reopens offline.

## Release and rollback

Deploy the backend migration and enforcement before enabling additional users or the native client. Keep existing public traffic behind Azure platform authentication during rollout. Verify the configured tenant, audience, scope, allowed clients, and identity-header trust boundary in the actual hosted deployment. Add account-aware rate limits before public access. The Blob snapshot store is durable for the current private low-volume service; assess a database service before promising high-volume multi-user operation.

Roll back client exposure if any account-boundary test fails. Do not fall back to a shared or anonymous account, and do not disable ownership checks to recover access. Preserve unowned historical rows for an explicit administrative decision. Record deployment IDs, test accounts, denied cross-account requests, and any data migration in a release verification note.

## Identity references

- [Microsoft access-token validation](https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens) and [claims validation](https://learn.microsoft.com/en-us/entra/identity-platform/claims-validation)
- [Azure App Service identity headers](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-user-identities)
- [Microsoft mobile app API flow](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-mobile-call-api)
