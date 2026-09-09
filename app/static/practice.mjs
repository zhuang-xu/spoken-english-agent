import { RealtimeCall } from "./realtime.mjs";

const form = document.querySelector("#preferences");
const start = document.querySelector("#start");
const stop = document.querySelector("#stop");
const fields = document.querySelector("#fields");
const transcripts = document.querySelector("#transcripts");
const call = new RealtimeCall({
  audio: document.querySelector("#reply"),
  onStatus(state, message) {
    const busy = state === "connecting" || state === "connected";
    start.disabled = fields.disabled = busy;
    stop.disabled = !busy;
    document.querySelector("#status").textContent = message;
  },
  onTranscript(text) {
    const line = document.createElement("p");
    line.textContent = text;
    transcripts.append(line);
    if (transcripts.children.length > 100) transcripts.firstElementChild.remove();
  },
});

form.addEventListener("submit", event => {
  event.preventDefault();
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
  transcripts.replaceChildren();
  void call.start(preferences);
});
stop.addEventListener("click", () => call.stop());
window.addEventListener("pagehide", () => call.stop());
