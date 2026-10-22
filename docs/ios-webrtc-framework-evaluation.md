# iOS WebRTC framework evaluation

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

**Current integration (October 12):** Updated from 137.7151.00 to the latest
WebRTC-SDK release, 150.7871.01. Direct upstream package resolution failed on
the tools-5.9 / visionOS.v26 manifest mismatch. The local wrapper at
`mobile/Packages/WebRTC/Package.swift` declares tools 6.2 and uses the unmodified
official release archive with its upstream checksum. Historical M137 findings
below describe the previous integration. Physical-device audio remains pending.

Date: October 11, 2026. Status: released-binary API and compile/link evaluation
complete; device microphone delivery and Azure interoperability are unverified.
The subsequent October 11 migration selected WebRTC-SDK 150.7871.01 with
`.platformDefault` and no sample callback/copying. The abandoned upstream source
checkout and build tooling were removed.
The final pinned 137.7151.00 integration now includes the capture observer and
turn WAV adapter described below; device microphone delivery remains pending.

The initial 150.7871.01 integration needed a local binary wrapper because the
upstream tools-5.9 manifest uses `.visionOS(.v26)` (PackageDescription 6.2).
The subsequent iOS 26 migration replaced that wrapper with a direct remote
package pinned to `137.7151.00`. The 144-series has the same manifest error;
later 137-series tags use `.visionOS(.v2)` (PackageDescription 6.0) with tools 5.9
and also fail resolution. `137.7151.00` uses the compatible `.visionOS(.v1)`.
The evaluations below describe the originally tested binaries; physical-device
capture and interoperability must be verified again for the selected older release.

## Result

Both standalone LiveKitWebRTC and WebRTC-SDK expose an Objective-C audio
processing delegate callable from Swift, alongside the platform-default audio
device. Neither requires the full LiveKit SDK or a LiveKit server when used as
a peer-connection framework with our existing SDP and data-channel transport.

Prefer evaluating WebRTC-SDK first for this app because it retains `import WebRTC`
and the existing `RTC…` type names. LiveKitWebRTC is also viable but renames the
module and Objective-C symbols. Both evaluated releases use M150, whereas our
previous stasel dependency used M153; this is a version change, not a claim of
equivalence in fixes or runtime behavior.

