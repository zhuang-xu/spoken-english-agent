import { RealtimeCall } from "./realtime.mjs";
import { SessionSync } from "./session.mjs";

const speak = document.querySelector("#speak");
const turnStatus = document.querySelector("#turn-status");
let turnState = "disabled";

let session, finalizing = false, evaluating = false, feedbackRequested = false;
const saveStatus = document.querySelector("#save-status");
const saveNote = document.querySelector("#save-note");
const evaluate = document.querySelector("#evaluate");
const feedback = document.querySelector("#feedback");
function appendTranscript(text, speaker = "Partner") {
  const following = transcripts.scrollHeight - transcripts.scrollTop - transcripts.clientHeight < 48;
  const line = document.createElement("p");
  if (speaker !== "Partner") line.className = "learner";
  line.textContent = `${speaker}: ${text}`;
  transcripts.append(line);
  if (following) transcripts.scrollTop = transcripts.scrollHeight;
  latest.hidden = following;
}
async function finish(options) {
  if (!session || finalizing) return;
  finalizing = true;
  start.disabled = fields.disabled = evaluate.disabled = true;
  saveNote.hidden = true;
  saveNote.textContent = "";
  saveStatus.textContent = "Saving session…";
  await session.finish(options);
  finalizing = false;
  start.disabled = fields.disabled = false;
  evaluate.hidden = false;
  evaluate.disabled = !session.ready;
  if (session.ready && feedbackRequested) await requestFeedback();
}

const form = document.querySelector("#preferences");
const start = document.querySelector("#start");
const stop = document.querySelector("#stop");
const fields = document.querySelector("#fields");
const transcripts = document.querySelector("#transcripts");
const latest = document.querySelector("#latest");
const setup = document.querySelector("#setup");
const conversation = document.querySelector("#conversation");
const feedbackSection = document.querySelector("#feedback-section");
const audio = document.querySelector("#reply");
const sound = document.querySelector("#sound");
const enableAudio = document.querySelector("#enable-audio");
const contextChoices = document.querySelectorAll('input[name="context_choice"]');
const customContext = document.querySelector(".custom-context");
const topicInput = document.querySelector('input[name="preferred_topic"]');
function syncContextChoice() {
  const custom = document.querySelector('input[name="context_choice"]:checked')?.value === "custom";
  customContext.hidden = !custom;
  topicInput.disabled = !custom;
  if (custom) topicInput.focus();
}
contextChoices.forEach(choice => choice.addEventListener("change", syncContextChoice));
syncContextChoice();
latest.addEventListener("click", () => { transcripts.scrollTop = transcripts.scrollHeight; latest.hidden = true; });
transcripts.addEventListener("scroll", () => {
  if (transcripts.scrollHeight - transcripts.scrollTop - transcripts.clientHeight < 48) latest.hidden = true;
});
sound.addEventListener("click", () => {
  audio.muted = !audio.muted;
  sound.textContent = audio.muted ? "Agent sound off" : "Agent sound on";
  sound.setAttribute("aria-pressed", String(audio.muted));
});
enableAudio.addEventListener("click", async () => {
  try { await audio.play(); enableAudio.hidden = true; }
  catch { document.querySelector("#status").textContent = "Audio could not start. Try Enable agent audio again."; }
});
audio.addEventListener("playing", () => { enableAudio.hidden = true; });
const controls = document.querySelector("#controls");
new ResizeObserver(() => {
  document.body.style.setProperty("--controls-height", `${controls.getBoundingClientRect().height + 24}px`);
}).observe(controls);
const call = new RealtimeCall({
  audio,
  onAudioBlocked() { enableAudio.hidden = false; },
  manualTurns: true,
  onTurnState(state) {
    turnState = state;
    speak.disabled = !["ready", "recording"].includes(state);
    speak.textContent = state === "recording" ? "Finish turn" : "Start speaking";
    speak.setAttribute("aria-pressed", String(state === "recording"));
    turnStatus.textContent = { ready: "Ready to record your next answer.",
      recording: "Recording your microphone. Finish the turn when you are done (maximum two minutes).",
      waiting: "Preparing or finishing your turn…", disabled: "" }[state];
  },
  onTurnStart(start) { return session.beginRecording(start); },
  onTurnAudio(id, result, end) { session?.captureRecording(id, result, end); },
  onTurnCommitted(id, item) { session?.bindRecording(id, item); },
  onStatus(state, message) {
    const busy = state === "connecting" || state === "connected";
    start.disabled = fields.disabled = busy || finalizing || evaluating;
    stop.disabled = !busy;
    start.hidden = busy;
    document.body.classList.toggle("practicing", busy);
    sound.disabled = !busy;
    if (!busy) enableAudio.hidden = true;
    if (state === "error" && !session) setup.open = true;
    document.querySelector("#status").textContent = message;
  },
  onTranscript: appendTranscript,
  onSession(id) {
    const current = session = new SessionSync(id, {
      onChange(message) { if (session === current) saveStatus.textContent = message; },
      onSaveFailed(message) {
        if (session === current) {
          saveNote.textContent = message;
          saveNote.hidden = false;
        }
      },
      onTranscript: appendTranscript,
    });
  },
  onEvent(event) { session?.handle(event); },
  onStop(options) { void finish(options); },
});

