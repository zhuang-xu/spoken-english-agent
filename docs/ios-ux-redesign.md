# iOS practice experience

Implementation status: multi-screen SwiftUI experience implemented and built on the iPhone simulator. All 24 UI journeys verified across the regression and focused runs.

## Reference apps

Reviewed the official product presentations for [Speak](https://www.speak.com/),
[ELSA Speak](https://elsaspeak.com/en), and [Loora](https://www.loora.com/).
Speak describes a guided learn–practice–conversation loop. ELSA emphasizes
real-world role-play, personalization, and progress review. Loora emphasizes
focused conversations across everyday, travel, interview, and work situations.
These product patterns inform this app’s scenario entry points and distinct
practice stages. The visual system and navigation below are original design
choices; they do not claim to reproduce these products’ current native screens.

## Navigation and session flow

- **Home tab:** an editorial welcome, a featured Start action, real-life scenario
  cards, and an account-scoped entry into recent practice. Setup fields, live
  recording controls, sign-out, and diagnostics are absent from Home.
- **History tab:** a separate navigation stack with saved conversations, actual
  conversation/report counts, and full coaching details. Signed-out users see a
  sign-in empty state; no account’s saved content is exposed.
- **Account avatar:** a filled avatar represents an account with verified saved
  history; an outlined avatar represents signed-out state. A status dot
  distinguishes online access from offline access, while the avatar has an
  accessible signed-in or signed-out label. The avatar opens an account
  sheet with sign-in/out, restoration, and diagnostics.
- **Start → session sheet:** configure a goal, optional topic, English level,
  and session length. Scenario cards prefill the goal and topic. Cancel closes
  the sheet without a connection or recording. Only Start conversation requests
  microphone permission and connects to the existing backend.
- **Conversation:** a full-screen navigation stack, session context, status,
  speaker-labeled bubbles, and a bottom control surface. A single microphone
  changes to Finish turn while recording. Audio routing and speaking controls
  remain within reach without scrolling the transcript. Closing an active
  session prompts for feedback or ending without feedback; failed/completed sessions can
  close directly. After feedback completes, View saved feedback opens History.

## Visual and accessibility decisions

An evergreen hero, white primary entry action, scenario-colored SF Symbols,
rounded surfaces, clear typography, and a restrained adaptive teal accent give
Home a distinct hierarchy. System surfaces support light and dark appearance.
History displays real stored values, rather than invented streaks or scores.

System typography supports larger text; scenario tiles use adaptive columns,
and the level picker switches to a menu at accessibility text sizes. Speaker
names, status labels, and accessible avatar labels supplement visual state.
Reduced Motion disables transcript scrolling animation. Setup uses interactive
keyboard dismissal, and conversation controls use a safe-area inset.

## Implementation and validation

`ContentView` owns tabs, modal sequencing, account boundaries, and audio/scene
lifecycle. `PracticeHomeView`, `PracticeSetupView`, `ConversationView`,
`AccountView`, and `HistoryView` implement separate screens. Existing backend,
authentication, storage, recording, coaching, and interruption services remain
in use. New source files are registered in the checked-in Xcode project and are
included automatically by the XcodeGen source-directory specifications.

The UI journey suite now follows the avatar, tabs, setup sheet, and conversation
screen. New journeys verify cancellation before connecting, travel preset
values, full-screen conversation isolation, and the signed-out history boundary.
The regression run passed 22 of 23 tests; the remaining assertion mistook a hidden
tab retained in the accessibility tree for a visible tab. After changing that
assertion to check whether Home can be tapped, the Travel test passed. The final
three-test run also passed active-session close/cancel/end and the direct
feedback-to-History journey. These runs cover all 24 distinct UI journeys.

Physical audio routing and Microsoft broker sign-in retain their documented
real-device verification requirements.

## Conversation language

Conversation statuses describe the learner’s experience: Ready to talk,
Listening to you, Preparing your reply, and Conversation complete. End conversation
opens a choice between Finish & get feedback and End without feedback. Retry and
failure messages use everyday language; connection stages and error codes remain
in diagnostics. Internal coordinator phase names and automation identifiers stay
stable.

## October 10 device feedback fixes

Removed the ambiguous checkmark control. End conversation opens a bottom sheet
with Finish & get feedback, End without feedback, and Cancel; closing an active
conversation opens the same sheet. WebRTC's own audio configuration now retains
default loudspeaker routing when its audio unit starts. Physical playback
audibility still requires a listening check on the iPhone.

## October 10 microphone and playback correction

The native client now uses one voice-processing AVAudioEngine, injected into
WebRTC as its audio device. The turn writer receives a copy of that same
microphone stream and converts it to 16 kHz mono WAV on a serial queue.
Starting and finishing a turn no longer open a second AVAudioRecorder alongside
WebRTC. The output engine remains running across turns. Automated verification:
26 audio and call tests passed, including preservation of a non-silent 48 kHz
input signal through WAV conversion and cancellation cleanup. Actual spoken
transcription and playback quality require a device listening check.

Physical iPhone 16 Pro (iOS 27.0.1): the shared engine initialized at 48 kHz
with Speaker output. The first connection reached an ICE/data-channel timeout;
a repeat Connect/Disconnect test passed at 15:14 Asia/Shanghai. The corrected
build remains installed and was relaunched. This checks live connection and
engine startup, not spoken transcription accuracy or playback audibility.

## October 10 upload rejection handling

Device logs showed four earlier learner WAV uploads repeatedly receiving HTTP
422. The upload journal now distinguishes permanently rejected audio from
transient pending work. A rejected recording is kept locally, is not retried
again, and blocks feedback requests with a clear instruction to start a new
practice. History displays rejected recordings separately from pending uploads.
Existing pending entries become rejected on their next server retry. HTTP 503
remains retryable. Regression tests verify rejection persistence after relaunch,
no repeated rejected audio upload or feedback request, and recovery from 503.

## Server recording inspection — October 10

With explicit approval, a read-only copy of the hosted database was inspected.
All eight learner WAV uploads stored on October 10 through 15:05 Asia/Shanghai
were 4,096-byte header-only files: 16 kHz mono, zero frames, and a zero-length
data chunk. This includes the four recordings uploaded at 15:05:34–15:05:42
shown as pending in History. The server persists uploads before decoding them
for assessment; decode_audio then returns HTTP 422, “Learner recording contains
no audio samples.” These contain no recoverable speech. No uploads from the
new shared-engine build were present in this database snapshot, so its actual
spoken-upload behavior remains unverified. The downloaded copy was removed
after inspection.
