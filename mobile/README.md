# iOS client

Phase 5 physical-device acceptance is complete with no issues, as confirmed by
the user on October 21, 2026. Earlier failed audio runs are historical; see the
[device acceptance record](../docs/ios-acceptance-testing.md).
The checked-in `SpokenAgents.xcodeproj`
has an iPhone SwiftUI app, unit tests, UI tests, a shared scheme, and the pinned
native WebRTC package. Its call coordinator, backend client, SDP exchange,
permission flow, manual-turn event handling, and WAV recorder are exercised with
fakes. The foreground practice loop validates setup, shows transcript parts,
sends heartbeats, and handles cancellation and audio interruptions. A SwiftData
store keeps sessions, transcript parts, protected turn audio, an immutable
upload journal, final manifests, and full cached reports. Finishing a practice
retries uploads, declares every intended component, checks readiness, and requests
coaching with bounded progress polling. History opens the full report offline,
retries saving or assessment, and refreshes an existing report without losing its
cached copy. Native sign-in now uses MSAL and a delegated Spoken Agents API scope.
The app verifies `/me` before selecting an account's SwiftData partition. The
legacy `local` partition remains hidden. A cached MSAL account can reopen its
previously verified history offline; sign-out hides it immediately. Physical-device acceptance is complete; hosted two-account isolation remains a separate verification item.
The app limits a recorded turn to five minutes and removes acknowledged upload
bytes after a complete report is saved. Pending uploads remain available for retry.
The [account isolation plan](../docs/account-isolation-plan.md) puts backend
ownership enforcement before native sign-in and defines how verified accounts
select local history partitions.

## Source organization (MVVM)

The app source under `SpokenAgents/` is organized by responsibility:

```text
SpokenAgents/
├── App/                       # App entry point and dependency composition
├── Models/                    # Session, conversation, account, and coaching values
│   └── Persistence/           # SwiftData records
├── ViewModels/                # Observable presentation state and actions
├── Views/                     # Root navigation
│   ├── Account/
│   ├── Practice/
│   ├── History/
│   ├── Diagnostics/
│   └── Components/            # Shared cards and palette
├── Services/
│   ├── Authentication/        # MSAL adapter and keychain account binding
│   ├── Networking/            # Session API, uploads, and coaching requests
│   ├── Persistence/           # PracticeStore and protected local files
│   ├── Audio/                 # Microphone permission and recording
│   └── Realtime/              # WebRTC transport and SDP exchange
└── Support/
    ├── Diagnostics/           # Persistent logging
    └── Testing/               # DEBUG-only UI journey fixtures
```

`CallCoordinator` serves as the conversation view model; `AccountSession` serves
as the account view model. Their existing names and interfaces are retained.
Views observe their state and invoke actions, while services handle external I/O.
`PracticeStore` remains an observable persistence service shared by practice and
history. Simple form and navigation state stays local to SwiftUI views; this
folder reorganization does not extract every existing view action into a new
view model. The app entry point composes and injects these dependencies.

Keep data declarations in `Models`, screen behavior in `ViewModels`, and platform
or backend integrations in `Services`. Configuration, entitlements, and assets
remain at their existing paths. Both XcodeGen specs recursively include the
source tree; regenerate the native project after adding or moving files.

## Build, test, and run

Open `SpokenAgents.xcodeproj`, select the `SpokenAgents` scheme and an iPhone
simulator, then Build, Test, and Run. The equivalent command-line checks are:

```sh
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO test
```

`project-native.yml` is the XcodeGen source for the checked-in project. Regenerate
with `xcodegen generate --spec project-native.yml` after changing target settings.

The native build is configured for the `spoken-agents-ios` public client and hosted
API. Its redirect URI is `msauth.com.zhuangxu.spokenagents.app://auth`.
The API registration exposes the delegated `access_as_user` scope, and the native
client requests it. The hosted API validates that audience, scope, and client ID.
These IDs, URLs, and scope are public configuration, not secrets. Hosted account verification passed in the recorded physical connection test;
the user has since confirmed completion of physical-device acceptance. The app
sends the MSAL access token
only to `API_BASE_URL`; the separate short-lived realtime credential goes only
to the provider's SDP endpoint. The native client uses the
`com.microsoft.adalcache` keychain sharing group.

## Native WebRTC variant

The app requires iOS 26.0 or later. The checked-in project uses the local
Swift package manifest at `Packages/WebRTC/Package.swift`, wrapping the official
WebRTC-SDK **150.7871.01** binary. Xcode downloads the release archive and verifies
its upstream SHA-256 checksum; the framework itself is unmodified. MSAL remains a
separate remote Swift package dependency.

The upstream release manifest declares tools 5.9 but uses `.visionOS(.v26)`,
which requires PackageDescription 6.2. Direct package resolution was retried on
October 12 and failed. The local wrapper declares tools 6.2 to correct this
manifest mismatch, so Xcode 26 or later is required. Update the binary URL and
checksum together when upgrading; return to a direct upstream dependency when
its manifest is corrected. Physical-device audio must be verified after upgrades.

