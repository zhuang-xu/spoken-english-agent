import { RealtimeCall } from "./realtime.mjs";
import { BackendError, SessionSync, loadEvaluation } from "./session.mjs";
import { AccountBoundary, AccountError } from "./account.mjs";

const legacyFeedbackKey = "speakwell:last-completed-feedback";
const feedbackKey = accountId => `${legacyFeedbackKey}:${accountId}`;
let verifiedAccountId = null;
function savedFeedback() {
  if (!verifiedAccountId || account.state !== "ready") return null;
  try {
    const saved = JSON.parse(localStorage.getItem(feedbackKey(verifiedAccountId)));
    return saved && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(saved.id) &&
      typeof saved.goal === "string" ? saved : null;
  } catch { return null; }
}
function rememberFeedback(id, goal) {
  if (!verifiedAccountId || account.state !== "ready") return;
  try { localStorage.setItem(feedbackKey(verifiedAccountId), JSON.stringify({ id, goal })); }
  catch { /* Storage may be disabled; the current report is still available. */ }
}
function forgetFeedback() {
  if (!verifiedAccountId || account.state !== "ready") return;
  try { localStorage.removeItem(feedbackKey(verifiedAccountId)); }
  catch { /* Nothing else on the page depends on browser storage. */ }
}

const speak = document.querySelector("#speak");
const turnStatus = document.querySelector("#turn-status");
let turnState = "disabled";

