import { TurnRecorder } from "./recorder.mjs";

// Credentials stay in this connection attempt; never persist or log responses.
class ConnectionError extends Error {}

export class RealtimeCall {
  constructor({ audio, onStatus = () => {}, onTranscript = () => {},
    onAudioBlocked = () => {}, onSession = () => {}, onEvent = () => {}, onStop = () => {},
    manualTurns = false, Recorder = TurnRecorder, now = () => performance.now(),
    onTurnState = () => {}, onTurnStart = () => {}, onTurnAudio = () => {}, onTurnCommitted = () => {},
    fetchImpl = (...args) => globalThis.fetch(...args), mediaDevices = globalThis.navigator?.mediaDevices,
    PeerConnection = globalThis.RTCPeerConnection, setupTimeoutMs = 30000 } = {}) {
    Object.assign(this, { onAudioBlocked, manualTurns, Recorder, now, onTurnState, onTurnStart, onTurnAudio, onTurnCommitted, audio, onStatus, onTranscript, onSession, onEvent, onStop, fetchImpl, mediaDevices,
      PeerConnection, setupTimeoutMs });
    this.attempt = null;
  }

  async start(preferences) {
    if (this.attempt) return;
    const attempt = { controller: new AbortController() };
    this.attempt = attempt;
    const current = () => this.attempt === attempt;
    let stage = "microphone";
    this.onStatus("connecting", "Waiting for microphone permission…");
    try {
      if (!this.mediaDevices?.getUserMedia || !this.PeerConnection) {
        throw new ConnectionError("Use a WebRTC-capable browser on HTTPS or localhost.");
      }
      const stream = await this.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
      if (!current()) {
        stream.getTracks().forEach(track => track.stop());
        return;
      }
      attempt.stream = stream;
      if (this.manualTurns) {
        stream.getTracks().forEach(track => { track.enabled = false; });
        try { attempt.recorder = new this.Recorder(stream, { onLimit: () => this.finishTurn() }); }
        catch { throw new ConnectionError("This browser cannot record supported audio. Try a browser with MediaRecorder support."); }
      }
      attempt.clockStart = this.now();
      attempt.timer = setTimeout(() => {
        if (current()) this.stop("Connection timed out. Start again to retry.", "error");
      }, this.setupTimeoutMs);
      stage = "connection";
      const pc = attempt.pc = new this.PeerConnection();
      pc.ontrack = event => {
        if (!current()) return;
        this.audio.srcObject = event.streams[0] || new MediaStream([event.track]);
        this.audio.play().catch(() => {
          if (current()) this.onAudioBlocked();
        });
      };
      pc.onconnectionstatechange = () => {
        if (!current()) return;
        if (["failed", "closed"].includes(pc.connectionState)) {
          this.stop("Connection ended. Start again to reconnect.", "error");
        } else if (pc.connectionState === "disconnected") {
          this.onStatus("connecting", "Connection interrupted. Waiting for the network…");
          attempt.disconnectTimer ??= setTimeout(() => {
            if (current()) this.stop("Connection lost. Start again to reconnect.", "error");
          }, 10000);
        } else if (pc.connectionState === "connected") {
          clearTimeout(attempt.disconnectTimer);
          attempt.disconnectTimer = null;
          if (attempt.dc.readyState === "open") this.onStatus("connected", this.manualTurns ? "Connected. Use Start speaking to record your answer." : "Connected. You can speak now.");
        }
      };
      stream.getTracks().forEach(track => pc.addTrack(track, stream));
      const dc = attempt.dc = pc.createDataChannel("oai-events");
      dc.onopen = () => {
        if (!current()) return;
        clearTimeout(attempt.timer);
        try {
          dc.send(JSON.stringify({ type: "session.update", session: { type: "realtime",
            audio: { input: { transcription: { model: "whisper-1" }, turn_detection: this.manualTurns ? null : { type: "server_vad" } } },
          } }));
          dc.send(JSON.stringify({ type: "response.create" }));
          if (this.manualTurns) attempt.configTimer = setTimeout(() => {
            if (current() && !attempt.configured) this.stop("Voice recording configuration timed out. Please reconnect.", "error");
          }, 10000);
          this.onStatus("connected", this.manualTurns ? "Connected. Use Start speaking to record your answer." : "Connected. You can speak now.");
        } catch {
          this.stop("Could not start the conversation. Please reconnect.", "error");
        }
      };
      dc.onmessage = ({ data }) => {
        if (!current()) return;
        let event;
        try { event = JSON.parse(data); } catch { return; }
        if (this.manualTurns) {
          if (event?.type === "response.created") attempt.responseActive = true;
          if (event?.type === "response.done") attempt.responseActive = false;
          if (event?.type === "output_audio_buffer.started") attempt.playbackActive = true;
          if (["output_audio_buffer.stopped", "output_audio_buffer.cleared"].includes(event?.type)) attempt.playbackActive = false;
          if (event?.type === "session.updated") {
            attempt.configured = event.session?.audio?.input?.turn_detection === null;
            if (attempt.configured) clearTimeout(attempt.configTimer);
            if (attempt.configured && !attempt.turn) this.onTurnState("ready");
          } else if (event?.type === "input_audio_buffer.cleared") {
            attempt.clearResolve?.(true);
          } else if (event?.type === "input_audio_buffer.committed" && attempt.turn?.committing && !attempt.turn.item && typeof event.item_id === "string") {
            attempt.turn.item = event.item_id;
            this.onTurnCommitted(attempt.turn.id, event.item_id);
          }
        }
        this.onEvent(event);
        if (this.manualTurns && attempt.turn?.item && attempt.turn.item === event?.item_id &&
          ["conversation.item.input_audio_transcription.completed", "conversation.item.audio_transcription.completed",
            "conversation.item.input_audio_transcription.failed", "conversation.item.audio_transcription.failed"].includes(event.type)) {
          clearTimeout(attempt.turnTimer);
          attempt.turn = null;
          attempt.turnResolve?.();
          this.onTurnState("ready");
        }
        if (event?.type === "response.output_audio_transcript.done" && typeof event.transcript === "string") {
          this.onTranscript(event.transcript);
        } else if (event?.type === "error" ||
          (event?.type === "response.done" && event.response?.status === "failed")) {
          this.stop("The voice service reported an error. Please reconnect.", "error");
        }
      };
      dc.onclose = dc.onerror = () => {
        if (current()) this.stop("Conversation channel closed. Please reconnect.", "error");
      };
      const offer = await pc.createOffer();
      if (!current()) return;
      await pc.setLocalDescription(offer);
      if (!current()) return;
      this.onStatus("connecting", "Creating your practice session…");
      const response = await this.fetchImpl("/sessions", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(preferences), cache: "no-store", signal: attempt.controller.signal,
      });
      if (!current()) return;
      if (!response.ok) throw new ConnectionError(`Session request failed (HTTP ${response.status}). Check the service and preferences, then retry.`);
      let result;
      try { result = await response.json(); } catch { throw new ConnectionError("Session service returned invalid connection details."); }
      if (!current()) return;
      if (typeof result?.session?.id !== "string" || !result.session.id) {
        throw new ConnectionError("Session service returned an invalid session ID.");
      }
      attempt.sessionId = result.session.id;
      this.onSession(result.session.id);
      const { realtime } = result ?? {};
      let url;
      try { url = new URL(realtime.webrtc_url); } catch { throw new ConnectionError("Session service returned an invalid WebRTC URL."); }
      if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash ||
        url.pathname !== "/openai/v1/realtime/calls") {
        throw new ConnectionError("Session service returned an invalid WebRTC URL.");
      }
      const credential = realtime.client_credential;
      if (typeof credential?.value !== "string" || !credential.value.trim() ||
        !(Date.parse(credential.expires_at) > Date.now())) {
        throw new ConnectionError("Connection credential is missing or expired. Start again for a fresh session.");
      }
      this.onStatus("connecting", "Connecting audio…");
      // The browser sends SDP directly to Azure using the temporary bearer token.
      const answer = await this.fetchImpl(url.href, {
        method: "POST", headers: {
          Authorization: `Bearer ${credential.value}`, "Content-Type": "application/sdp",
        }, body: offer.sdp, cache: "no-store", credentials: "omit", redirect: "error",
        signal: attempt.controller.signal,
      });
      if (!current()) return;
      if (!answer.ok) throw new ConnectionError(`Voice connection rejected (HTTP ${answer.status}). Start again to retry.`);
      const sdp = await answer.text();
      if (!current()) return;
      if (!sdp.startsWith("v=0")) throw new ConnectionError("Voice service returned an invalid SDP answer.");
      await pc.setRemoteDescription({ type: "answer", sdp });
    } catch (error) {
      if (!current()) return;
      const message = stage === "microphone" && error.name === "NotAllowedError"
        ? "Microphone permission denied. Allow microphone access and try again."
        : stage === "microphone" && error.name === "NotFoundError"
          ? "No microphone was found. Connect one and try again."
          : error instanceof ConnectionError ? error.message
            : "Could not connect. Check your microphone, network, and service, then retry.";
      this.stop(message, "error");
    }
  }

  async beginTurn() {
    const attempt = this.attempt;
    if (!attempt?.configured || attempt.turn || attempt.clearing || attempt.ending) return;
    attempt.clearing = true;
    this.onTurnState("waiting");
    try {
      if (attempt.responseActive) attempt.dc.send(JSON.stringify({ type: "response.cancel" }));
      if (attempt.playbackActive) attempt.dc.send(JSON.stringify({ type: "output_audio_buffer.clear" }));
      const cleared = new Promise(resolve => { attempt.clearResolve = resolve; });
      attempt.clearTimer = setTimeout(() => attempt.clearResolve?.(false), 5000);
      attempt.dc.send(JSON.stringify({ type: "input_audio_buffer.clear" }));
      const acknowledged = await cleared;
      if (this.attempt !== attempt) return;
      if (!acknowledged) {
        this.onStatus("connected", "Could not prepare the microphone turn. Try Start speaking again.");
        return;
      }
      const start = Math.max(0, Math.round(this.now() - attempt.clockStart));
      const id = this.onTurnStart(start);
      attempt.turn = { id };
      attempt.recordingResult = attempt.recorder.start();
      attempt.stream.getTracks().forEach(track => { track.enabled = true; });
      this.onTurnState("recording");
    } catch {
      this.stop("Could not record this turn. Please start a new session.", "error");
    } finally {
      clearTimeout(attempt.clearTimer);
      attempt.clearResolve = null;
      attempt.clearing = false;
      if (this.attempt === attempt && !attempt.turn) this.onTurnState("ready");
    }
  }

  finishTurn() {
    const attempt = this.attempt;
    if (!attempt?.turn || attempt.turn.committing) return;
    const turn = attempt.turn;
    turn.committing = true;
    attempt.stream.getTracks().forEach(track => { track.enabled = false; });
    const result = attempt.recorder.stop();
    this.onTurnAudio(turn.id, result, Math.round(this.now() - attempt.clockStart));
    attempt.recordingResult = null;
    this.onTurnState("waiting");
    // MediaRecorder's final data event must be collected before closing resources.
    void result.then(() => {
      if (this.attempt !== attempt) return;
      try {
        attempt.dc.send(JSON.stringify({ type: "input_audio_buffer.commit" }));
        attempt.dc.send(JSON.stringify({ type: "response.create" }));
        attempt.turnTimer = setTimeout(() => {
          if (this.attempt === attempt && attempt.turn) {
            this.stop("The turn transcript timed out. Audio will be saved; feedback needs the missing transcript.", "error");
          }
        }, 15000);
      } catch { this.stop("Could not submit this turn. Audio will be saved.", "error"); }
    });
  }

  async disconnect() {
    const attempt = this.attempt;
    if (!attempt || attempt.ending) return;
    attempt.ending = true;
    this.finishTurn();
    if (attempt.turn) {
      await new Promise(resolve => {
        attempt.turnResolve = resolve;
        attempt.endTimer = setTimeout(resolve, 16000);
      });
    }
    if (this.attempt === attempt) this.stop();
  }

  stop(message = "Disconnected. Microphone released.", state = "idle", options = {}) {
    const attempt = this.attempt;
    if (attempt?.turn && !attempt.turn.committing) {
      attempt.turn.committing = true;
      const recording = attempt.recorder.stop();
      if (!options.suppressSessionEnd) this.onTurnAudio(attempt.turn.id, recording, Math.round(this.now() - attempt.clockStart));
    }
    this.attempt = null; // Invalidate callbacks before close emits events.
    if (attempt) {
      clearTimeout(attempt.timer);
      clearTimeout(attempt.turnTimer);
      clearTimeout(attempt.clearTimer);
      clearTimeout(attempt.endTimer);
      clearTimeout(attempt.configTimer);
      attempt.clearResolve?.(false);
      attempt.turnResolve?.();
      clearTimeout(attempt.disconnectTimer);
      attempt.controller.abort();
      attempt.dc?.close();
      attempt.pc?.close();
      attempt.stream?.getTracks().forEach(track => track.stop());
    }
    this.onTurnState("disabled");
    this.audio.pause();
    this.audio.srcObject = null;
    this.onStatus(state, message);
    if (attempt?.sessionId && !options.suppressSessionEnd) this.onStop(options);
  }
}
