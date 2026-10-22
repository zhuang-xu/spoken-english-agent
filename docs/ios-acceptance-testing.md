# iOS acceptance testing

## Current acceptance status — confirmed October 21, 2026

**Passed.** The user confirms that the physical-device acceptance run is complete
with no issues. The iOS physical-device acceptance gate is closed. This status
supersedes the earlier capture failures and pending-device statements below,
which are retained as historical investigation records.

Confirmation was received on October 21; the run date, build/deployment identifiers,
and result bundle were not supplied with this update. No new device test was run
for this documentation change. Hosted two-account isolation and public-rollout
checks are separate from this iOS acceptance confirmation.

## Post-cleanup physical retest — October 22, 2026

Ran the signed current working-tree build on the connected iPhone 16 Pro after
removing the standalone microphone apps, periodic media/PCM counters, and native
WebRTC file logger. The test runner initially needed provisioning and device
certificate trust; after trust was enabled, both physical tests executed.

- `testConnectOnPhysicalDevice` passed (50.327 seconds), including live account
  verification, realtime connection, and an opening agent transcript.
- `testSpokenTurnAndHostedFeedbackOnPhysicalDevice` failed (44.085 seconds): after
  its fixed 20-second recording wait, `finishTurnButton` was absent and the UI
  already showed `startTurnButton`. The support timeline records a 12.6-second
  capture (201,600 frames at 16 kHz, RMS approximately 0.0000151), followed by
  finalization and a return to ready before the automated finish tap. The log
  does not identify what triggered finalization. Nonzero capture alone does not
  establish intelligible speech, audible playback, or successful feedback.

The spoken test stopped before its expected-sentence and saved-feedback checks;
those outcomes remain unverified for this cleanup build. This retest does not
replace the earlier user-confirmed acceptance with a new full pass.

Result bundle: `/tmp/spoken-diagnostic-cleanup-device-trusted.xcresult`.
Build/test log: `/tmp/spoken-diagnostic-cleanup-device-trusted.log`.

## Historical device investigation

## October 13 audio configuration fix

Follow-up investigation identified native initialization failure, not handset
routing. The opt-in debug native log reported `OSStatus -50` when WebRTC reapplied
its saved category/mode/options, followed by `InitPlayout` returning `-1` and
recording initialization failing. The SDK initializes its saved category and
mode from the current Apple session, which was `SoloAmbient` / `Default` before
the call. The app had set voice category/mode on the live session but updated
only routing options on WebRTC's saved configuration. Explicitly persisting
`PlayAndRecord` / `VoiceChat` in that configuration fixes this mismatch.

Also moved account/call construction into one lazy `StateObject` owner, removing
temporary factory construction on root-view recreation. A physical retry logged
one factory yet reproduced the original failure, so that ownership correction
did not resolve the audio initialization failure by itself.

The fixed physical iPhone connection test passed at 09:57 Asia/Shanghai. Its
diagnostic timeline (historical file removed) shows:

- Speaker output and `PlayAndRecord` / `VoiceChat` throughout seven connected
  route snapshots, with built-in microphone and output volume 0.6.
- Initialized playout and recording, with `playing=true` and `recording=true`.
- Inbound audio decoded: 875,520 received samples, 19.36 seconds of sample
  duration, and nonzero total audio energy (0.189294).
- Custom capture/render processing observers still report zero callbacks.
  This run establishes native device startup and decoded audio consumption;
  it does not establish successful local WAV capture or human-confirmed audibility.

Before this fix, all 122 simulator unit tests passed. One device attempt stopped
at account verification before WebRTC; the retry and subsequent native-log run
connected successfully but reproduced the audio failure. Result bundles are in
`/private/tmp/spoken-audio-owner-20261013.xcresult`,
`/private/tmp/spoken-audio-owner-retry-20261013.xcresult`,
`/private/tmp/spoken-native-audio-20261013.xcresult`, and
`/private/tmp/spoken-audio-config-fixed-20261013.xcresult`.

The native WebRTC file logger and periodic media/PCM diagnostic instrumentation
used during these historical runs were removed on October 22 after acceptance.
The normal bounded support timeline remains available.

## October 13 physical audio-route diagnostic run

