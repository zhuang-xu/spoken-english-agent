import { test } from "node:test";
import assert from "node:assert/strict";
import { RealtimeCall } from "../public/realtime.mjs";

const preferences = { speaking_goal: "Practice work", level: "B1",
  preferred_topic: "projects", session_duration_minutes: 15 };
const sdp = "v=0\r\nmock-sdp";
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
function harness(options = {}) {
  const requests = [], statuses = [], transcripts = [], peers = [];
  const track = { stopped: false, stop() { this.stopped = true; } };
  const stream = { getTracks: () => [track] };
  const audio = { srcObject: null, pause() {}, play: async () => {} };
  class Peer {
    constructor() {
      peers.push(this);
      this.dc = { readyState: "connecting", messages: [],
        send(message) { this.messages.push(JSON.parse(message)); },
        close() { this.readyState = "closed"; this.onclose?.(); } };
    }
    addTrack(value) { this.track = value; }
    createDataChannel(name) { this.channelName = name; return this.dc; }
    async createOffer() { return { type: "offer", sdp }; }
    async setLocalDescription(offer) { this.localDescription = offer; }
    async setRemoteDescription(answer) { this.remoteDescription = answer; }
    close() { this.connectionState = "closed"; this.onconnectionstatechange?.(); }
  }
  const session = { session: { id: "local-id" }, realtime: {
    webrtc_url: "https://test-resource.openai.azure.com/openai/v1/realtime/calls",
    client_credential: { value: "temporary-secret", expires_at: new Date(Date.now() + 60000).toISOString() },
  } };
  const fetchImpl = async (url, init) => {
    requests.push({ url, ...init });
    if (options.fetch) return options.fetch(url, init, session);
    return url === "/sessions"
      ? { ok: true, json: async () => session }
      : { ok: true, text: async () => sdp };
  };
  const call = new RealtimeCall({ audio, fetchImpl, PeerConnection: Peer,
    mediaDevices: { getUserMedia: options.media ?? (async () => stream) },
    onStatus: (...args) => statuses.push(args), onTranscript: text => transcripts.push(text),
    setupTimeoutMs: options.timeout ?? 30000,
    onAudioBlocked: options.onAudioBlocked, onSession: options.onSession, onEvent: options.onEvent, onStop: options.onStop,
    manualTurns: options.manualTurns, Recorder: options.Recorder, onTurnState: options.onTurnState,
    onTurnStart: options.onTurnStart, onTurnAudio: options.onTurnAudio, onTurnCommitted: options.onTurnCommitted });
  return { call, track, stream, audio, peers, requests, statuses, transcripts, session };
}

test("POSTs SDP with only the temporary token, applies answer, plays media and requests opening", async () => {
  const h = harness();
  try {
    await h.call.start(preferences);
    const [session, offer] = h.requests;
    assert.equal(session.url, "/sessions");
    assert.deepEqual(JSON.parse(session.body), preferences);
    assert.equal(session.cache, "no-store");
    assert.equal(offer.url, h.session.realtime.webrtc_url);
    assert.equal(offer.method, "POST");
    assert.deepEqual(offer.headers, { Authorization: "Bearer temporary-secret", "Content-Type": "application/sdp" });
    assert.equal(offer.body, sdp);
    assert.equal(offer.credentials, "omit");
    const pc = h.peers[0];
    assert.equal(pc.channelName, "oai-events");
    assert.equal(pc.track, h.track);
    assert.deepEqual(pc.remoteDescription, { type: "answer", sdp });
    pc.dc.readyState = "open";
    pc.dc.onopen();
    assert.equal(pc.dc.messages[0].type, "session.update");
    assert.equal(pc.dc.messages[0].session.audio.input.transcription.model, "whisper-1");
    assert.deepEqual(pc.dc.messages[1], { type: "response.create" });
    pc.ontrack({ streams: [h.stream] });
    assert.equal(h.audio.srcObject, h.stream);
    pc.dc.onmessage({ data: JSON.stringify({ type: "response.output_audio_transcript.done", transcript: "Hello" }) });
    pc.dc.onmessage({ data: "invalid json" });
    pc.dc.onmessage({ data: "null" });
    assert.deepEqual(h.transcripts, ["Hello"]);
    assert.equal(h.statuses.at(-1)[0], "connected");
    assert.ok(!JSON.stringify(h.statuses).includes("temporary-secret"));
  } finally { h.call.stop(); }
  assert.equal(h.track.stopped, true);
  assert.equal(h.audio.srcObject, null);
  assert.equal(h.peers[0].connectionState, "closed");
});

test("permission denial never creates a provider session", async () => {
  const h = harness({ media: async () => { throw new DOMException("secret", "NotAllowedError"); } });
  await h.call.start(preferences);
  assert.equal(h.requests.length, 0);
  assert.match(h.statuses.at(-1)[1], /permission denied/);
});