let session, sessionAccountId = null, finalizing = false, evaluating = false;
let starting = false, feedbackRequested = false, activeGoal = "";
const saveStatus = document.querySelector("#save-status");
const saveNote = document.querySelector("#save-note");
const evaluate = document.querySelector("#evaluate");
const feedback = document.querySelector("#feedback");
const restoreButton = document.querySelector("#restore-feedback");
const forgetButton = document.querySelector("#forget-feedback");
const retrySave = document.querySelector("#retry-save");
const retryAccount = document.querySelector("#retry-account");
const signIn = document.querySelector("#sign-in");
const accountStatus = document.querySelector("#account-status");
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
  const current = session;
  finalizing = true;
  start.disabled = fields.disabled = evaluate.disabled = true;
  saveNote.hidden = true;
  saveNote.textContent = "";
  saveStatus.textContent = "Saving session…";
  await current.finish(options);
  finalizing = false;
  if (session !== current || account.state === "changed") return;
  start.disabled = fields.disabled = account.state !== "ready";
  evaluate.hidden = false;
  evaluate.disabled = !current.ready || account.state !== "ready";
  retrySave.hidden = current.ready || account.state !== "ready";
  if (current.ready && feedbackRequested && account.state === "ready") await requestFeedback();
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
function clearAccountView() {
  session?.cancel();
  session = null;
  sessionAccountId = null;
  activeGoal = "";
  feedbackRequested = false;
  call.stop("The signed-in account changed.", "error", { suppressSessionEnd: true });
  transcripts.replaceChildren();
  feedback.replaceChildren();
  feedbackSection.hidden = conversation.hidden = true;
  restoreButton.hidden = forgetButton.hidden = retrySave.hidden = true;
  saveNote.hidden = true;
  saveStatus.textContent = "";
  document.querySelector("#setup-summary").textContent = "Set up your practice";
}
function accountStateChanged(state) {
  const ready = state === "ready";
  start.disabled = fields.disabled = !ready || finalizing || evaluating || starting || !!call.attempt;
  evaluate.disabled = !ready || !session?.ready;
  retryAccount.hidden = ready;
  signIn.hidden = state !== "required";
  accountStatus.textContent = {
    loading: "Checking your account…",
    ready: "Account verified.",
    required: "Your sign-in expired. Sign in again, then check your account.",
    forbidden: "This account does not have access to practice.",
    unavailable: "Could not verify your account. Check your connection and try again.",
    changed: "The signed-in account changed. Reload this page to continue.",
  }[state];
  retryAccount.textContent = state === "changed" ? "Reload page" : "Check account";
  if (!ready) {
    feedbackSection.hidden = true;
    conversation.hidden = true;
    restoreButton.hidden = forgetButton.hidden = retrySave.hidden = true;
  }
  if (state === "changed") {
    clearAccountView();
  } else if (!ready && call.attempt) {
    call.stop(accountStatus.textContent, "error");
  }
}
const account = new AccountBoundary({ fetchImpl: (...args) => fetch(...args), onState: accountStateChanged });
async function checkAccount() {
  const previous = verifiedAccountId;
  try {
    verifiedAccountId = await account.check({ recover: true });
    try { localStorage.removeItem(legacyFeedbackKey); } catch { /* Optional browser storage. */ }
    if (!session) {
      if (feedbackSection.hidden) await restoreFeedback();
    } else if (session.ended && !session.ready && !finalizing) await finish();
    else if (previous && session.ready && feedbackRequested) await requestFeedback();
  } catch { /* The account state is displayed by AccountBoundary. */ }
}
retryAccount.addEventListener("click", () => {
  if (account.state === "changed") window.location.reload();
  else void checkAccount();
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && account.accountId) void checkAccount();
});
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
  fetchImpl: async (url, init) => {
    if (!sessionAccountId) throw new AccountError("changed");
    if (url === "/sessions") return account.fetchFor(sessionAccountId, url, init);
    await account.require(sessionAccountId);
    return fetch(url, init);
  },
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
    start.disabled = fields.disabled = busy || finalizing || evaluating || account.state !== "ready";
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
    const ownerId = sessionAccountId;
    const current = session = new SessionSync(id, {
      fetchImpl: (url, init) => account.fetchFor(ownerId, url, init),
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

form.addEventListener("submit", async event => {
  event.preventDefault();
  if (finalizing || evaluating || starting || call.attempt || account.state !== "ready") return;
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
  starting = true;
  start.disabled = fields.disabled = true;
  try { await account.require(verifiedAccountId); }
  catch { starting = false; return; }
  starting = false;
  if (account.state !== "ready") return;
  sessionAccountId = verifiedAccountId;
  session?.cancel();
  session = null;
  feedbackRequested = false;
  activeGoal = preferences.speaking_goal;
  saveStatus.textContent = "";
  saveNote.hidden = true;
  saveNote.textContent = "";
  feedback.replaceChildren();
  feedbackSection.hidden = true;
  restoreButton.hidden = true;
  setup.open = false;
  conversation.hidden = false;
  document.querySelector("#setup-summary").textContent = `${preferences.speaking_goal} · ${preferences.level} · ${preferences.session_duration_minutes} min`;
  conversation.open = true;
  document.querySelector("#transcript-heading").textContent = "Conversation transcripts";
  latest.hidden = true;
  enableAudio.hidden = true;
  evaluate.hidden = true;
  evaluate.disabled = true;
  retrySave.hidden = true;
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
  const ownerId = sessionAccountId;
  if (!current?.ready || evaluating || account.state !== "ready" || ownerId !== verifiedAccountId) return;
  evaluating = true;
  evaluate.disabled = start.disabled = true;
  saveStatus.textContent = "Preparing feedback…";
  try {
    const evaluation = await current.evaluate();
    if (session !== current || account.state !== "ready" || ownerId !== account.accountId) return;
    if (evaluation.status !== "completed" || !evaluation.result) {
      saveStatus.textContent = "Feedback is not complete. Request feedback again to check or retry.";
      return;
    }
    renderFeedback(evaluation, activeGoal);
    rememberFeedback(current.id, activeGoal);
    saveStatus.textContent = "Feedback ready.";
  } catch (error) {
    if (session === current && account.state !== "changed") saveStatus.textContent = error.message;
  }
  finally {
    evaluating = false;
    evaluate.disabled = !current.ready || account.state !== "ready";
    start.disabled = account.state !== "ready";
  }
}
function renderFeedback(evaluation, goal, restored = false) {
  forgetButton.hidden = false;
  feedback.replaceChildren();
  const add = (tag, text) => {
    const node = document.createElement(tag);
    node.textContent = text;
    feedback.append(node);
  };
  const result = evaluation.result;
  if (goal) add("h3", `Progress toward: ${goal}`);
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
  feedbackSection.hidden = false;
  conversation.hidden = restored;
  conversation.open = false;
  if (!restored) document.querySelector("#transcript-heading").textContent = "Review conversation";
  document.querySelector("#feedback-heading").focus({ preventScroll: true });
  feedbackSection.scrollIntoView({ block: "start", behavior: "smooth" });
}
evaluate.addEventListener("click", () => void requestFeedback());
retrySave.addEventListener("click", () => void finish());
async function restoreFeedback() {
  const saved = savedFeedback();
  const ownerId = verifiedAccountId;
  if (!saved || session || account.state !== "ready") return;
  restoreButton.hidden = true;
  saveStatus.textContent = "Loading your saved feedback…";
  try {
    const evaluation = await loadEvaluation(saved.id, (url, init) => account.fetchFor(ownerId, url, init));
    if (session || call.attempt || account.state !== "ready" || ownerId !== account.accountId) return;
    if (evaluation.status !== "completed" || !evaluation.result) {
      restoreButton.hidden = false;
      saveStatus.textContent = "Your saved feedback is still being prepared. Try View saved feedback again.";
      return;
    }
    renderFeedback(evaluation, saved.goal, true);
    saveStatus.textContent = "Saved feedback loaded.";
  } catch (error) {
    if (session || call.attempt || account.state !== "ready" || ownerId !== account.accountId) return;
    if (error instanceof BackendError && error.status === 404) {
      forgetFeedback();
      saveStatus.textContent = "Your previous feedback is no longer available on the server.";
    } else {
      restoreButton.hidden = false;
      saveStatus.textContent = `${error.message} Use View saved feedback to retry.`;
    }
  }
}
restoreButton.addEventListener("click", () => void restoreFeedback());
forgetButton.addEventListener("click", () => {
  forgetFeedback();
  forgetButton.hidden = true;
  saveStatus.textContent = "This report will not reopen on this device.";
});
start.disabled = fields.disabled = true;
void checkAccount();
window.addEventListener("pagehide", () => {
  // Best effort only: browsers may terminate remaining uploads on page exit.
  call.stop(undefined, undefined, { keepalive: true });
});
