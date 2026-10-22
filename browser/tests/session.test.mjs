import { test } from "node:test";
import assert from "node:assert/strict";
import { BackendError, SessionSync } from "../public/session.mjs";

function harness() {
  const requests = [], messages = [], notes = [], transcripts = [], failures = new Map();
  let fail = false, count = 0;
  const session = new SessionSync("session-id", {
    uuid: () => `turn-${++count}`, onChange: message => messages.push(message),
    onSaveFailed: message => notes.push(message), onTranscript: (...args) => transcripts.push(args),
    saveRetryDelays: [0, 0, 0], wait: async () => {},
    fetchImpl: async (url, init) => {
      requests.push({ url, ...init });
      const entry = [...failures].find(([part, remaining]) => url.includes(part) && remaining > 0);
      if (entry) failures.set(entry[0], entry[1] - 1);
      return { ok: !fail && !entry, status: 503, json: async () => ({ ready_for_evaluation: true, status: "completed" }) };
    },
  });
  return { session, requests, messages, notes, transcripts, fail: value => { fail = value; },
    failPath: (part, count) => failures.set(part, count) };
}
const emit = (session, type, fields = {}) => session.handle({ type, item_id: "item_1", ...fields });

test("feedback failure says the saved session can be retried", () => {
  assert.equal(new BackendError(502, "/evaluation").message,
    "The feedback service could not complete the report. Your session is saved; try Get feedback again.");
  assert.match(new BackendError(502, "/end").message, /Backend request failed/);
});

test("out-of-order learner events use one turn ID and immutable upload; manifest follows uploads and end", async () => {
  const h = harness();
  emit(h.session, "conversation.item.input_audio_transcription.completed", { transcript: " Hello " });
  emit(h.session, "input_audio_buffer.speech_stopped", { audio_end_ms: 400 });
  assert.equal(h.requests.length, 0);
  emit(h.session, "input_audio_buffer.speech_started", { audio_start_ms: 10 });
  emit(h.session, "conversation.item.input_audio_transcription.completed", { transcript: "Hello" });
  await h.session.finish();
  assert.deepEqual(JSON.parse(h.requests[0].body), { text: "Hello", start_ms: 10, end_ms: 400, provider_item_id: "item_1" });
  assert.equal(h.requests.filter(r => r.url.endsWith("/transcript")).length, 1);
  assert.deepEqual(JSON.parse(h.requests.at(-1).body), {
    audio_turn_ids: [], transcript_turn_ids: ["turn-1"], agent_transcripts: [],
  });
  assert.equal(h.requests[1].url, "/sessions/session-id/end");
  assert.deepEqual(h.transcripts, [["Hello", "You"]]);
  assert.equal((await h.session.evaluate()).status, "completed");
});

test("agent content identities deduplicate and do not claim audible playback", async () => {
  const h = harness();
  const event = { transcript: "Hi", response_id: "response_1", content_index: 0 };
  emit(h.session, "response.output_audio_transcript.done", event);
  emit(h.session, "response.output_audio_transcript.done", event);
  await h.session.finish();
  assert.equal(h.requests.filter(r => r.url.includes("agent-items")).length, 1);
  assert.deepEqual(JSON.parse(h.requests[0].body), { text: "Hi", response_id: "response_1", playback_status: "unknown" });
  assert.deepEqual(JSON.parse(h.requests.at(-1).body).agent_transcripts, [{ item_id: "item_1", content_index: 0 }]);
});

test("failed uploads retry automatically with an identical payload", async () => {
  const h = harness();
  h.failPath("agent-items", 2);
  emit(h.session, "response.output_audio_transcript.done", { transcript: "Hi", response_id: "r1", content_index: 0 });
  await h.session.uploads.values().next().value.pending;
  await h.session.finish();
  const uploads = h.requests.filter(r => r.url.includes("agent-items"));
  assert.equal(uploads.length, 3);
  assert.ok(uploads.every(upload => upload.body === uploads[0].body));
  assert.match(h.messages.join("\n"), /automatic retry 2 of 3/);
  assert.deepEqual(h.notes, []);
  assert.equal(h.session.ready, true);
});

