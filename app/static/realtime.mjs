// Credentials stay in this connection attempt; never persist or log responses.
class ConnectionError extends Error {}

export class RealtimeCall {
  constructor({ audio, onStatus = () => {}, onTranscript = () => {},
    fetchImpl = globalThis.fetch, mediaDevices = globalThis.navigator?.mediaDevices,
    PeerConnection = globalThis.RTCPeerConnection, setupTimeoutMs = 30000 } = {}) {
    Object.assign(this, { audio, onStatus, onTranscript, fetchImpl, mediaDevices,
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
      const stream = await this.mediaDevices.getUserMedia({ audio: true });
      if (!current()) {
        stream.getTracks().forEach(track => track.stop());
        return;
      }
      attempt.stream = stream;
      attempt.timer = setTimeout(() => {
        if (current()) this.stop("Connection timed out. Start again to retry.", "error");
      }, this.setupTimeoutMs);
      stage = "connection";
      const pc = attempt.pc = new this.PeerConnection();
      pc.ontrack = event => {
        if (!current()) return;
        this.audio.srcObject = event.streams[0] || new MediaStream([event.track]);
        this.audio.play().catch(() => {
          if (current()) this.onStatus("connected", "Press Play in the audio controls to hear replies.");
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
          if (attempt.dc.readyState === "open") this.onStatus("connected", "Connected. You can speak now.");
        }
      };
      stream.getTracks().forEach(track => pc.addTrack(track, stream));
      const dc = attempt.dc = pc.createDataChannel("oai-events");
      dc.onopen = () => {
        if (!current()) return;
        clearTimeout(attempt.timer);
        try {
          dc.send(JSON.stringify({ type: "response.create" }));
          this.onStatus("connected", "Connected. You can speak now.");
        } catch {
          this.stop("Could not start the conversation. Please reconnect.", "error");
        }
      };
      dc.onmessage = ({ data }) => {
        if (!current()) return;
        let event;
        try { event = JSON.parse(data); } catch { return; }
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

  stop(message = "Disconnected. Microphone released.", state = "idle") {
    const attempt = this.attempt;
    this.attempt = null; // Invalidate callbacks before close emits events.
    if (attempt) {
      clearTimeout(attempt.timer);
      clearTimeout(attempt.disconnectTimer);
      attempt.controller.abort();
      attempt.dc?.close();
      attempt.pc?.close();
      attempt.stream?.getTracks().forEach(track => track.stop());
    }
    this.audio.pause();
    this.audio.srcObject = null;
    this.onStatus(state, message);
  }
}
