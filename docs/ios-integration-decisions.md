# iOS integration decisions and device matrix

**Recorded:** 2026-09-27. **Implementation status:** Phase 5 local build and tests
passed on 2026-10-02; physical-device behavior and hosted authentication remain pending.

## Integration choices

| Area | Decision and current evidence |
|---|---|
| Minimum OS and storage | iOS 17.0; use SwiftData for the Phase 3 local store. Xcode 27.0 built and tested the app on iOS 27.0 simulator. Migration behavior remains unverified. |
| Native media | Swift Package Manager pins `stasel/WebRTC` 153.0.0 in `mobile/project-native.yml` and the checked-in project. Its package declares iOS 10 as its library minimum; the app minimum is iOS 17. The downloaded XCFramework is about 97 MiB on disk, with a 12 MiB iOS arm64 framework. The checked-out license is BSD 3-Clause with bundled WebRTC notices. Xcode 27.0 compiled and linked it; live peer compatibility is a device check. |
| Learner audio | WebRTC owns the local audio track. `AVAudioRecorder` writes a separate 16 kHz, mono, 16-bit PCM WAV for each manual turn within the same `AVAudioSession`. The native test decodes a matching one-second WAV fixture. A recording is rejected if it exceeds the backend's 10 MiB per-turn limit; the app automatically ends a turn after five minutes. Concurrent capture and microphone isolation require the device matrix below. |
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
