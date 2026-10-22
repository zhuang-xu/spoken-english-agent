import { AccountError } from "./account.mjs";
// Same-origin backend requests. Never persist credentials or raw error responses.
export class BackendError extends Error {
  constructor(status, path = "") {
    super(status === 401 ? "Your sign-in expired. Sign in again, then retry." :
      status === 403 ? "This account does not have access to practice." :
      status === 404 ? "This session is no longer available on the server. Start a new conversation." :
      status === 502 && path === "/evaluation" ? "The feedback service could not complete the report. Your session is saved; try Get feedback again." :
      status ? `Backend request failed (HTTP ${status}). Please retry.` : "Backend unavailable. Check your connection and retry.");
    this.status = status;
  }
}

const transientSaveError = error => error instanceof BackendError &&
  (!error.status || error.status === 408 || error.status === 429 || error.status >= 500);

export async function loadEvaluation(id, fetchImpl = (...args) => globalThis.fetch(...args)) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30000);
  try {
    const response = await fetchImpl(`/sessions/${encodeURIComponent(id)}/evaluation`, {
      method: "GET", cache: "no-store", credentials: "same-origin", signal: controller.signal,
    });
    if (!response.ok) throw new BackendError(response.status, "/evaluation");
    return await response.json();
  } catch (error) {
    throw error instanceof BackendError ? error : new BackendError();
  } finally { clearTimeout(timer); }
}

export class SessionSync {
  constructor(id, { fetchImpl = (...args) => globalThis.fetch(...args), uuid = () => crypto.randomUUID(),
    onChange = () => {}, onSaveFailed = () => {}, onTranscript = () => {}, heartbeatMs = 30000,
    saveRetryDelays = [0, 750, 2000], wait = ms => new Promise(resolve => setTimeout(resolve, ms)) } = {}) {
    Object.assign(this, { id, fetchImpl, uuid, onChange, onSaveFailed, onTranscript,
      saveRetryDelays, wait });
    this.turns = new Map();
    this.recordedTurns = new Map();
    this.captures = new Set();
    this.bufferedAudioBytes = 0;
    this.parts = new Map();
    this.uploads = new Map();
    this.ended = false;
    this.ready = false;
    this.invalidated = false;
    this.controllers = new Set();
    this.timer = setInterval(() => this.heartbeat(), heartbeatMs);
  }

