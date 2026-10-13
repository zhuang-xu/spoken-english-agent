# WebRTC microphone verification

Separate development app using the same pinned WebRTC-SDK 150.7871.01 binary
as Spoken Agents. It does not change or replace the production app.

## Demo basis

The M150 [AppRTC demo](https://github.com/webrtc-sdk/webrtc/blob/m150_release/examples/objc/AppRTCMobile/ARDAppClient.m)
creates its standard factory with default video encoder/decoder factories,
creates an audio source with empty constraints, and adds an enabled audio track.
This app follows those audio creation steps. It uses two peers in one process
with locally exchanged SDP instead of the demo's room/signaling service.

Before factory creation, it persists PlayAndRecord/VoiceChat session settings
and default speaker routing to avoid the previously observed invalid inherited
SoloAmbient configuration. WebRTC owns activation and audio-unit startup.
No custom audio device, processing module, input-route override, recorder,
OpenAI client, authentication, or microphone track toggling is involved.
The receiver's audio track is disabled after negotiation to avoid acoustic
loopback. This is a microphone-source test, not a playback acceptance test.

## Run

Tap **Start microphone check**, allow microphone access, and speak for 15 seconds
when **Capture active — speak now** appears. Source energy, level, sample duration,
packet count, track state and route are shown. A nonzero energy value establishes
signal at WebRTC's media source, not recognition of the spoken sentence.
Unavailable fields are explicitly displayed as unavailable.

Numeric snapshots are saved to `Documents/microphone-metrics.json`. No voice
recording is saved or sent to an external service. No ICE servers are configured.

Generate with `xcodegen generate --spec mobile/WebRTCMicCheck/project.yml`, then
build the generated project using its WebRTCMicCheck scheme.

If this setup captures speech while Spoken Agents does not, compare audio setup
and lifecycle differences. If it also receives zeros, that is a reproduction in
a minimal demo-based app; it does not independently establish an SDK bug or
identify whether silence begins at the OS audio-unit output.

## Physical result — October 13, 2026

The user's completed iPhone 16 Pro test at 15:57–15:58 Asia/Shanghai produced
15 snapshots. The microphone track was enabled throughout, ICE was connected,
and the route was MicrophoneBuiltIn with PlayAndRecord/VoiceChat. Source sample
duration increased to 15.7 seconds and outbound packets increased to 794.
Audio level and cumulative source energy stayed exactly zero in every snapshot.
The minimal demo-based setup therefore reproduces the silent media-source
failure without Spoken Agents' recorder, custom processing delegates, or
provider connection. This is not proof of an SDK defect: OS audio-unit output
and the common device/session configuration remain unmeasured boundaries.

Numeric evidence: [microphone-metrics-2026-10-13.json](microphone-metrics-2026-10-13.json).