test("persistent save failure stops after three automatic attempts and emits a note", async () => {
  const h = harness();
  h.failPath("agent-items", 99);
  emit(h.session, "response.output_audio_transcript.done", { transcript: "Hi", response_id: "r1", content_index: 0 });
  await h.session.uploads.values().next().value.pending;
  await h.session.finish();
  const uploads = h.requests.filter(r => r.url.includes("agent-items"));
  assert.equal(uploads.length, 4);
  assert.ok(uploads.every(upload => upload.body === uploads[0].body));
  assert.equal(h.session.ready, false);
  assert.equal(h.notes.length, 1);
  assert.match(h.notes[0], /after 3 automatic attempts/);
  await assert.rejects(h.session.evaluate(), /complete session/);
});

test("unfinished learner speech stays in the final inventory and no late events mutate it", async () => {
  const h = harness();
  emit(h.session, "input_audio_buffer.speech_started", { audio_start_ms: 0 });
  await h.session.finish();
  assert.equal(h.session.ready, false);
  const manifest = JSON.parse(h.requests.at(-1).body);
  assert.deepEqual(manifest.transcript_turn_ids, ["turn-1"]);
  const before = h.requests.length;
  emit(h.session, "conversation.item.input_audio_transcription.completed", { transcript: "late" });
  assert.equal(h.requests.length, before);
});

test("heartbeat stops after end and unload requests keepalive", async () => {
  const h = harness();
  await h.session.heartbeat();
  assert.equal(h.requests[0].url, "/sessions/session-id/heartbeat");
  await h.session.finish({ keepalive: true });
  assert.equal(h.requests[1].keepalive, true);
  const count = h.requests.length;
  await h.session.heartbeat();
  assert.equal(h.requests.length, count);
});

test("concurrent finalization shares one manifest request", async () => {
  const h = harness();
  await Promise.all([h.session.finish(), h.session.finish()]);
  assert.equal(h.requests.filter(r => r.url.endsWith("upload-manifest")).length, 1);
});

test("audio and transcript share UUID; failed binary upload retries exact bytes and MIME", async () => {
  const h = harness();
  const id = h.session.beginRecording(100);
  const blob = new Blob([new Uint8Array([0, 1, 255, 4])], { type: "audio/webm;codecs=opus" });
  h.fail(true);
  await h.session.captureRecording(id, Promise.resolve({ blob }), 800);
  await h.session.uploads.get(`/learner-turns/${id}/audio`).pending;
  h.session.bindRecording(id, "item_1");
  h.fail(false);
  emit(h.session, "conversation.item.input_audio_transcription.completed", { transcript: "My answer" });
  await h.session.finish();
  const audio = h.requests.filter(request => request.url.endsWith("/audio"));
  assert.equal(audio.length, 2);
  assert.equal(audio[0].body, blob);
  assert.equal(audio[1].body, blob);
  assert.equal(audio[1].headers["Content-Type"], blob.type);
  assert.deepEqual([...new Uint8Array(await audio[1].body.arrayBuffer())], [0, 1, 255, 4]);
  const manifest = JSON.parse(h.requests.at(-1).body);
  assert.deepEqual(manifest.audio_turn_ids, [id]);
  assert.deepEqual(manifest.transcript_turn_ids, [id]);
  const transcript = h.requests.find(request => request.url.endsWith("/transcript"));
  assert.deepEqual(JSON.parse(transcript.body), { text: "My answer", start_ms: 100, end_ms: 800, provider_item_id: "item_1" });
  assert.equal(h.session.ready, true);
  assert.equal(h.session.bufferedAudioBytes, 0);
});

test("final manifest waits for recorder data after end; missing transcript still blocks evaluation", async () => {
  const h = harness();
  let resolve;
  const result = new Promise(done => { resolve = done; });
  const id = h.session.beginRecording(0);
  h.session.captureRecording(id, result, 2000);
  const finishing = h.session.finish();
  await new Promise(done => setTimeout(done, 0));
  assert.equal(h.requests.some(request => request.url.endsWith("upload-manifest")), false);
  resolve({ blob: new Blob(["complete file"], { type: "audio/mp4" }) });
  await finishing;
  assert.equal(h.requests.some(request => request.url.endsWith(`/learner-turns/${id}/audio`)), true);
  assert.equal(h.session.ready, false);
  assert.deepEqual(JSON.parse(h.requests.at(-1).body).audio_turn_ids, [id]);
});

