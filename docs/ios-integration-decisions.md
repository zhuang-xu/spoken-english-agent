# iOS integration decisions and device matrix

**Recorded:** 2026-09-27. **Status updated:** 2026-10-21. Phase 5 physical-device
acceptance passed with no issues, as confirmed by the user. Earlier failed runs
are historical. See [the device acceptance record](ios-acceptance-testing.md).

## Integration choices

| Area | Decision and current evidence |
|---|---|
| Minimum OS and storage | iOS 26.0; use SwiftData for the Phase 3 local store. Xcode 27.0 built and tested the app on iOS 27.0 simulator. Migration behavior remains unverified. |
| Native media | WebRTC-SDK 150.7871.01 official binary, checksum-pinned by local `mobile/Packages/WebRTC/Package.swift`, product `WebRTC`. On October 12, direct upstream resolution failed because its tools-5.9 manifest uses `visionOS.v26`; the local wrapper declares tools 6.2. The app minimum remains iOS 26. The factory explicitly selects `.platformDefault`, with voice processing enabled and retained capture/render delegates. Physical-device acceptance passed, as confirmed by the user on October 21, 2026. |
| Learner audio | WebRTC owns native microphone capture and playback. `WebRTCAudioCapture.swift` observes processed microphone samples without modifying the input. A bounded reusable pool transfers FloatS16 samples to a serial WAV conversion/writing worker. The shared observer implements `TurnRecording`, connecting manual turns to the existing protected journal and audio feedback flow. No separate microphone recorder is opened. Physical-device acceptance passed, as confirmed by the user on October 21, 2026. |
| Local journal | Pending audio is capped at 200 MiB per account and each turn at 10 MiB. It stays until a complete report is saved or the practice is locally deleted; accepted upload bytes are then removed while pending retries remain. The SwiftData store, audio directory, and temporary turn recording use file protection; persistent files are excluded from backup. Records are partitioned by verified account ID. |
| Configuration | `API_BASE_URL` is nonsecret build configuration. The short-lived Realtime credential stays in memory. No Function key or provider secret belongs in the app. |

## Consolidated physical iPhone pass for Phase 5

Record device model, iOS version, Xcode version, backend deployment, test account,
and result for each case. Repeat affected cases after a fix.

| Case | Pass evidence |
|---|---|
| Microphone permission and opening question | Denial creates no session; grant allows the HTTPS SDP exchange and audible opening prompt. |
| Manual learner turn | Start and finish send the expected data-channel events; committed item ID maps to the intended turn UUID; final learner and agent text match the conversation. |
| Concurrent capture | The saved WAV decodes in the backend, contains the complete learner turn without agent audio, and aligns with the final transcript. Check short and near-limit turns. |
| Output routes | Speaker and wired or Bluetooth output play the agent reply; route changes stop or safely continue according to the foreground policy. |
| Interruption and background | Phone/system interruption and backgrounding stop recording, close media, and preserve an honest session status. Late callbacks cannot restart audio. |
| Network loss and retry | Disconnect ends the known session when possible; exact pending bytes retry after relaunch, and incomplete data cannot request evaluation. |
| Offline history and report | Force quit, enable airplane mode, relaunch, and reopen several practices in order with transcripts and cached coaching. |
| Real evaluation | A hosted conversation produces a complete report; uploaded audio and text are inspected for alignment and missing components. |