Ran `PhysicalConnectionTests.testConnectOnPhysicalDevice` exactly once on the
connected iPhone 16 Pro, October 13, 2026, 09:40 Asia/Shanghai. The signed build
and connection test passed; the opening agent transcript appeared and cleanup
closed the transport. This is not a successful audible-playback check.

Before running, preserved existing device logs and added actual audio route,
category, mode, options, sample rate, buffer duration, channel counts, and volume
snapshots at activation, audio-device startup, and every three seconds while
connected. Existing diagnostics also collected receiver state, RTP counters,
audio-device state, and capture/render PCM counters.

- All activation/startup and six connected route snapshots reported `Speaker`.
  No snapshot reported the handset receiver.
- Activation used `PlayAndRecord` / `VoiceChat`, built-in microphone, 48 kHz,
  one input channel, two output channels, and output volume 0.6.
- During startup, the session changed to `SoloAmbient` / `Default`, with no
  input route and output volume 0.35; this persisted throughout the connected
  snapshots. The source of this configuration change remains undetermined.
- All six media snapshots reported `playing=false`, `recording=false`,
  `enabled=false`, and `manual=false`, despite an active session and enabled
  remote audio track. Capture and render callbacks remained zero.
- Inbound RTP grew from 13 packets / 39 bytes to 729 packets / 63,318 bytes,
  with 35 packets lost; decoded sample and audio-energy counters remained zero.
  Incoming network audio therefore does not establish local playout.

The filtered run timeline (historical file removed) contained
metadata only. Full before/after logs are in
`/private/tmp/spoken-audio-route-before-20261013` and
`/private/tmp/spoken-audio-route-after-20261013`; the test result bundle is
`/private/tmp/spoken-audio-route-20261013.xcresult`.
Next investigation: determine why audio-session configuration changes and the
WebRTC audio device remains stopped. No routing or playback fix was attempted
in this single-run check.

Current status, October 12: WebRTC-SDK 137.7151.00 uses the default native audio
device with the retained observer and WAV adapter in `WebRTCAudioCapture.swift`.
Capture, protected local recording, journal uploads, and feedback are connected.
The physical iPhone 16 Pro (iOS 27.0.1) signed build installed and all 121 unit
tests passed on the device. These fixtures do not establish microphone delivery
or hosted speech quality. Live connection passed, but spoken acceptance failed
with zero captured frames as recorded below. Earlier October 10/11 entries describe historical
implementations. Connection-only verification does not pass the speech gate.

## Physical-device verification — October 12, 2026

Device: iPhone 16 Pro (device name “Zhuang’s iPhone 16”), iOS 27.0.1.
The signed app installed and ran on the device.

- All 121 unit tests passed on the phone, including a second full run after the
  diagnostics and assisted-test cleanup changes (`spoken-physical-final-unit-20261012.xcresult`).
- Five fixture-based UI tests passed: recording/transcript controls, background
  stop, feedback/conversation save, offline cached report, and incomplete-practice
  retry. These use generated audio and mocked services.
- The separate live connection test passed: hosted account verification, session
  creation, Azure SDP exchange, ICE connection, data-channel open, manual-turn
  configuration, and explicit session ending.
- The assisted speech test's first attempt timed out creating the hosted session
  (`NSURLErrorDomain -1001`). Three subsequent attempts connected and recorded
  for approximately 20 seconds, but all failed before upload or evaluation.
  The speaker confirmed speaking and hearing no AI opening audio.
- Added payload-free diagnostics. The last two attempts reported both
  `frames=0` and `expected_frames=0`; the last attempt also recorded WebRTC
  audio-device-start events without a reported start error. This establishes
  missing PCM delivery to the writer, not a silent WAV. It does not establish
  whether the cause is the device audio engine, the SDK processing callback,
  or another media-path issue.
- No successful WAV upload, speech transcript, pronunciation assessment, or
  saved hosted feedback was verified. The release speech gate remains open.

Result bundles are under `/private/tmp/`: `spoken-physical-unit-20261012.xcresult`,
`spoken-physical-mocked-ui-20261012.xcresult`,
`spoken-physical-connection-20261012.xcresult`, and the assisted runs
`spoken-physical-audio-20261012.xcresult`,
`spoken-physical-audio-retry-20261012.xcresult`,
`spoken-physical-audio-probe-20261012.xcresult`, and
`spoken-physical-audio-device2-20261012.xcresult`.
The intermediate device-diagnostic build failed on a Swift method rename;
correcting delegate removal to `remove(_:)` compiled successfully in the final
assisted run. Assisted-test cleanup now uses an XCTest teardown block because
an assertion abort can bypass Swift `defer`.

