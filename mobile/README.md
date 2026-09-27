# iOS client

Phase 1 is complete at the simulator gate. The checked-in `SpokenAgents.xcodeproj`
has an iPhone SwiftUI app, unit tests, UI tests, a shared scheme, and the pinned
native WebRTC package. Its call coordinator, backend client, SDP exchange,
permission flow, manual-turn event handling, and WAV recorder are exercised with
fakes. The screen is a prototype; the practice and history flow is still planned.

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

## Native WebRTC variant

The checked-in project resolves `stasel/WebRTC` 153.0.0 through Swift Package
Manager. `project.yml` remains a simulator-only fallback if the binary cannot be
downloaded; generating that variant removes the native dependency until the
native specification is regenerated. Concurrent WebRTC microphone input and
learner-only WAV recording remain a final physical-device verification item. No
Function key or provider secret is included. `API_BASE_URL` defaults to local
FastAPI for simulator work and can be set through a nonsecret build configuration.

See the [implementation plan](../docs/ios-app-plan.md) and
[design](../docs/ios-app-design.md) for phase gates and remaining work.
