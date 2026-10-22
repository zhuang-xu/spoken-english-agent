# iOS audio execution and lifecycle audit

## Current acceptance status — confirmed October 21, 2026

**Passed.** The user confirms that the physical-device acceptance run is complete
with no issues. The iOS physical-device acceptance gate is closed. This status
supersedes the earlier capture failures and pending-device statements below,
which are retained as historical investigation records.

Confirmation was received on October 21; the run date, build/deployment identifiers,
and result bundle were not supplied with this update. No new device test was run
for this documentation change. Hosted two-account isolation and public-rollout
checks are separate from this iOS acceptance confirmation.

## Historical audit and verification records

Date: October 11, 2026. Status: code audit, simulator tests, Thread Sanitizer,
and unsigned native device build completed. Physical-device capture and live Azure
interoperability remain unverified. This audit covers app-controlled lifetimes;
it does not establish secure erasure of copies inside Apple/WebRTC frameworks.

## Ownership and shutdown

| Execution context | Owned work/data | Lifetime and shutdown |
| --- | --- | --- |
| Main actor | Call phase, attempt ID, UI, SwiftData context, account generation | Process-managed executor. Disconnect/account change invalidates the attempt, cancels timers, and closes transport. Suspended start/stop/save results recheck the attempt before changing state. |
| WebRTC capture callback | Borrowed full-band channel pointers | Valid only inside the callback. Data is copied into an owned slot before returning. Callback entry captures a lifecycle generation and rechecks it under the gate. Closed admission prevents copying after stop/cancel. Concurrent callback contention fails the recording instead of blocking or silently overwriting samples. |
| Audio ring | Fixed reusable slots, atomic read/write indices | Producer publishes only complete slots. Consumer releases only after conversion. Consumed slots are cleared; stop/cancel clears all remaining slots. Generation-tagged failures cannot poison a later turn. |
| Serial recording worker | Converter, PCM buffers, temporary WAV, worker error | DispatchSource signals coalesce. Worker owns file/conversion access. Generation checks keep stale cleanup from deleting a newer writer. Start/stop use continuations; task cancellation closes admission and queues cleanup. Converter buffers are cleared on finish/cancel. Source cancellation and abandoned-writer cleanup run when the observer is released. |
| Background file queue | Immutable snapshots of URLs, Data, and hashes | Jobs finish their bounded local I/O; cancellation is checked before dispatch and after completion. SwiftData objects do not cross into worker closures. Failed/superseded writes await target cleanup. Store account generation catches switching away and back during suspension. |
| Upload orchestration / URLSession | One pending item per active practice retry, verified request body, response | Duplicate retries for the same practice are suppressed. Cancellation, account generation, practice existence, journal hash, and pending receipt are checked before transmission and acknowledgment. URLSession manages networking threads. Requests already transmitted stay authenticated as their original account; a stale response cannot mark a different generation accepted. |
| WebRTC signaling/playback/network threads | SDK-owned peer/channel/audio objects | Transport state is main-actor isolated. Delegate callbacks forward object identities and immutable events rather than SDK objects. Closed/replaced object callbacks are ignored. SDP awaits recheck generation, and an old failure cannot close a newer connection. SDK thread shutdown itself is owned by WebRTC. |
| Heartbeat and turn timer tasks | Session identifier and timing | Heartbeat holds the coordinator weakly across sleep; iteration ownership ends before the next sleep. Coordinator deallocation cancels timers, schedules main-actor media closure/recorder cancellation, and best-effort backend session ending. |

Successful stop transfers a completed WAV URL to the caller. The journal then owns
its durable protected copy; the source is removed after a successful commit.
Accepted upload files remain intentionally available until a complete report is
saved or the practice is deleted. Failed uploads retain identical bytes for retry.

## Corrections made

- Recorder startup claims its generation and recording state under the same gate
  used by cancellation. Callback failures and worker cleanup are generation-aware.
- Late callbacks cannot copy an old block into a newly started turn. Ring and
  converter samples are cleared once consumed or retired.
- Task cancellation is forwarded to the recorder; abandoned observers remove
  unfinished WAVs and cancel their DispatchSource without a retain cycle.
- Heartbeat no longer retains its owner throughout the sleep loop. Owner teardown
  closes media and cancels recorder work.
- Background file completion checks cancellation and account generation. Awaited
  cleanup prevents an async save from returning while its redundant target remains.
- Uploads check deleted practices and stale account generations, suppress concurrent
  retries, and preserve pending receipts on cancelled work.
- Transport state is main-actor isolated; stale SDP failures and SDK delegate
  callbacks cannot mutate a replacement connection.
- Reconciliation recognizes both legacy two-UUID filenames and the new three-UUID
  filenames, recovering audio after interruption between file writing and journal
  commit under the original practice/turn IDs.

## Verification

The initial audit passed 104 simulator unit tests. Thirteen new tests covered background producer and
consumer ring reuse, borrowed-memory reuse, overlapping callback contention,
32 concurrent cancellations, cancellation of a suspended recorder task, observer
release and WAV deletion, heartbeat-owner release, concurrent duplicate saves,
account switching away and back during file work, cancelled file preparation,
concurrent upload retries, deletion during upload preparation, stale-account upload
preparation, and interrupted-save recovery.

