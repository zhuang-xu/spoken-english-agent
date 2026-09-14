export const MAX_AUDIO_BYTES = 10 * 1024 * 1024;
const MIME_TYPES = ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/mp4"];

// One complete container per utterance; timeslice fragments are never uploaded alone.
export class TurnRecorder {
  constructor(stream, { MediaRecorderImpl = globalThis.MediaRecorder,
    maxBytes = MAX_AUDIO_BYTES, maxDurationMs = 120000, stopTimeoutMs = 5000,
    onLimit = () => {} } = {}) {
    if (!MediaRecorderImpl) throw new Error("Audio recording is unavailable. Use a browser with MediaRecorder support.");
    const mimeType = MIME_TYPES.find(type => MediaRecorderImpl.isTypeSupported(type));
    if (!mimeType) throw new Error("This browser cannot record a supported audio format.");
    Object.assign(this, { stream, MediaRecorderImpl, mimeType, maxBytes, maxDurationMs, stopTimeoutMs, onLimit });
  }

  start() {
    if (this.current) throw new Error("A recording is already in progress.");
    const recorder = new this.MediaRecorderImpl(this.stream, { mimeType: this.mimeType, audioBitsPerSecond: 64000 });
    const take = this.current = { recorder, chunks: [], size: 0 };
    take.result = new Promise(resolve => { take.resolve = resolve; });
    const complete = error => {
      if (take.done) return;
      take.done = true;
      clearTimeout(take.limitTimer);
      clearTimeout(take.stopTimer);
      const blob = new Blob(take.chunks, { type: recorder.mimeType || this.mimeType });
      take.chunks = [];
      if (this.current === take) this.current = null;
      take.resolve({ blob: error || !blob.size ? null : blob,
        error: error || (!blob.size ? "No audio was recorded. Please start a new session." : null) });
    };
    recorder.ondataavailable = ({ data }) => {
      if (take.done || take.error || !data?.size) return;
      take.size += data.size;
      if (take.size > this.maxBytes) {
        take.error = "Recording exceeded 10 MiB. This turn cannot be assessed.";
        take.chunks = [];
        this.onLimit();
        void this.stop();
      } else take.chunks.push(data);
    };
    recorder.onerror = () => {
      take.error = "Audio recording failed. This turn cannot be assessed.";
      this.onLimit();
      void this.stop();
    };
    recorder.onstop = () => complete(take.error);
    take.complete = complete;
    try { recorder.start(250); }
    catch (error) { complete("Audio recording could not start."); throw error; }
    take.limitTimer = setTimeout(() => { this.onLimit(); void this.stop(); }, this.maxDurationMs);
    return take.result;
  }

  stop() {
    const take = this.current;
    if (!take) return Promise.resolve({ blob: null, error: "No recording is in progress." });
    if (!take.stopping) {
      take.stopping = true;
      clearTimeout(take.limitTimer);
      take.stopTimer = setTimeout(() => take.complete("Audio recording did not finish. This turn cannot be assessed."), this.stopTimeoutMs);
      try { if (take.recorder.state !== "inactive") take.recorder.stop(); }
      catch { take.complete("Audio recording did not finish. This turn cannot be assessed."); }
    }
    return take.result;
  }
}