  async request(path, { method = "POST", body, contentType, keepalive = false } = {}) {
    if (this.invalidated) throw new AccountError("changed");
    const controller = new AbortController();
    this.controllers.add(controller);
    const timeout = path === "/evaluation" ? 200000 : path.endsWith("/audio") ? 130000 : 30000;
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
      const response = await this.fetchImpl(`/sessions/${encodeURIComponent(this.id)}${path}`, {
        method, cache: "no-store", credentials: "same-origin", signal: controller.signal, keepalive,
        ...(body === undefined ? {} : { headers: { "Content-Type": contentType || "application/json" }, body: contentType ? body : JSON.stringify(body) }),
      });
      if (this.invalidated) throw new AccountError("changed");
      if (!response.ok) throw new BackendError(response.status, path);
      const result = await response.json();
      if (this.invalidated) throw new AccountError("changed");
      return result;
    } catch (error) {
      throw error instanceof BackendError || error instanceof AccountError ? error : new BackendError();
    } finally { clearTimeout(timer); this.controllers.delete(controller); }
  }

  cancel() {
    this.invalidated = true;
    this.ended = true;
    this.ready = false;
    clearInterval(this.timer);
    for (const controller of this.controllers) controller.abort();
    this.controllers.clear();
    this.turns.clear();
    this.recordedTurns.clear();
    this.parts.clear();
    for (const upload of this.uploads.values()) upload.body = null;
    this.uploads.clear();
    this.bufferedAudioBytes = 0;
  }

  async heartbeat() {
    if (this.ended || this.beating) return;
    this.beating = true;
    try { await this.request("/heartbeat"); }
    catch (error) { if (!this.ended) this.onChange(error.message); }
    finally { this.beating = false; }
  }

  turn(item) {
    if (!this.turns.has(item)) {
      if (this.turns.size >= 1000) throw new Error("Transcript limit reached. End this session.");
      this.turns.set(item, { id: this.uuid() });
    }
    return this.turns.get(item);
  }

  inventory() {
    return [...new Map([...this.turns.values(), ...this.recordedTurns.values()].map(turn => [turn.id, turn])).values()];
  }

  beginRecording(start) {
    if (this.ended || this.inventory().length >= 1000) throw new Error("Session turn limit reached.");
    const turn = { id: this.uuid(), start, expectsAudio: true };
    this.recordedTurns.set(turn.id, turn);
    return turn.id;
  }

  bindRecording(id, item) {
    const turn = this.recordedTurns.get(id);
    if (!turn || this.ended || this.turns.has(item)) return;
    this.turns.set(item, turn);
  }

  captureRecording(id, result, end) {
    const turn = this.recordedTurns.get(id);
    if (!turn) return;
    turn.end = Math.max(turn.start + 1, end);
    const pending = Promise.resolve(result).then(({ blob, error }) => {
      if (this.invalidated) return;
      if (error || !blob || !blob.size || blob.size > 10 * 1024 * 1024) {
        this.captureFailed = true;
        this.onChange(error || "Audio recording is missing or too large. Feedback is unavailable.");
        return;
      }
      if (this.bufferedAudioBytes + blob.size > 64 * 1024 * 1024) {
        this.captureFailed = true;
        this.onChange("Unsaved audio exceeded the memory limit. Feedback is unavailable for this session.");
        return;
      }
      this.bufferedAudioBytes += blob.size;
      this.queue(`/learner-turns/${id}/audio`, blob, blob.type);
    }).catch(() => {
      this.captureFailed = true;
      this.onChange("Audio recording failed. Feedback is unavailable.");
    }).finally(() => this.captures.delete(pending));
    this.captures.add(pending);
    return pending;
  }

  handle(event) {
    if (this.ended || !event || typeof event.type !== "string" || typeof event.item_id !== "string") return;
    try {
      if (event.type === "input_audio_buffer.speech_started") {
        this.turn(event.item_id).start = event.audio_start_ms;
      } else if (event.type === "input_audio_buffer.speech_stopped") {
        this.turn(event.item_id).end = event.audio_end_ms;
      } else if (["conversation.item.input_audio_transcription.completed", "conversation.item.audio_transcription.completed"].includes(event.type)) {
        const turn = this.turn(event.item_id);
        if (turn.text === undefined && typeof event.transcript === "string") {
          turn.text = event.transcript.trim();
          this.onTranscript(turn.text, "You");
        }
      } else if (event.type.endsWith("transcription.failed")) {
        this.turn(event.item_id);
        this.onChange("A learner transcript is missing. Feedback will stay unavailable for this session.");
      } else if (event.type === "response.output_audio_transcript.done") {
        if (!/^[A-Za-z0-9_-]{1,200}$/.test(event.item_id) || !Number.isInteger(event.content_index) || event.content_index < 0 ||
          typeof event.response_id !== "string" || typeof event.transcript !== "string") return;
        const key = `${event.item_id}/transcripts/${event.content_index}`;
        if (!this.parts.has(key)) {
          if (this.parts.size >= 1000) throw new Error("Transcript limit reached. End this session.");
          this.parts.set(key, { item_id: event.item_id, content_index: event.content_index });
          this.queue(`/agent-items/${key}`, { text: event.transcript, response_id: event.response_id, playback_status: "unknown" });
        }
      }
      const turn = this.turns.get(event.item_id);
      if (turn?.text && Number.isInteger(turn.start) && turn.start >= 0 && Number.isInteger(turn.end) && turn.end > turn.start) {
        this.queue(`/learner-turns/${turn.id}/transcript`, {
          text: turn.text, start_ms: turn.start, end_ms: turn.end, provider_item_id: event.item_id,
        });
      }
    } catch (error) { this.captureFailed = true; this.onChange(error.message); }
  }

  queue(path, body, contentType) {
    if (this.invalidated || this.uploads.has(path)) return;
    const upload = { path, body, contentType, saved: false };
    this.uploads.set(path, upload);
    void this.send(upload);
  }

  async send(upload) {
    if (this.invalidated || upload.saved) return;
    if (upload.pending) return upload.pending;
    upload.pending = (async () => {
      try {
        await this.request(upload.path, { method: "PUT", body: upload.body, contentType: upload.contentType });
        if (this.invalidated) return;
        upload.saved = true;
        upload.error = null;
        if (upload.contentType) {
          this.bufferedAudioBytes -= upload.body.size;
          upload.body = null; // Successful audio needs no further in-memory retry copy.
        }
      }
      catch (error) {
        upload.error = error;
        if (!this.ended) this.onChange(`Upload not saved yet${error.status ? ` (HTTP ${error.status})` : ""}. It will retry automatically when the conversation ends.`);
      }
      finally { upload.pending = null; }
    })();
    return upload.pending;
  }

  finish({ keepalive = false } = {}) {
    if (this.invalidated) return Promise.resolve(null);
    this.ended = true;
    clearInterval(this.timer);
    if (this.finishing) return this.finishing;
    this.finishing = this.finalize(keepalive).finally(() => { this.finishing = null; });
    return this.finishing;
  }

  async finalize(keepalive) {
    this.ready = false;
    for (let attempt = 0; attempt < this.saveRetryDelays.length; attempt++) {
      if (this.invalidated) return null;
      if (attempt) {
        this.onChange(`Saving session… automatic retry ${attempt + 1} of ${this.saveRetryDelays.length}.`);
        await this.wait(this.saveRetryDelays[attempt]);
      }
      try {
        // End is idempotent; uploads remain legal after ending.
        await this.request("/end", { keepalive });
        await Promise.all([...this.captures]);
        await Promise.all([...this.uploads.values()].map(upload => this.send(upload)));
        const failed = [...this.uploads.values()].filter(upload => !upload.saved);
        if (failed.length) {
          throw failed.find(upload => !transientSaveError(upload.error))?.error ||
            failed[0].error || new BackendError();
        }
        const status = await this.request("/upload-manifest", { method: "PUT", body: {
          audio_turn_ids: this.inventory().filter(turn => turn.expectsAudio).map(turn => turn.id),
          transcript_turn_ids: this.inventory().map(turn => turn.id),
          agent_transcripts: [...this.parts.values()],
        } });
        this.ready = status.ready_for_evaluation === true && !this.captureFailed &&
          this.inventory().every(turn => this.uploads.get(`/learner-turns/${turn.id}/transcript`)?.saved &&
            (!turn.expectsAudio || this.uploads.get(`/learner-turns/${turn.id}/audio`)?.saved)) &&
          [...this.uploads.values()].every(upload => upload.saved);
        if (this.ready) {
          this.onChange("Session saved. Feedback is ready to request.");
        } else {
          const note = this.inventory().length ?
            "The session ended, but some audio or transcripts could not be saved. Feedback is unavailable for this session." :
            "Session ended. No learner speech was captured.";
          this.onChange(note);
          this.onSaveFailed(note);
        }
        return status;
      } catch (error) {
        if (this.invalidated) return null;
        if (error instanceof AccountError || error?.status === 401 || error?.status === 403) {
          this.onChange(error.message);
          this.onSaveFailed(error.message);
          return null;
        }
        if (!transientSaveError(error)) {
          const note = `${error.message} Feedback is unavailable for this session.`;
          this.onChange(note);
          this.onSaveFailed(note);
          return null;
        }
      }
    }
    const note = `We could not save this session after ${this.saveRetryDelays.length} automatic attempts. Check your connection before starting a new conversation. Feedback is unavailable for this session.`;
    this.onChange(note);
    this.onSaveFailed(note);
    return null;
  }

  async evaluate() {
    if (this.invalidated) throw new AccountError("changed");
    if (!this.ready) throw new Error("Save a complete session before requesting feedback.");
    for (let step = 0; step < 256; step += 1) {
      if (this.invalidated) throw new AccountError("changed");
      const evaluation = await this.request("/evaluation");
      if (evaluation.status !== "waiting" || step === 255) return evaluation;
      const total = evaluation.transcript_windows_total ?? 0;
      const completed = evaluation.transcript_windows_completed ?? 0;
      this.onChange(total && evaluation.transcript_status !== "completed"
        ? `Preparing feedback: ${completed} of ${total} transcript batches complete…`
        : "Preparing the final feedback…");
      await this.wait(5000);
    }
  }
}
