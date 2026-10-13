# Native microphone comparison

Standalone SwiftUI iPhone application with no WebRTC or LiveKit dependency.
Uses AVAudioEngine's input tap with AVAudioSession record/measurement, without
voice processing, playback, custom routing, network traffic, or audio storage.

Tap Start, grant microphone access, and speak for 15 seconds. Numeric counters
are displayed and saved in `Documents/native-microphone-metrics.json`: callback,
frame and sample counts, nonzero count, energy, RMS, peak, sample format, route,
engine state and setup errors. Unsupported buffers and absent callbacks are
reported separately from all-zero samples. Counters skip publication if a
snapshot briefly holds their try-lock, so they are not an exact sample audit.

A nonzero signal here verifies native capture under this measurement configuration,
not WebRTC's VoiceProcessingIO configuration. A zero result reproduces silence
without either SDK, but still does not prove a hardware defect. A controlled
VoiceChat/VoiceProcessingIO comparison or direct AudioUnitRender measurement
would be needed to locate the failure in WebRTC's exact OS input path.

This app does not replace Spoken Agents or change its implementation.

## Physical result — October 13, 2026

The completed iPhone run at 16:32 Asia/Shanghai received 157 native input tap
callbacks with 753,600 Float32 mono samples at 48 kHz (15.7 seconds of samples).
All values were zero; unsupported buffer count was zero. The engine was running,
the route was MicrophoneBuiltIn, and the session was Record/Measurement with
one input channel. Silence therefore also occurs in a native configuration
without WebRTC, LiveKit or voice processing. This does not locate a hardware,
OS-policy, or buffer-observation cause.

[Saved numeric evidence](../../docs/diagnostics/native-microphone-metrics-2026-10-13.json).