All 13 capture tests also passed with Thread Sanitizer enabled, with no reported
data races. The native device target built with code signing disabled. External
HTTP, provider events, and microphone delivery are mocked in these tests.

## Limits

### Microphone callback correction — October 13, 2026

The SDK 150.7871.01 `RTCAudioCustomProcessingAdapter` initializer creates its
native adapter but never assigns the supplied delegate. This explains why
native recording and decoded audio counters could advance while both custom
PCM callback counters stayed at zero. The transport now creates the processing
module and explicitly assigns its capture and render delegate properties before
creating the factory. Those setters call the native adapter's `SetDelegate`.
The transport retains both observers for the factory lifetime.

Source: [SDK adapter implementation](https://github.com/webrtc-sdk/webrtc/blob/m150_release/sdk/objc/components/audio/RTCAudioCustomProcessingAdapter.mm).
A regression test checks capture/render attachment before and after native
factory construction. Simulator tests do not establish physical microphone
delivery; a spoken iPhone repeat remains required.
Verification: all 51 selected capture and call-coordinator simulator tests passed,
including the native delegate attachment regression, with zero failures.

Physical iPhone 16 Pro repeat at 14:50–14:51 Asia/Shanghai reached recording
and produced a 21.04-second WAV with 336,640 frames at 16 kHz. Capture diagnostics
advanced to 2,104 callbacks / 1,009,920 input frames at 48 kHz, confirming native
delegate delivery after the correction. WAV RMS was only 0.00000903. The assisted
test failed its expected learner-sentence assertion; hosted feedback was not
reached. Whether the test sentence was spoken in the recording window needs
confirmation. This is a callback-delivery pass, not a passed spoken acceptance
test. Result bundle: `/tmp/spoken-mic-physical-20261013.xcresult`.

The user confirmed speaking during this recording window. WebRTC's media-source
energy was also near zero before WAV conversion, so conversion alone does not
explain the missing sentence. SDK `RTCAudioBuffer.mm` exposes the native
`AudioBuffer::channels()` FloatS16 samples as expected. A normal app launch outside
XCTest is the next comparison; test-runner interference remains a hypothesis,
not an established cause.

The normal-launch repeat at 14:58 Asia/Shanghai also failed: all 262,080
observed input samples were zero; finalization rejected 87,360 output frames
(5.46 seconds) with no energy. Output PCM had nonzero energy. This rules out
XCTest as the sole explanation for the observed failure. The next comparison
uses the SDK's `.audioEngine` device in place of `.platformDefault`, keeping
the SDK as the single audio owner. This device change is provisional pending
physical spoken verification.

The user reported loss of audible agent playback with the `.audioEngine`
comparison build. The device switch was reverted to `.platformDefault`;
explicit capture/render delegate attachment remains. The alternate engine is
not a validated fix and should not be shipped. Microphone silence remains open.

### Explicit microphone startup checks

The coordinator now calls a throwing `startInput()` after opening its local
writer, before entering recording. The transport clears processing-module mute,
initializes/starts recording only when needed, checks each return code, and
unmutes the device only when it reports muted. The track is enabled only if
recording is initialized/running and both mute checks permit input. Failures
cancel the local writer through the existing coordinator cleanup path.

`audio.input_start` records init/start/unmute results, processing/device mute
states, track enablement, recording state, and manual-audio flags together.
The SDK may report false when device mute readback is unsupported; this is not
proof of hardware input state. Successful startup still does not establish
nonzero microphone samples. The platform-default audio device and session
configuration are unchanged. A coordinator regression covers startup failure
without entering recording or committing audio. Physical verification remains
pending.

### OpenAI-style push-to-talk flow

Microphone startup checks now run once during connection, after sending manual
turn configuration. The track remains enabled between turns. Start clears the
provider input buffer and opens the local WAV writer; finish closes the local
writer, commits the provider buffer, and requests a response. Disconnect,
interruption, and account changes still disable input and close the transport.
Audio streams to the provider throughout the connected session, including idle
periods; local WAV capture remains restricted to an active turn. The next clear
discards uncommitted audio accumulated between turns. This follows the
[OpenAI demo's clear/commit flow](https://github.com/openai/openai-realtime-agents/blob/main/src/app/App.tsx#L276).
It removes per-turn track toggling but does not yet establish the cause of the
physical microphone silence. No audio-engine switch is involved.

Physical continuous-input repeat at 15:47–15:49 Asia/Shanghai still failed.
Both successful connections reported init/start result 0, initialized/running
recording, enabled track, and processing/device mute false after startup.
Processing mute was true before startup and was explicitly cleared. Two turns
were rejected with 63,680 and 167,360 zero-energy output frames respectively.
Capture callbacks continued between turns, yet the recorded turns had zero
energy. Removing per-turn track toggling did not resolve the observed silence.
These measurements do not identify whether zeros originate at the OS audio-unit
output or inside downstream WebRTC processing; that boundary remains unmeasured.

The main thread and system worker/network pools live for the process; they are not
created or destroyed per turn. Queue jobs and resources are retired explicitly.
Cancellation of a file job waits for its already-dispatched local I/O to return
before checking cancellation and cleaning up. It cannot abort a synchronous OS file
operation midway.

Forced process termination cannot run deinitializers. Completed journal-directory
writes can be recovered by reconciliation; an unfinished protected temporary WAV
can remain until the operating system clears temporary storage. Runtime tests
establish cleanup for normal stop, failure, cancellation, and owner release, not
cleanup after a process kill. No test establishes complete erasure of framework
copies, physical microphone delivery, or all possible scheduler interleavings.

## Expanded coverage from different failure boundaries

Added 17 further cases after the initial audit:

| Area | Added cases | Expected behavior |
| --- | --- | --- |
| Capture and conversion | 6: cancellation of pending start, duplicate start while opening, nonfinite PCM, 8/32 kHz resampling across turns, writer-open failure/retry, 25 rounds of start versus concurrent cancellation | No orphaned writer or stale turn data; errors release start state; output duration matches captured input; subsequent turns remain usable. |
| Durable file transactions | 5: cancellation, account change, and practice deletion after file writing; concurrent conflicting saves; destination write failure/retry | The uncommitted target is removed before completion; caller-owned source survives failed commits; exactly one conflicting writer wins; no duplicate journal/file remains. |
| In-flight HTTP uploads | 4: late acknowledgment after switching accounts away/back, late acknowledgment after deletion, cancellation after transmission, network timeout followed by retry | Stale responses cannot accept or resurrect metadata; pending bytes stay identical; retry ownership is released after failure/cancellation. |
| Call coordination | 2: account change during finalization, End while finalization is suspended | Late files/events are discarded; End waits for the in-flight turn and commits/ends exactly once. |

File transaction tests use an optional worker-side boundary observer to pause
after the WAV exists but before its SwiftData journal commit. Network tests use
per-host response gates with a locked registry, locked captured-body state, and
atomic cancellation; they pause actual URLSession test requests before delivering
acknowledgments. Capture tests include a 25-round race with eight concurrent
cancellations per round. Mutable coordinator test doubles are main-actor isolated;
their synchronous cancellation counter is atomic.

The new lower-rate test exposed an AVAudioConverter filter tail extending output
beyond the source duration. The writer now tracks expected 16 kHz frame count,
bounds output to the captured input duration, and rejects an incomplete conversion.
This also prevents filter-tail frames alone from exceeding the five-minute limit.

Latest verification: 121 simulator unit tests passed; the 77 tests across capture,
PracticeStore, in-flight uploads, and call coordination also passed with Thread
Sanitizer enabled and no reported races. The unsigned native device build passed.
These results broaden observed scheduling and failure coverage; the physical-device
and process-termination limitations above still apply.

## Result collection follow-up — October 12, 2026

Confirmed the completed Xcode result bundles directly: the full unit run records
121 passed and zero failed tests; the Thread Sanitizer run records 77 passed and
zero failed tests. No data races were reported. Xcode's delayed exit was attributed
to simulator diagnostic collection timing out after 600 seconds, after the test
process had completed. Concurrent older runs also appended to shared log paths;
the individual result bundles are the authoritative per-run records.

The sanitizer bundle records one priority-inversion warning attributed to
`PracticeStoreTests.testConcurrentRetryAndCancellationDuringPreparationSendNoRequest`:
a user-initiated thread waited on a default-priority thread. A targeted sanitizer
rerun passed, but changing the injected file queue to user-initiated priority did
not remove the warning, so that change was reverted. The warning's exact source
remains unresolved; the exported activity record contains no call stack. It is
distinct from a reported data race and should not be presented as resolved.

For subsequent runs, use unique log/result paths and
`-collect-test-diagnostics never` when verbose simulator diagnostics are not
needed. The targeted rerun completed normally with this setting.

## Physical-device follow-up — October 12, 2026

The signed iPhone 16 Pro/iOS 27.0.1 run passed all 121 unit tests and five
fixture-based UI regressions. A separate live Azure connection test passed.
Assisted spoken turns failed: after connection and recording, zero frames reached
the WAV writer. WebRTC reported audio-device startup, but the speaker heard no
AI audio. Real microphone delivery, upload, and hosted speech feedback remain
unverified. See [the acceptance record](ios-acceptance-testing.md) for evidence
and the still-open release gate.

The capture worker now records numeric empty-turn counters before rejecting the
file. A transport-owned weak audio-session observer records start/stop and start
errors and unregisters on deallocation; it stores no PCM or conversation content.
The assisted UI test uses XCTest teardown rather than Swift `defer` to close the
session even when an assertion aborts the test.

## Diagnostic cleanup — October 22, 2026

Physical-device acceptance passed on October 21. The standalone microphone test
apps, periodic RTP/media snapshots, capture/render PCM diagnostic counters, and
debug native WebRTC file logger have been removed. The capture post-processing
delegate remains attached because it supplies learner audio to the WAV recorder.
The bounded support timeline, audio-session lifecycle/error events, and assisted
acceptance tests remain available for future regressions. Earlier diagnostic
results above describe historical investigation builds.
