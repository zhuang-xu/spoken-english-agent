# LiveKit official demo microphone comparison

Fetched [livekit-examples/swift-example](https://github.com/livekit-examples/swift-example)
at commit `e294b27290153d5c763f08cf53e99d79e4d968e7` into
`/tmp/spoken-livekit-swift-example`. The build pins LiveKit Swift 2.17.0 and
LiveKitWebRTC 150.7871.02; Spoken Agents uses WebRTC-SDK 150.7871.01.
This comparison changes both integration and binary, so success would not
independently identify which difference resolves silence.

The official SwiftSDK.1 scheme built successfully for the physical iPhone.
Temporary checkout modifications:

- Separate bundle identifiers and development-team signing.
- Removed Multipath and published App Group entitlements unsupported by this
  development team. Screen sharing is not part of the microphone test.
- Prefilled local server address and a two-hour development room token.
- Added local-network permission and a local-network ATS exception.
- Added a read-only LiveKit AudioRenderer observer: counts samples and nonzero
  samples, peak, energy, format, and unsupported buffers. It never modifies or
  retains borrowed audio. Numeric snapshots are saved every two seconds from
  a separate task to `Documents/livekit-microphone-metrics.json`.

The observer uses a try-lock to publish cumulative numeric counters and skips
publication on contention; counters are not an exact audit of every sample.
No raw voice recording is saved. Demo microphone and audio-session control
remain LiveKit's own implementation. Spoken Agents is unchanged by this test.

A Homebrew-installed LiveKit 1.13.9 server runs in development mode on this Mac
with a local-network bind. Its log is `/tmp/spoken-livekit-server.log`.
No external LiveKit Cloud service is used. The user explicitly requested the
local server. Stop the server when the physical comparison is complete.

Physical microphone results are pending. The user should allow local-network
and microphone permissions, connect, enable the microphone, speak for 15
seconds, and disconnect. Retrieve only the numeric metrics for verification.

First physical run at 16:16–16:17 Asia/Shanghai connected to the server for
approximately 24 seconds and disconnected normally. The observer recorded zero
callbacks and zero samples, and the server log contained no published microphone
track. This is inconclusive for capture: a microphone capture/publication has
not been established. Confirm whether microphone unmute was attempted and expose
startup errors before interpreting this as silence or an SDK defect.
Evidence: [numeric metrics](livekit-microphone-metrics-2026-10-13.json).

The user confirmed tapping microphone unmute without a visible error. Inspection
found the demo discards microphone startup exceptions with `try?`. A diagnostic
update replaces that with do/catch, displays a microphone startup error alert,
and saves the error to `Documents/microphone-startup-error.json`. The capture
configuration remains unchanged. The local server was stopped after the first
run and restarted for the error-visible repeat, logging to
`/tmp/spoken-livekit-server-retry.log`. Results remain pending.

The second physical run at 16:20 Asia/Shanghai successfully published an audio
track with source MICROPHONE, confirmed by the local server. No startup-error
record was created. The local AudioRenderer received 2,486 callbacks containing
1,193,280 signed 16-bit samples at 48 kHz (24.86 seconds for mono). Every sample
was zero; peak, RMS and energy were zero, with no unsupported buffers. This
reproduces silence in LiveKit's own capture path and different WebRTC binary.
It does not establish whether the OS supplies silence or processing introduces
it. Numeric evidence: [retry metrics](livekit-microphone-retry-2026-10-13.json).
The temporary local server was stopped after collecting this result.

A fresh-process repeat at 16:24 Asia/Shanghai again published a microphone
track successfully. It recorded 5,124 callbacks and 2,459,520 Int16 samples at
48 kHz; nonzero count, energy, peak and RMS were all zero. No unsupported
buffers or startup-error record occurred. This repeats the Swift-observed
silence; native buffer contents before callback delivery remain unverified.
[Repeat metrics](livekit-microphone-repeat-2026-10-13.json).
The temporary server was stopped after result collection.
