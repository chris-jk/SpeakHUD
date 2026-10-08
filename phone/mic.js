// The phone's microphone as plain sound: an audio worklet that hands the page what it
// hears, a couple of thousand samples at a time. The page (app.js, "dictation") keeps
// them, and sends the recording to the Mac when you stop talking. Nothing is played.
class Mic extends AudioWorkletProcessor {
  constructor() {
    super();
    this.held = new Float32Array(2048);
    this.filled = 0;
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (!channel) return true;
    for (let i = 0; i < channel.length; i++) {
      this.held[this.filled++] = channel[i];
      if (this.filled === this.held.length) {
        this.port.postMessage(this.held.slice(0));
        this.filled = 0;
      }
    }
    return true;
  }
}

registerProcessor('mic', Mic);