form.addEventListener("submit", event => {
  event.preventDefault();
  if (finalizing || evaluating || call.attempt) return;
  const data = new FormData(form);
  const preferences = Object.fromEntries(data);
  delete preferences.context_choice;
  if (!preferences.preferred_topic?.trim()) preferences.preferred_topic = "";
  for (const field of ["speaking_goal", "level"]) {
    preferences[field] = preferences[field].trim();
    if (preferences[field].length < 2) {
      document.querySelector("#status").textContent = "Please choose a speaking goal and English level.";
      return;
    }
  }
  preferences.session_duration_minutes = Number(preferences.session_duration_minutes);
  if (!Number.isInteger(preferences.session_duration_minutes) || preferences.session_duration_minutes < 1 || preferences.session_duration_minutes > 120) return;
  session = null;
  feedbackRequested = false;
  saveStatus.textContent = "";
  saveNote.hidden = true;
  saveNote.textContent = "";
  feedback.replaceChildren();
  feedbackSection.hidden = true;
  setup.open = false;
  document.querySelector("#setup-summary").textContent = `${preferences.speaking_goal} · ${preferences.level} · ${preferences.session_duration_minutes} min`;
  conversation.open = true;
  document.querySelector("#transcript-heading").textContent = "Conversation transcripts";
  latest.hidden = true;
  enableAudio.hidden = true;
  evaluate.hidden = true;
  evaluate.disabled = true;
  transcripts.replaceChildren();
  void call.start(preferences);
  conversation.scrollIntoView({ block: "start" });
});
speak.addEventListener("click", () => {
  if (turnState === "recording") call.finishTurn();
  else if (turnState === "ready") void call.beginTurn();
});
stop.addEventListener("click", () => {
  feedbackRequested = true;
  speak.disabled = stop.disabled = true;
  saveStatus.textContent = "Ending conversation and saving your answers…";
  void call.disconnect();
});
async function requestFeedback() {
  const current = session;
  if (!current?.ready || evaluating) return;
  evaluating = true;
  evaluate.disabled = start.disabled = true;
  saveStatus.textContent = "Preparing feedback…";
  try {
    const evaluation = await current.evaluate();
    feedback.replaceChildren();
    const add = (tag, text) => {
      const node = document.createElement(tag);
      node.textContent = text;
      feedback.append(node);
    };
    if (evaluation.status !== "completed" || !evaluation.result) {
      saveStatus.textContent = "Feedback is not complete. Request feedback again to check or retry.";
      return;
    }
    const result = evaluation.result;
    const outcome = new FormData(form).get("speaking_goal");
    add("h3", `Progress toward: ${outcome}`);
    add("p", result.summary);
    add("h3", "Evidence from your conversation");
    for (const item of result.strengths) add("p", item);
    add("h3", "General language feedback");
    for (const name of ["grammar", "vocabulary", "coherence"]) {
      add("h4", `${name[0].toUpperCase() + name.slice(1)}: ${result[name].score ?? "Not assessed"}${result[name].score == null ? "" : "/5"}`);
      add("p", result[name].feedback);
    }
    const assessed = evaluation.speech_assessments?.flatMap(item => item.status === "assessed" ? item.segments : []) ?? [];
    if (assessed.length) {
      const average = key => Math.round(assessed.reduce((sum, item) => sum + (item[key] ?? 0), 0) / assessed.filter(item => item[key] != null).length);
      add("h4", `Pronunciation clarity: ${average("accuracy_score")}/100`);
      add("p", "Based on the pronunciation accuracy measured in your recorded answers.");
      add("h4", `Spoken fluency: ${average("fluency_score")}/100`);
      add("p", "Based on pacing and continuity measured in your recorded answers.");
    }
    add("h3", "One focused next step");
    add("p", result.next_steps.join(" "));
    if (result.corrections.length) add("h3", "Corrections");
    for (const correction of result.corrections) {
      add("p", `${correction.original} → ${correction.improved}: ${correction.explanation}`);
    }
    saveStatus.textContent = "Feedback ready.";
    feedbackSection.hidden = false;
    conversation.open = false;
    document.querySelector("#transcript-heading").textContent = "Review conversation";
    document.querySelector("#feedback-heading").focus({ preventScroll: true });
    feedbackSection.scrollIntoView({ block: "start", behavior: "smooth" });
  } catch (error) { saveStatus.textContent = error.message; }
  finally {
    evaluating = false;
    evaluate.disabled = !current.ready;
    start.disabled = false;
  }
}
evaluate.addEventListener("click", () => void requestFeedback());
window.addEventListener("pagehide", () => {
  // Best effort only: browsers may terminate remaining uploads on page exit.
  call.stop(undefined, undefined, { keepalive: true });
});