test("failed recording stays declared and blocks evaluation", async () => {
  const h = harness();
  const id = h.session.beginRecording(0);
  await h.session.captureRecording(id, Promise.resolve({ error: "Recording failed" }), 100);
  h.session.bindRecording(id, "item_1");
  emit(h.session, "conversation.item.input_audio_transcription.completed", { transcript: "hello" });
  await h.session.finish();
  assert.equal(h.session.ready, false);
  assert.deepEqual(JSON.parse(h.requests.at(-1).body).audio_turn_ids, [id]);
  await assert.rejects(h.session.evaluate(), /complete session/);
});

test('expired sign-in retains exact audio for retry after the same account returns', async () => {
  const { AccountBoundary } = await import('../public/account.mjs');
  const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  let expired = false;
  const requests = [];
  const boundary = new AccountBoundary({ fetchImpl: async (url, init) => {
    requests.push({ url, ...init });
    if (url === '/me') return expired ? { ok: false, status: 401 } :
      { ok: true, status: 200, json: async () => ({ account_id: owner }) };
    return expired ? { ok: false, status: 401 } :
      { ok: true, status: 200, json: async () => ({ ready_for_evaluation: true }) };
  } });
  await boundary.check();
  const session = new SessionSync('session-id', {
    fetchImpl: (url, init) => boundary.fetchFor(owner, url, init),
    saveRetryDelays: [0], wait: async () => {},
  });
  const audio = new Blob(['exact bytes'], { type: 'audio/webm' });
  expired = true;
  session.queue('/learner-turns/turn-1/audio', audio, 'audio/webm');
  await session.uploads.values().next().value.pending;
  assert.equal(await session.finish(), null);
  assert.equal(session.uploads.values().next().value.body, audio);
  expired = false;
  await boundary.check({ recover: true });
  await session.finish();
  assert.equal(session.ready, true);
  const sent = requests.filter(request => request.url.endsWith('/audio'));
  assert.equal(sent.length, 1);
  assert.equal(sent[0].body, audio);
  assert.equal(sent[0].headers['X-Expected-Account-ID'], owner);
});

test('account switch cancels pending uploads and discards buffered audio', async () => {
  let resolveUpload;
  const pending = new Promise(resolve => { resolveUpload = resolve; });
  const requests = [];
  const session = new SessionSync('session-id', {
    fetchImpl: (url, init) => { requests.push({ url, ...init }); return pending; },
  });
  const audio = new Blob(['private audio'], { type: 'audio/webm' });
  session.queue('/learner-turns/turn-1/audio', audio, 'audio/webm');
  assert.equal(requests.length, 1);
  session.cancel();
  resolveUpload({ ok: true, status: 200, json: async () => ({}) });
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(session.uploads.size, 0);
  assert.equal(session.ready, false);
  session.queue('/learner-turns/turn-2/audio', audio, 'audio/webm');
  await session.finish();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].signal.aborted, true);
});

test("evaluation advances transcript checkpoints until the final report", async t => {
  const h = harness();
  t.after(() => h.session.cancel());
  h.session.ready = true;
  let calls = 0;
  h.session.fetchImpl = async () => ({ ok: true, json: async () => ++calls < 3
    ? { status: "waiting", transcript_status: "running", transcript_windows_total: 2,
        transcript_windows_completed: calls }
    : { status: "completed", result: { summary: "Ready" } } });
  assert.equal((await h.session.evaluate()).status, "completed");
  assert.equal(calls, 3);
  assert.match(h.messages[0], /1 of 2/);
});

test("account invalidation stops evaluation checkpoint polling", async t => {
  const h = harness();
  t.after(() => h.session.cancel());
  h.session.ready = true;
  let calls = 0;
  h.session.fetchImpl = async () => {
    calls += 1;
    return { ok: true, json: async () => ({ status: "waiting" }) };
  };
  h.session.wait = async () => { h.session.invalidated = true; };
  await assert.rejects(h.session.evaluate(), error => error.reason === "changed");
  assert.equal(calls, 1);
});
