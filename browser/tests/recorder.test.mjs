import { test } from "node:test";
import assert from "node:assert/strict";
import { TurnRecorder } from "../public/recorder.mjs";

function harness(options = {}) {
  const instances = [];
  class MediaRecorder {
    static isTypeSupported(type) { return type === "audio/webm;codecs=opus"; }
    constructor(stream, config) { this.mimeType = config.mimeType; this.stream = stream; instances.push(this); }
    start() { this.state = "recording"; }
    stop() { this.state = "inactive"; }
    chunk(text) { this.ondataavailable({ data: new Blob([text]) }); }
    complete() { this.onstop(); }
  }
  const stream = {};
  const recorder = new TurnRecorder(stream, { MediaRecorderImpl: MediaRecorder, ...options });
  return { recorder, instances, stream };
}

test("uploads a complete container including final asynchronous data; a second turn is independent", async () => {
  const h = harness();
  const first = h.recorder.start();
  const media = h.instances[0];
  assert.equal(media.stream, h.stream);
  media.chunk("header");
  const stopped = h.recorder.stop();
  assert.equal(first, stopped);
  media.chunk("last-frame");
  media.complete();
  const { blob, error } = await stopped;
  assert.equal(error, null);
  assert.equal(blob.type, "audio/webm;codecs=opus");
  assert.equal(await blob.text(), "headerlast-frame");
  const next = h.recorder.start();
  h.instances[1].chunk("new-container");
  h.recorder.stop();
  h.instances[1].complete();
  assert.equal(await (await next).blob.text(), "new-container");
});

test("oversized and empty recordings fail rather than uploading fragments", async () => {
  const h = harness({ maxBytes: 3 });
  const result = h.recorder.start();
  h.instances[0].chunk("too large");
  h.instances[0].complete();
  assert.equal((await result).blob, null);
  const empty = h.recorder.start();
  h.recorder.stop();
  h.instances[1].complete();
  assert.match((await empty).error, /No audio/);
});

test("recording errors and missing stop events are bounded", async () => {
  const h = harness({ stopTimeoutMs: 5 });
  const result = h.recorder.start();
  h.instances[0].onerror();
  assert.match((await result).error, /did not finish/);
});

test("duration limit finalizes the recording", async () => {
  let limited = 0;
  const h = harness({ maxDurationMs: 5, onLimit: () => limited++ });
  const result = h.recorder.start();
  h.instances[0].chunk("recording");
  await new Promise(resolve => setTimeout(resolve, 15));
  assert.equal(limited, 1);
  assert.equal(h.instances[0].state, "inactive");
  h.instances[0].complete();
  assert.equal(await (await result).blob.text(), "recording");
});

test("unsupported recording fails before capture", () => {
  assert.throws(() => new TurnRecorder({}, { MediaRecorderImpl: null }), /unavailable/);
});
