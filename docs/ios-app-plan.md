# iOS app implementation plan

**Status:** Phases 0–3 completed at their simulator gates; Phase 4 is next.\
**Source:** [iOS app design](ios-app-design.md).\
**Scope:** One foreground speaking practice at a time on a physical iPhone, with local history and an offline-readable coaching report.

## Outcome and release boundary

The first release lets a learner choose a goal and level, hold a manual-turn voice conversation, save the full conversation, receive feedback, and reopen past practices offline. It uses the existing backend contracts for [sessions](sessions-api-contract.md), [learner inputs](learner-inputs-api-contract.md), [agent transcripts](agent-transcripts-api-contract.md), [completeness](session-recovery-and-completeness.md), and [evaluation](evaluation-api-contract.md). The client owns presentation, media, and recoverable local capture; the backend remains the authority for session state and assessment.

The final acceptance environment is a physical iPhone. Earlier phases use simulator runs and automated tests; live microphone, audio route, WebRTC, and provider behavior remain unverified until the final device pass. Background calling, reconnection to an old session, cross-device history, and public multi-user release are outside this plan.

## Work sequence

Each phase produces a buildable, testable, simulator-runnable artifact and has a gate before dependent work proceeds. Implement the client in `mobile/`. Complete one consolidated physical iPhone verification pass after all features are implemented.

### 0. Create the Xcode project and lock integration choices

- Create and commit a native `.xcodeproj` under `mobile/` with an iPhone SwiftUI app target, unit test target, UI test target, and shared scheme. Keep project settings and nonsecret build configuration in version control so another developer can build from a clean checkout.
- Confirm the project builds, tests, and launches as a minimal app in an iPhone simulator before adding network or media code.
- Choose the minimum iOS version and persistence stack: SwiftData for an iOS 17 minimum, or a SQLite-backed Core Data store otherwise.
- Select and pin a maintained native WebRTC distribution. Record its supported Xcode/iOS versions, license, binary size, and integration method.
- Choose a microphone capture path designed to feed WebRTC and write one complete learner-only recording per manual turn without competing audio sessions. Select a backend-supported format and verify fixture decoding and the 10 MiB per-turn limit in automated tests; verify concurrent live capture in the final device pass.
- Define local journal size, audio retention, backup, and account separation policies. Keep the API base URL in build configuration and secrets out of the bundle.

**Gate:** The checked-in `.xcodeproj` builds, tests, and launches in a simulator from a clean checkout. A short decision record and final device test matrix exist; supported audio fixtures decode successfully. Concurrent microphone and WebRTC capture remains a final device check.

### 1. Implement the call transport

- Create the SwiftUI app shell, typed HTTP client, microphone permission flow, `AVAudioSession` setup, and native WebRTC adapter.
- Generate a UUID `Idempotency-Key` per intended start. Ask for permission before `POST /sessions`; hold the returned temporary credential only in memory.
- Add the local audio track and `oai-events` data channel, exchange SDP at the returned HTTPS `webrtc_url`, and request the opening response after the channel opens. Distinguish API `active` from a connected media channel.
- Implement one manual spoken turn: clear the input buffer, unmute the microphone, capture learner-only audio, finish the turn, commit the buffer, and handle the agent reply. Exercise the event sequence with deterministic fakes before the final live device pass.

**Gate:** The app builds, tests, and runs in a simulator. Faked permission, SDP, data-channel, turn, and timeout cases complete with correct state and cleanup. Live audio and WebRTC are pending the final device pass.

### 2. Build the foreground practice loop

- Implement setup fields and validation from the session contract: speaking goal, CEFR level, optional topic including agent choice, and duration.
- Make one practice state model authoritative for permission, connection, ready, recording, transcript wait, finishing, evaluation, completion, and failure. Tag callbacks with an attempt ID so a cancelled attempt cannot revive.
- Add persistent controls for **Start speaking**, **Finish turn**, audio output, and **End & get feedback**; show learner and agent final transcripts and recording/transcribing/saving progress.
- Correlate each locally generated turn UUID with the provider committed item ID before accepting its final learner transcript. Identify agent parts by provider item ID and content index. Record observed playback as completed, interrupted, or unknown.
- Send a heartbeat roughly every 30 seconds while active. On route changes, interruption, backgrounding, disconnect, or cancellation, stop recording, close media once, and end a known backend session where execution permits.

**Gate:** The app builds, tests, and runs in a simulator. Faked permission denial, timeout, transport loss, phone interruption, route change, and late callbacks produce coherent states and no restarted media. Real interruptions and route changes remain final device checks.

### 3. Make capture and history durable