October 11 WebRTC-SDK migration verification: the local binary wrapper resolved
successfully through Swift Package Manager. Xcode 27.0 app builds passed for
generic iPhone and simulator destinations with signing disabled. Both app
bundles embed `WebRTC.framework`; their framework UUIDs match the official
150.7871.01 release. No capture callback or copying is installed. The previous
source checkout and native build tools were removed. No physical microphone or
hosted conversation test was run for this migration.

October 11 cleanup: removed the temporary isolated microphone screen, its launch
flag and UI test, the acoustic recording extension of the connection test, and
sample/meter diagnostic probes. The October 10 entries below are historical;
they do not describe currently available test controls. Production WAV validation
and silent-turn recovery remain. Static review assumes WebRTC serializes device
lifecycle callbacks and the input format remains stable during a call; neither
assumption establishes successful device capture. No new device test was run.

## Automated regression gate

Run from the repository root. Use an installed simulator destination.

```sh
xcodebuild -project mobile/SpokenAgents.xcodeproj -scheme SpokenAgents \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Required assertions:

- A header-only WAV is rejected even when its file is 4 KiB.
- A zero-signal microphone stream is rejected before upload.
- A non-silent 48 kHz input survives conversion into 16 kHz mono PCM with
  plausible frame count and signal energy.
- Cancellation removes unfinished recording data.
- Upload acknowledgement is required before feedback; server readiness alone
  cannot hide unacknowledged uploads.
- A temporary upload failure can recover, reach zero pending items, save a full
  report, and preserve that report after reopening the store.
- Permanent audio rejection persists after relaunch and stops repeated uploads
  and evaluation requests; History distinguishes rejection from pending work.
- Account changes, microphone denial, interruption, reconnect, and offline
  history continue to pass the regular journey suite.

Fixtures verify software behavior. They do not prove microphone acquisition,
provider transcription accuracy, routing, or audible playback.

## Assisted physical-device release gate

Record device/iOS, source state, build time, hosted deployment, and result bundle
or diagnostic timestamps. Mark each item passed, failed, or untested.

1. Start a new practice on the signed-in device. Listen to the opening question.
   The correct output route must be audible at an ordinary device volume.
2. Tap the microphone and say: “After work, I usually read a book and take a walk.”
   Finish the turn. Verify the displayed transcript preserves those words;
   minor punctuation differences are acceptable. Record discrepancies explicitly.
3. Listen to the reply. Check for gaps, crackling, unexpectedly low volume, or
   playback stopping when another turn starts. Repeat for at least three turns.
4. Finish with feedback. Confirm upload receipts, zero pending items, and a full
   coaching report. Diagnostic `audio.turn_saved` entries must show positive
   frames, duration matching the spoken turn, and nonzero RMS. Inspect server
   recording metadata when an upload fails; never infer speech quality from RMS.
5. Enable Airplane Mode, terminate/reopen, and open the same report in History.
   Disable Airplane Mode afterward. Check the full report remains readable.
6. Repeat with headphones and after switching back to speaker. Check both
   recording and output. During another practice, background the app or receive
   an interruption; verify clear state and retention of acknowledged work.
7. Interrupt the network during saving, restore it, and retry from History.
   Verify identical audio is retained, receipts reach zero pending, and report
   generation succeeds without inventing or discarding intended components.

Do not mark a release speech-verified unless steps 1–5 pass on the physical
phone. Record untested route/interruption combinations as release limitations.
A test failure must have an explanation and a passing repeat after the fix.

## Current verification record — October 10, 2026

- Earlier recordings: server metadata confirmed header-only WAVs with zero frames.
- Shared engine: device initialization and connection passed; this alone does
  not establish spoken capture or playback quality.
- Automated: 81 unit checks plus the rejected-recording UI journey passed.
  After the audio lifecycle correction, all 28 capture/call checks passed again.
- First assisted attempt failed at microphone start. Logs showed audio-engine
  restart failure; the engine now remains alive across media-state changes.
- A physical repeat encountered Bluetooth activation during setup and cancelled
  the call. Setup now accepts a new route while actual route loss still stops it.
- Expanded physical iPhone 16 Pro (iOS 27.0.1) test passed at 15:35 Asia/Shanghai:
  connected, tapped microphone, reached Listening to you, and disconnected.
  This proves recording can start, not that speech or feedback is correct.
- Backend pronunciation regression: 37 tests passed, including the exact
  4,096-byte header-only WAV and its 422 decoder response.
- Assisted retry failed on finish. The physical test now finalizes a turn as
  well as starting recording. A muted capture mixer was added to pull input
  through the live render graph; the subsequent hardware test recorded 84,599
  frames at 16 kHz but failed sample validation. This is not a
  passed speech gate. A spoken retry on the built-in microphone is pending.
- Full practice UI regression: all 23 journeys passed. The final unit rerun
  passed all 81 tests on the current graph implementation.
- Built-in microphone spoken retry also failed on finish: metadata shows 54,179
  frames at 16 kHz. The exact validation branch is not yet confirmed. Approval
  to copy only that failed recording for numeric sample inspection is pending.
- Release gate: FAILED. Transcript accuracy, audible playback, successful real
  upload/report generation, and offline report reopening remain unverified.
- Assisted spoken, playback, feedback, and offline report checks: awaiting results.

## Follow-up capture diagnosis

The user corrected the earlier Mirroring answer: tests were performed directly
on the iPhone, and Voice Memos records normally. Mirroring is not established
as the cause. Approved inspection of the one failed recording confirmed all
54,179 signed 16-bit samples were zero; the local copy was deleted afterward.

Confirmed app regression: zero-signal validation was routed into the generic
finish-error handler, which disconnected the entire call. Silent turns now
return to Ready to talk, discard only the unrecorded empty turn placeholder,
and allow retry without committing empty audio. A regression test covers this.
System input mute and voice-processing mute were false. A bypass trial also
returned zeros, so voice processing alone is not established as the cause.
The initial route repeatedly became BluetoothHFP despite speaker UI state.
The diagnostic build uses a standard audio IO engine, an input sink, and an
explicit built-in microphone/speaker preference. Actual spoken success remains
unverified. Numeric input energy before conversion is now instrumented to
distinguish input failure from WAV conversion failure without exporting voice.

### 2026-10-10 isolated recorder device check

After the developer profile was trusted, `IsolatedMicrophoneTests.testRealMicrophoneWithoutWebRTC` launched on the physical iPhone. The debug screen constructed only `AVAudioRecorder`, used the built-in microphone with a record/measurement session, and recorded for 12 seconds without constructing a WebRTC factory or peer connection. A watcher detected `mic_check.started` at 09:50:34.931 UTC and invoked the Mac speech command with the agreed test sentence. At 09:50:47.681 UTC, validation returned `RecordingFailure.noAudio`; the UI test failed. Whether the acoustic sentence was clearly audible at the phone remains awaiting user confirmation. This result does not yet identify a root cause and does not validate a fix. The simulator unit suite completed successfully during this check.

The repeat at 18:04 local time armed the acoustic watcher before launching the UI test. It detected recording start at 10:04:23.689 UTC and completed two Mac speech invocations within the recording window. The recorder again returned `noAudio` at 10:04:36.487 UTC. Audibility at the phone still requires user confirmation; no recording fix is validated.

The user confirmed both acoustic sentences were clearly audible near the iPhone. Inspection of the isolated runs found no `audio.sample_evidence` event, which means validation failed before the RMS loop; the existing log therefore does not establish that these isolated recordings contained zero-valued samples. Added numeric recorder evidence (elapsed recording time, peak meter, byte count, decoded frame count, mute state, and route) to distinguish missing frames from silent samples without exporting voice audio.

Instrumented tests at 18:06 and 18:07 local time recorded approximately 12.7 seconds but produced 4096-byte files with zero decoded frames and peak meter -120 dB. The route was MicrophoneBuiltIn and app input mute false. Releasing AVAudioRecorder before file inspection did not change this result. Next comparison launches the identical isolated screen outside XCTest to determine whether the runner affects capture; this is not yet a diagnosed app root cause.