| Distribution | Evaluated version | Input callback | Integration assessment |
| --- | --- | --- | --- |
| [WebRTC-SDK](https://github.com/webrtc-sdk/Specs) | 150.7871.01 | `RTCAudioCustomProcessingDelegate` through `RTCDefaultAudioProcessingModule.capturePostProcessingDelegate` | Best initial candidate; familiar module/type names. |
| [LiveKitWebRTC](https://github.com/livekit/webrtc-xcframework) | 150.7871.03 | Equivalent `LKRTC…` delegate and processing module | Suitable standalone framework; prefix migration required. |
| [stasel/WebRTC](https://github.com/stasel/WebRTC) | Previously pinned 153.0.0 | No public input PCM observer found in that binary's headers | Native voice transport works as an API baseline; recording requires a framework extension. |
| [Pexip WebRTC Objective-C](https://github.com/pexip/webrtc-objc) | Default manifest points to 115.0.5790 | Not verified | Older default package; no demonstrated recording advantage. Not downloaded or compiled. |

These are Objective-C interfaces over native WebRTC, usable from Swift.
Swift Package Manager distribution does not mean their implementation is Swift.

## Concrete integration API

The checked binary headers support:

1. A retained `RTCAudioCustomProcessingDelegate` implementing
   `audioProcessingInitialize(sampleRate:channels:)`,
   `audioProcessingProcess(audioBuffer:)`, and `audioProcessingRelease()`.
2. `RTCDefaultAudioProcessingModule(config:capturePostProcessingDelegate:renderPreProcessingDelegate:)`.
3. `RTCPeerConnectionFactory(audioDeviceModuleType: .platformDefault,
   bypassVoiceProcessing: false, encoderFactory: nil, decoderFactory: nil,
   audioProcessingModule: processing)`.
4. Reading `RTCAudioBuffer.channels`, `.frames`, and
   `.rawBuffer(forChannel:)`, copying data before the callback returns.

LiveKit equivalents prefix those Objective-C types with `LK`.
The callback is capture **post-processing**; it is not untouched hardware input.
The callback buffer cannot be retained beyond its call. Production recording
must copy into owned storage and perform conversion/file I/O asynchronously.
The processing delegate property is weak, so the app must retain the observer.
The sample scale, format changes, buffering, and turn boundaries require an
explicit recording adapter; the compile probe is not that adapter.

## Verification performed

Downloaded the actual release XCFrameworks, not just current source headers.
Verified SHA-256 against each Swift package manifest:

- WebRTC-SDK: `03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa`.
- LiveKitWebRTC: `5727a03c32ed902da570b699e3983e3fb4bfe853ab4da045af70912a7db44557`.

An isolated Swift probe compiled and linked against each binary for
`arm64-apple-ios17.0` and `arm64-apple-ios17.0-simulator` with Xcode 27.0.
The probe includes the processing delegate, buffer copying, platform-default
factory creation, peer connection, learner audio track and `oai-events` channel.
All four compile/link checks passed. Device and simulator output platform tags
were confirmed for the WebRTC-SDK probe. No microphone was accessed and no
network session was opened by these probes.

Review artifacts are outside the app:

- `/private/tmp/spoken-webrtc-sdk-binary-review/AudioCallbackProbe.swift`
- `/private/tmp/spoken-livekit-binary-review/AudioCallbackProbe.swift`

## Next bounded verification

### Pinned 137.7151.00 API verification — October 11, 2026

Verified the resolved Specs revision `1aadb8523929f8f2c57de850e88d7afce7ecd1c8`
and cached release archive checksum
`f2da959264b6e28ab2bb1efd59966cddd795d81166df54b5725ad83cb18a4964`
against its package manifest. SwiftPM normalizes the version to `137.7151.0`.

The actual binary headers expose all three `RTCAudioCustomProcessingDelegate`
callbacks, `RTCAudioBuffer.channels`, `.frames`, and `.rawBuffer(forChannel:)`
returning per-channel `float *`, and the processing-module initializer with a weak
capture delegate. The buffer is explicitly valid only inside the process callback.
The factory accepts `bypassVoiceProcessing:encoderFactory:decoderFactory:audioProcessingModule:`
with its default audio device; the newer `audioDeviceModuleType:` argument is absent.

An isolated Swift probe retained the observer and module, copied a channel, and
created the factory, peer, audio track, and data channel. Compile/link passed for
arm64 iOS 26 and arm64 iOS 26 simulator. The toolchain emitted an incompatible
macOS sysroot warning during linking; output platform tags were checked separately.
Probe source and outputs: `/private/tmp/spoken-webrtc-137-api-probe/`.
This allocation-based probe is API verification, not the production buffer pool.

Headers do not document sample amplitude scale or callback cadence. The matching
[M137 AudioBuffer implementation](https://github.com/webrtc-sdk/webrtc/blob/m137_release/modules/audio_processing/audio_buffer.cc)
uses FloatS16 full-band data and 10 ms blocks. The subsequent capture adapter
normalizes by 32768 and rejects unexpected frame counts and formats. No microphone
or provider call was performed; runtime delivery remains unverified.

### Capture and recording integration — October 11, 2026

Implemented in `mobile/SpokenAgents/Services/Audio/WebRTCAudioCapture.swift`.
The transport retains this observer and its processing module; the app supplies
the same observer as the coordinator's existing `TurnRecording`. Twenty reusable
slots hold up to 480 frames per channel, two channels (76,800 sample-storage bytes).
Atomic producer/consumer indices prevent reuse before consumption. A try-lock
serializes capture with control operations without waiting on the audio callback;
contention, overflow, capture release, or format changes invalidate the active turn.
A coalesced DispatchSource signal schedules a serial worker without allocating a
work item or sample array for each block. The worker performs normalization,
mono downmixing, AVAudioConverter resampling, and incremental protected Int16 WAV
writing. Stop closes admission, drains copied blocks, flushes the converter, and
returns a complete 16 kHz mono WAV to the existing journal. The recorder interface
uses asynchronous start and stop; continuations suspend the caller while the worker
opens or finalizes files. Cancellation closes admission immediately and queues file
cleanup without waiting for the worker. A lifecycle generation rejects late results.
Silence, missing callbacks, nonfinite samples, and size/duration limits fail without
returning a partial file. Cancel and transport close remove unfinished files.

The adapter supports 8, 16, 32, and 48 kHz, one or two channels, and five-minute
turns. It observes microphone post-processing only, but acoustic speaker leakage
may still be present. Physical-device callback delivery, queue pressure, turn
alignment, and hosted Speech interoperability remain pending.

Verification: the native iOS simulator unit suite passed 86 tests, including seven
capture tests for FloatS16 normalization, stereo downmixing, resampling, independent
turns, delayed initialization, silence/missing callbacks, invalid formats, capture
release, cancellation, overflow, and borrowed-buffer copying. The coordinator
journal test also passed using the real capture recorder, verifying a decodable
saved WAV and matching audio/transcript UUIDs. The full native device target built
with signing disabled. Local Markdown links and diff whitespace checks passed.

### Asynchronous file preparation — October 11, 2026

The coordinator displays a finalizing-turn state and shares the in-flight finish
task so repeated Finish actions cannot duplicate recording finalization. Attempt
checks after suspended start, stop, and save prevent late results from reviving
stopped calls. End conversation waits for an in-progress turn finalization.

The live WAV journal path snapshots values on the main actor, then performs file
reading, hashing, and protected file writing in background tasks. SwiftData commits
and a final quota check remain serialized on the main actor. Account/practice
checks after suspension prevent metadata from being committed to a different owner.
Upload preparation likewise reads and verifies bytes off the main actor, then
rechecks the account lease before submitting the authenticated URLSession request.
One upload body remains in memory, bounded by the existing 10 MiB turn limit;
file-backed network upload is not introduced. The capture callback and fixed pool
are unchanged. Physical-device capture and live hosted feedback remain pending.

Optimization verification: 90 simulator unit tests passed, including suspended
coordinator start/stop cancellation, repeated Finish, asynchronous journal
idempotency, and upload hash verification. An additional real-recorder test passed
with its worker deliberately suspended: start/stop/cancel left the main actor
responsive, rejected cancelled results, and allowed a subsequent successful turn.
The native device target built successfully with signing disabled.

The subsequent [audio lifecycle audit](ios-audio-lifecycle.md) records ownership,
generation-safe cleanup, teardown, upload guards, interrupted-save recovery, and
the expanded 121-test suite plus Thread Sanitizer results. The later format tests
also verified exact captured duration at lower input rates and prompted bounding
resampler filter tails to the captured input frame count.

After a dependency choice, integrate one processing observer with
`.platformDefault`. Verify one real microphone turn produces nonzero copied
samples while the existing Azure SDP/data-channel conversation remains usable.
That establishes callback delivery and basic provider interoperability before
implementing the complete WAV/upload adapter. Compile/link success alone does
not establish either condition.

### Missing agent voice audit — October 12, 2026

The connected iPhone diagnostics reproduce successful SDP exchange, ICE, data
channel, and provider response events alongside zero captured frames. These
signals do not establish audible playback or successful microphone acquisition.

The app configured and activated `AVAudioSession` directly even though the pinned
framework's `RTCAudioSession.h` requires setters through its locking proxy.
Activation, category, speaker routing, and balanced deactivation now use
`RTCAudioSession` under its configuration lock. Resetting the preferred input to
nil uses Apple's setter under that same lock because M137's proxy declares a
nonnull argument. Speaker changes also update WebRTC's saved configuration,
including removing default-to-speaker when switching away from the speaker.
These are integration corrections; they do not establish the root cause of the
missing audio or prove the framework binary is defect-free.

Two bounded diagnostics at 3 and 10 seconds after channel opening record route,
output volume, session/device state, and audio RTP packet/byte/sample counters.
Only numeric media metadata and route types are recorded; no voice, SDP,
credentials, or conversation text is logged. Stale connection callbacks are
ignored. The physical connection test now requires an agent audio transcript
and keeps the connection open for both snapshots.

Validation: all 121 simulator unit tests passed with the pinned native package.
Physical playback and capture verification remain pending the live device audit.

### Latest-release upgrade verification — October 12, 2026

GitHub's latest release API returned 150.7871.01. Retrying the direct upstream
package failed during manifest compilation (`visionOS.v26` requires
PackageDescription 6.2, while upstream declares tools 5.9). The local package
wrapper corrects the tools declaration and pins the official binary URL/checksum.
The native project specification and generated project both use this wrapper.
The factory now explicitly selects `.platformDefault`. Simulator and unsigned
generic iPhone builds passed; all 122 unit tests passed, including output PCM
statistics. This does not verify microphone or speaker operation on a device.