test("Disconnect during permission wait releases late microphone and ignores duplicate Start", async () => {
  const pending = deferred();
  const h = harness({ media: () => pending.promise });
  const starting = h.call.start(preferences);
  await h.call.start(preferences);
  h.call.stop();
  pending.resolve(h.stream);
  await starting;
  assert.equal(h.track.stopped, true);
  assert.equal(h.requests.length, 0);
  assert.equal(h.call.attempt, null);
});

for (const status of [401, 415, 422, 502, 503, 504]) {
  test(`backend HTTP ${status} releases microphone and does not expose body`, async () => {
    const h = harness({ fetch: async () => ({ ok: false, status, text: async () => "secret" }) });
    await h.call.start(preferences);
    assert.equal(h.requests.length, 1);
    assert.equal(h.track.stopped, true);
    assert.match(h.statuses.at(-1)[1], new RegExp(`HTTP ${status}`));
    assert.ok(!h.statuses.at(-1)[1].includes("secret"));
  });
}

for (const scenario of ["expired", "missing", "bad-url", "bad-json", "sdp-rejected", "bad-sdp", "network", "invalid-answer"]) {
  test(`cleans up on ${scenario}`, async () => {
    const h = harness({ fetch: async (url, init, session) => {
      if (url === "/sessions") {
        if (scenario === "expired") session.realtime.client_credential.expires_at = "2000-01-01";
        if (scenario === "missing") delete session.realtime.client_credential;
        if (scenario === "bad-url") session.realtime.webrtc_url = "http://example.com";
        return { ok: true, json: async () => {
          if (scenario === "bad-json") throw new SyntaxError("secret");
          return session;
        } };
      }
      if (scenario === "network") throw new TypeError("secret");
      if (scenario === "invalid-answer") h.peers[0].setRemoteDescription = async () => { throw new DOMException("secret"); };
      return { ok: scenario !== "sdp-rejected", status: 401,
        text: async () => scenario === "bad-sdp" ? "secret" : sdp };
    } });
    await h.call.start(preferences);
    assert.equal(h.track.stopped, true);
    assert.equal(h.peers[0].connectionState, "closed");
    assert.equal(h.statuses.at(-1)[0], "error");
    assert.ok(!h.statuses.at(-1)[1].includes("secret"));
  });
}

test("late session response after Disconnect cannot send SDP", async () => {
  const pending = deferred(), reached = deferred();
  const h = harness({ fetch: () => { reached.resolve(); return pending.promise; } });
  const starting = h.call.start(preferences);
  await reached.promise;
  h.call.stop();
  pending.resolve({ ok: true, json: async () => h.session });
  await starting;
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].signal.aborted, true);
});

test("late SDP response after Disconnect cannot apply answer", async () => {
  const pending = deferred(), reached = deferred();
  const h = harness({ fetch: (url, init, session) => {
    if (url === "/sessions") return { ok: true, json: async () => session };
    reached.resolve(); return pending.promise;
  } });
  const starting = h.call.start(preferences);
  await reached.promise;
  h.call.stop();
  pending.resolve({ ok: true, text: async () => sdp });
  await starting;
  assert.equal(h.peers[0].remoteDescription, undefined);
  assert.equal(h.track.stopped, true);
});

test("setup timeout aborts stalled negotiation", async () => {
  const h = harness({ timeout: 5 });
  await h.call.start(preferences);
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.match(h.statuses.at(-1)[1], /timed out/);
  assert.equal(h.track.stopped, true);
  assert.equal(h.requests[1].signal.aborted, true);
});

test("failed transport cleans up; explicit retry obtains a fresh session", async () => {
  const h = harness();
  try {
    await h.call.start(preferences);
    h.peers[0].connectionState = "failed";
    h.peers[0].onconnectionstatechange();
    assert.equal(h.call.attempt, null);
    assert.equal(h.track.stopped, true);
    await h.call.start(preferences);
    assert.equal(h.requests.filter(r => r.url === "/sessions").length, 2);
  } finally { h.call.stop(); }
});

test("provider error events do not expose raw messages", async () => {
  const h = harness();
  await h.call.start(preferences);
  h.peers[0].dc.onmessage({ data: JSON.stringify({ type: "error", error: { message: "secret" } }) });
  assert.equal(h.track.stopped, true);
  assert.ok(!h.statuses.at(-1)[1].includes("secret"));
});