- Persist the backend session ID and idempotency key immediately after creation. Store preferences, status, conversation parts, and a client session clock in a local database.
- Before upload, persist each intended turn, final text, agent part, and completed audio file reference. Use turn UUIDs and provider IDs as uniqueness keys. Protect audio in files rather than database BLOBs.
- Add an upload journal with immutable payloads, content hashes, receipt states, and exact retry bytes. Persist receipts after server acknowledgment. Reconcile file moves and database rows on launch; expose missing or corrupt local data as an incomplete practice.
- Build History and detail views from local records, newest first. Reopen conversation and cached report offline. Show incomplete practices and retry pending save work; do not offer to resume an old WebRTC connection.
- Add **Delete from this device** and account separation behavior. Deleting local data makes no claim about server deletion.

**Gate:** Several practices survive force quit and relaunch with correct order, transcripts, status, and cached report. Crash-point tests preserve retry payloads; duplicate events and receipts do not create duplicate records. Account switching cannot expose another account's local data.

### 4. Finalize uploads and show coaching

- Upload raw learner audio and final transcript under the same turn UUID, plus final agent transcript parts. Treat 200 identical retries as success and surface 409 content conflicts without changing stored payloads.
- On finish, stop any active turn and wait briefly for its final transcript; then end the backend session, retry pending uploads, and persist an immutable manifest of every intended component before sending it. Include still-missing components in that manifest.
- Check `ready_for_evaluation` through the manifest response or data-status route. Never request evaluation while components are missing or unexpected. Keep a saved practice visible as incomplete if the data cannot be repaired.
- Request evaluation once ready. Handle immediate completion, an existing result, and 202 progress using `Retry-After`; use an explicit retry after failure or relaunch. Save the full completed response locally before showing it as cached.
- Present summary, grammar, vocabulary, coherence, pronunciation, spoken fluency, strengths, next steps, and grounded corrections. Show **Not assessed** when speech evidence is absent. Refresh a cached report online with `GET /sessions/{session_id}/evaluation` only after decoding a valid replacement; a failed refresh must leave the cached copy intact.

**Gate:** End-to-end mocked API tests cover create, upload, end, manifest, data status, 202, and completed evaluation. Identical retries succeed, incomplete data blocks evaluation, and a completed report reopens in airplane mode after force quit.

### 5. Verify the complete app on a physical iPhone and prepare the hosted release

- Define and implement native sign-in and backend access policy for the protected API. The current hosted browser cookie and Function key are not a native authentication contract; never bundle a Function key or provider secret.
- Verify durable hosted session storage and application-level ownership before claiming multi-user report retention or public availability. Add rate limiting for public use.
- Complete privacy and accessibility review: file protection, log redaction, backup/retention policy, VoiceOver, Dynamic Type, reachable controls, and microphone permission wording.
- After all features pass simulator gates, run one consolidated physical-device matrix covering microphone permission, opening question, manual turns, learner-only recording during WebRTC, speaker, wired or Bluetooth output, interruption, backgrounding, dropped network, saving/retry, offline history, and real provider evaluation. Inspect uploaded audio for completeness and transcript alignment. Fix failures and repeat affected device cases before release.

**Gate:** Automated tests pass; a real-device hosted conversation produces a complete report that remains readable offline; supported migration/relaunch cases retain history; the app contains no bundled API secret. Record tested devices, iOS versions, backend deployment, and known limitations before TestFlight distribution.

## Cross-cutting implementation rules

- After each implementation increment, build the shared Xcode scheme, run its automated tests, and launch the app in a simulator to exercise the changed path before moving to the next increment. Perform microphone, audio routing, WebRTC, and real-provider checks together in Phase 5. Fix regressions before proceeding and record the commands, destination, and results in the phase verification record.
- Serialize call events and cleanup in a call coordinator; keep network and media ownership out of SwiftUI views.
- Use bounded HTTP timeouts and `Retry-After`. Never log credentials, audio, transcripts, or raw provider errors.
- Keep every upload and manifest byte-identical across retries. A changed final manifest conflicts with the backend; decide its contents from the journal before the first send.
- Treat `POST /sessions` keyed replay with `realtime: null` as recovery of the session identity, not recovery of a credential. End a known abandoned active session when possible, then use a new key for a new call.
- Track saving and assessment separately in the UI. An ended call, received upload, and completed coaching report are distinct states.

## Verification record to fill during delivery

The implementing agent marks an increment or phase **Completed** only after its build, tests, run check, and stated gate pass. Record the implementation commit, Xcode version, build and test commands/results, run destination and outcome, backend deployment when used, and unresolved defects. If a gate cannot be verified, leave it **In progress** or **Blocked** with the reason and next action; do not mark it complete based on code changes alone. The gates above are planned acceptance criteria; none are claimed as completed by this document.

### Phase 0 and Phase 1 verification — 2026-09-27

**Completed at the simulator gates.** Implementation commit `ad7c16f` contains
the native project, shared scheme, app, and tests. The checked-in project now uses the native
WebRTC variant pinned to `stasel/WebRTC` 153.0.0. Xcode 27.0 resolved its
XCFramework and compiled the native adapter. The shared scheme built and passed
14 unit/UI tests on an iPhone 17 simulator with iOS 27.0. The committed tree was
exported to a clean temporary directory, tested again (14 passed), installed,
and launched explicitly (`com.spokenagents.app`, process 91138).
Tests covered permission denial, session creation and keyed replay, SDP request
and answer with a fake HTTPS endpoint, manual-turn data-channel events and turn
identity, buffer timeout and retry, transport timeout cleanup, and late callback
rejection. Commands from `mobile/`:

```sh
xcodegen generate --spec project-native.yml
xcodebuild -resolvePackageDependencies -project SpokenAgents.xcodeproj -scheme SpokenAgents
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test
xcrun simctl install 38DB423B-15D1-46FD-820D-DC3EE42077AE <built SpokenAgents.app>
xcrun simctl launch 38DB423B-15D1-46FD-820D-DC3EE42077AE com.spokenagents.app
```

The build and test runs used temporary package and derived-data directories.
No backend deployment was used. Live microphone, route,
WebRTC peer, and provider behavior await the Phase 5 physical-device pass. The
[integration decisions and device matrix](ios-integration-decisions.md) record
the pinned distribution, audio and storage policies, WAV fixture, and final
device cases.

### Phase 2 verification — 2026-09-28

**Completed at the simulator gate.** Implementation commit `605a35f`. The foreground practice screen validates and
trims setup values, keeps turn and output controls visible, displays final learner
and uniquely identified agent transcript parts, and distinguishes connection,
recording, transcription, finishing, and ended states. The coordinator sends
heartbeats while a backend session is active and invalidates callbacks on
disconnect, interruption, route change, or backgrounding. It ends known backend
sessions and closes media once. Agent playback remains `unknown` when playback
cannot be observed. The **End & get feedback** action ends the practice; durable
saving and evaluation are scheduled for Phases 3 and 4, so it currently explains
that feedback is pending rather than showing a report.

Xcode 27.0, iPhone 17 simulator (iOS 27.0): the shared scheme built; 19 unit/UI
tests passed, zero failed; the app installed and launched as process 42060.
The test set includes invalid setup, permission denial, connection failure,
manual turn and transcript correlation, duplicate agent parts, heartbeat stop,
interruption, late callbacks, and disconnect during a pending connection. No
backend deployment was used. Commands from `mobile/` used the cached package
directory and a temporary derived-data directory:

```sh
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /private/tmp/spoken-agents-phase2-derived -clonedSourcePackagesDirPath /private/tmp/spoken-agents-packages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO test -quiet
xcrun simctl install 38DB423B-15D1-46FD-820D-DC3EE42077AE /private/tmp/spoken-agents-phase2-derived/Build/Products/Debug-iphonesimulator/SpokenAgents.app
xcrun simctl launch 38DB423B-15D1-46FD-820D-DC3EE42077AE com.spokenagents.app
```

Live route, interruption, concurrent capture, and playback observations remain
for the Phase 5 physical-device pass. This implementation has no durable local
history or upload journal yet; those are Phase 3 work.

### Phase 3 verification — 2026-09-29

**Completed at the simulator gate.** The SwiftData store saves the session ID and
idempotency key after creation, preferences, status, client clock offsets, final
conversation parts, protected WAV file references, immutable JSON upload bytes,
SHA-256 hashes, receipts, and a full cached report. History reads local records
newest first, opens conversation and cached summary offline, retries pending
uploads with original bytes, and deletes local records and audio. Store queries
partition records by account ID. Launch reconciliation recovers an audio file
moved before its journal row was saved and marks missing or corrupt pending data
incomplete. An interrupted active practice cannot reopen its old media session.

Xcode 27.0, iPhone 18 Pro simulator (iOS 27.0): the shared scheme built and
passed **27 tests, zero failed**. The app installed and launched as process 1078.
Tests reopened multiple stored practices and a cached report in date order,
switched account partitions, checked duplicate journal items and receipts,
recovered an orphaned audio file, detected missing audio and a corrupt cached report, preserved bytes across
a 409 and a successful retry, exercised coordinator events through the store,
and opened History from the practice screen in a UI test.
No backend deployment was used. Commands from `mobile/`:

```sh
xcodegen generate --spec project-native.yml
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents -destination 'platform=iOS Simulator,id=67F852BC-E504-4F4B-91BD-D2ED3D42D141' -derivedDataPath /private/tmp/spoken-agents-phase3-derived -clonedSourcePackagesDirPath /private/tmp/spoken-agents-packages -disableAutomaticPackageResolution -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test -quiet
xcrun simctl install 67F852BC-E504-4F4B-91BD-D2ED3D42D141 /private/tmp/spoken-agents-phase3-derived/Build/Products/Debug-iphonesimulator/SpokenAgents.app
xcrun simctl launch 67F852BC-E504-4F4B-91BD-D2ED3D42D141 com.spokenagents.app
```

Implementation commit: `11c52ee`. Phase 4 still owns the immutable final manifest,
completeness check, evaluation workflow, and full coaching presentation. Device
audio and hosted behavior remain Phase 5 checks.
