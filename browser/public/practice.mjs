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
  const line = document.createElement("p");
  line.textContent = `${speaker}: ${text}`;
  transcripts.append(line);
  if (transcripts.children.length > 100) transcripts.firstElementChild.remove();
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
  evaluate.disabled = !session.ready;
  if (session.ready && feedbackRequested) await requestFeedback();
}

const form = document.querySelector("#preferences");
const start = document.querySelector("#start");
const stop = document.querySelector("#stop");
const fields = document.querySelector("#fields");
const transcripts = document.querySelector("#transcripts");
const call = new RealtimeCall({
  audio: document.querySelector("#reply"),
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
  for (const field of ["speaking_goal", "level", "preferred_topic"]) {
    preferences[field] = preferences[field].trim();
    if (preferences[field].length < 2) {
      document.querySelector("#status").textContent = "Please enter at least two characters in each text field.";
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
  evaluate.disabled = true;
  transcripts.replaceChildren();
  void call.start(preferences);
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
    add("h3", "Overall feedback");
    add("p", result.summary);
    for (const name of ["grammar", "vocabulary", "coherence"]) {
      add("h3", `${name[0].toUpperCase() + name.slice(1)}: ${result[name].score ?? "Not assessed"}${result[name].score == null ? "" : "/5"}`);
      add("p", result[name].feedback);
    }
    for (const [title, items] of [["Strengths", result.strengths], ["Top priorities", result.next_steps]]) {
      add("h3", title);
      for (const item of items) add("p", item);
    }
    if (result.corrections.length) add("h3", "Corrections");
    for (const correction of result.corrections) {
      add("p", `${correction.original} → ${correction.improved}: ${correction.explanation}`);
    }
    saveStatus.textContent = "Feedback ready.";
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