`project.yml` is a fallback without the WebRTC package; use `project-native.yml`
to regenerate the native project. The native transport uses the factory's default native audio device, so
WebRTC's iOS AudioUnit device owns capture and playback.
`Services/Audio/WebRTCAudioCapture.swift` retains a capture post-processing observer
and implements the existing turn recorder. The app shares it with the transport
and call coordinator. A 20-slot pool copies full-band FloatS16 microphone samples
only during a learner turn; a serial worker normalizes, downmixes, resamples, and
writes protected 16 kHz mono Int16 WAV files. Overflow, unsupported formats,
mid-turn format changes, and capture release invalidate the recording rather than
uploading partial audio. Existing UUIDs, journal uploads, and feedback are reused.
Physical-device acceptance passed, as confirmed by the user on October 21, 2026.
Recorder start/stop suspend while the worker opens or finalizes the file; cancel
queues cleanup. Live journal file preparation and upload reading/hashing run in
background tasks. SwiftData commits and account checks stay on the main actor.
Uploads retain at most one bounded turn body in memory (up to 10 MiB).
See the [audio lifecycle audit](../docs/ios-audio-lifecycle.md) for thread ownership,
generation checks, cleanup, concurrency tests, and remaining device-verification limits.

No
Function key or provider secret is included. `API_BASE_URL` points to the hosted
API and can be overridden through a nonsecret build configuration for local work.

See the [implementation plan](../docs/ios-app-plan.md) and
[design](../docs/ios-app-design.md) for phase gates and remaining work.

Authenticator returns are handled once by the UIKit scene delegate, preserving
`sourceApplication` for MSAL broker validation. Sign-in failures show whether
Microsoft authentication or API account verification failed, with error codes
only. The physical-device acceptance run is complete per the user confirmation;
no separate Authenticator round-trip result was supplied in that update.

## iPhone diagnostics

The capture post-processing delegate is assigned through its property setter
because the SDK adapter initializer ignores the supplied delegate. This callback
supplies learner audio to the WAV recorder and remains covered by a native-module
regression test. Physical-device acceptance passed on October 21, 2026; see the
[device test record](../docs/ios-acceptance-testing.md).

The standalone microphone test apps, periodic WebRTC media statistics, PCM signal
counters, and debug native file logging were removed after acceptance. Normal
support logging remains available below.

The app persistently records UTC timestamps, launch and connection attempt IDs,
sign-in states, request routes/status/timing, microphone and audio lifecycle,
WebRTC offer/answer stages, ICE/channel states, and provider error codes. It does
not record credentials, authorization headers, query strings, request/response
bodies, SDP, audio, or conversation text. Errors include domain/code and decoding
field paths, excluding error descriptions and userInfo. Two rotating JSONL files
retain approximately 2 MB total across launches, with file protection and no
cloud backup. Diagnostics failures never block the app.

To reproduce: open the app, sign in if needed, tap Connect, then open **Diagnostics**
and **Share diagnostic log**. Refresh prepares a new snapshot. A connected,
unlocked development iPhone also allows direct retrieval without sharing:

```sh
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier com.zhuangxu.spokenagents.app \
  --source 'Library/Application Support/Diagnostics' \
  --destination /tmp/spoken-device-diagnostics
```

Read `current.jsonl` and `previous.jsonl` in timestamp order. A `call.connect_failure`
identifies the stage; its preceding `http.response`, `http.failure`, and `rtc.*`
entries show the underlying status or state. A successful API session creation
followed by a failing provider SDP request distinguishes backend and WebRTC faults.

The first physical-device log identified successful `/me`, session creation,
and provider SDP responses, followed by route change reason 8
(`routeConfigurationChange`) during WebRTC audio setup. The app now continues
through this expected I/O configuration event; actual route-loss notifications
still stop practice. Regression tests cover both cases.

## Automated UI journeys

Simulator UI tests run without Microsoft sign-in, network access, microphone
permission prompts, or WebRTC hardware. `PracticeJourneyTests` covers sign-in
success/failure, sign-out and account isolation, setup validation, connection
retry and microphone denial, recording controls and transcripts, background interruption, disconnect,
feedback completion, offline report relaunch, saved-work retries, processing
feedback, failed refresh, deletion cancellation/persistence, and diagnostics.

```sh
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:SpokenAgentsUITests CODE_SIGNING_ALLOWED=NO test
```

The DEBUG-only `UITestEnvironment` requires `--ui-testing` and a UUID in
`UI_TEST_ID`. Every test uses a separate SwiftData directory under `UITests` and
an in-memory account binding; relaunch tests reuse their ID to verify persistence.
`UI_TEST_SCENARIO` selects local fixtures. Tests exercise the regular app views,
account session, coordinator, HTTP clients, and store with fake authentication,
audio, realtime events, and URLProtocol responses. History receives the same
injected coaching client so retry and refresh stay inside the fixture network.
Failure screenshots are attached to the Xcode test results. Release builds omit
the fixture environment. The existing physical connection test remains separate
and skips on simulators.

## Practice interface

The [UX redesign](../docs/ios-ux-redesign.md) introduces separate Home and History
tabs, an account avatar, real-life scenario cards, a session setup sheet, and a
full-screen conversation with fixed speaking controls. Start opens setup;
Start conversation connects after the user confirms their choices. Account
sign-in/out and diagnostics are available from the avatar. Existing account
isolation, recording, retry, and offline report flows remain in use.

## Release acceptance

Use the [iOS acceptance procedure](../docs/ios-acceptance-testing.md) for audio
and feedback releases. A passing build or connection test is not a passing
spoken session. Recording validation checks decoded frames, duration, and RMS
without logging speech text.