test("backend lifecycle hooks receive the session and events, and stop exactly once", async () => {
  const ids = [], events = [];
  let stops = 0;
  const h = harness({ onSession: id => ids.push(id), onEvent: event => events.push(event),
    onStop: () => { stops++; } });
  await h.call.start(preferences);
  assert.deepEqual(ids, ["local-id"]);
  const event = { type: "input_audio_buffer.speech_started", item_id: "item1", audio_start_ms: 0 };
  h.peers[0].dc.onmessage({ data: JSON.stringify(event) });
  assert.deepEqual(events, [event]);
  h.call.stop();
  h.call.stop();
  h.peers[0].dc.onmessage({ data: JSON.stringify(event) });
  assert.equal(stops, 1);
  assert.equal(events.length, 1);
});


test("manual recording waits for configuration, matches committed item, and drains transcript on disconnect", async () => {
  const turns = [], audio = [], bindings = [], states = [];
  class Recorder {
    start() { this.result = new Promise(done => { this.done = done; }); return this.result; }
    stop() { return this.result; }
  }
  // A controllable recorder emulates the asynchronous final data event.
  let recorder;
  class Recording extends Recorder { constructor() { super(); recorder = this; } }
  const h = harness({ manualTurns: true, Recorder: Recording,
    onTurnStart: start => { turns.push(start); return "turn-id"; },
    onTurnAudio: (...args) => audio.push(args), onTurnCommitted: (...args) => bindings.push(args),
    onTurnState: state => states.push(state) });
  await h.call.start(preferences);
  const dc = h.peers[0].dc;
  const event = data => dc.onmessage({ data: JSON.stringify(data) });
  dc.readyState = "open";
  dc.onopen();
  dc.onmessage({ data: "null" });
  assert.equal(h.track.enabled, false);
  assert.equal(dc.messages[0].session.audio.input.turn_detection, null);
  await h.call.beginTurn();
  assert.equal(turns.length, 0);
  event({ type: "session.updated", session: { audio: { input: { turn_detection: null } } } });
  const starting = h.call.beginTurn();
  assert.equal(dc.messages.at(-1).type, "input_audio_buffer.clear");
  event({ type: "input_audio_buffer.cleared" });
  await starting;
  assert.equal(h.track.enabled, true);
  assert.equal(turns.length, 1);
  const ending = h.call.disconnect();
  assert.equal(h.track.enabled, false);
  assert.equal(audio[0][0], "turn-id");
  assert.equal(dc.messages.some(message => message.type === "input_audio_buffer.commit"), false);
  recorder.done({ blob: new Blob(["audio"], { type: "audio/webm" }) });
  await Promise.resolve();
  assert.equal(dc.messages.at(-2).type, "input_audio_buffer.commit");
  event({ type: "input_audio_buffer.committed", item_id: "provider-item" });
  assert.deepEqual(bindings, [["turn-id", "provider-item"]]);
  event({ type: "conversation.item.input_audio_transcription.completed", item_id: "provider-item", transcript: "Hello there" });
  await ending;
  assert.equal(h.call.attempt, null);
  assert.equal(h.track.stopped, true);
  assert.equal(states.at(-1), "disabled");
});

test("transport failure during recording forwards final audio before session stop", async () => {
  const order = [];
  class Recorder {
    start() { return Promise.resolve({}); }
    stop() { order.push("recorder-stop"); return Promise.resolve({ blob: new Blob(["audio"]) }); }
  }
  const h = harness({ manualTurns: true, Recorder, onTurnStart: () => "turn1",
    onTurnAudio: () => order.push("audio-pending"), onStop: () => order.push("session-end") });
  await h.call.start(preferences);
  const dc = h.peers[0].dc;
  dc.readyState = "open";
  dc.onopen();
  dc.onmessage({ data: JSON.stringify({ type: "session.updated", session: { audio: { input: { turn_detection: null } } } }) });
  const starting = h.call.beginTurn();
  dc.onmessage({ data: JSON.stringify({ type: "input_audio_buffer.cleared" }) });
  await starting;
  h.call.stop();
  assert.deepEqual(order, ["recorder-stop", "audio-pending", "session-end"]);
});


test("blocked autoplay requests an explicit audio control without changing connection state", async () => {
  let blocked = 0;
  const h = harness({ onAudioBlocked: () => blocked++ });
  h.audio.play = async () => { throw new Error("Autoplay blocked"); };
  try {
    await h.call.start(preferences);
    const previous = h.statuses.length;
    h.peers[0].ontrack({ streams: [h.stream] });
    await Promise.resolve();
    assert.equal(blocked, 1);
    assert.equal(h.statuses.length, previous);
    assert.ok(h.call.attempt);
  } finally { h.call.stop(); }
});

test('account switch closes media without finalizing under the new account', async () => {
  let stops = 0;
  const h = harness({ onStop: () => { stops++; } });
  await h.call.start(preferences);
  h.call.stop('Account changed', 'error', { suppressSessionEnd: true });
  assert.equal(stops, 0);
  assert.equal(h.track.stopped, true);
  assert.equal(h.call.attempt, null);
});
