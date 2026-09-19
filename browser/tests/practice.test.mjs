import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

function page() {
  const nodes = new Map();
  function element() {
    return { children: [], hidden: false, scrollTop: 0, clientHeight: 300,
      listeners: {}, style: { setProperty() {} }, classList: { toggle() {} },
      setAttribute() {}, addEventListener(name, fn) { this.listeners[name] = fn; },
      append(node) { this.children.push(node); }, replaceChildren() { this.children = []; },
      get scrollHeight() { return Math.max(300, this.children.length * 100); },
      getBoundingClientRect() { return { height: 120 }; }, scrollIntoView() {}, focus() {} };
  }
  const document = { body: element(), createElement: element,
    querySelector(id) { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); } };
  let callbacks;
  const context = vm.createContext({ document, window: { addEventListener() {} },
    ResizeObserver: class { observe() {} },
    RealtimeCall: class { constructor(options) { callbacks = options; } }, SessionSync: class {} });
  const source = readFileSync(new URL('../public/practice.mjs', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
  vm.runInContext(source, context);
  return { nodes, callbacks };
}

test('transcripts follow latest messages but preserve a reader’s earlier position', () => {
  const { nodes, callbacks } = page();
  const transcript = nodes.get('#transcripts');
  for (let i = 0; i < 8; i++) callbacks.onTranscript(`Message ${i}`);
  assert.equal(transcript.scrollTop, transcript.scrollHeight);
  transcript.scrollTop = 0;
  callbacks.onTranscript('A new reply');
  assert.equal(transcript.scrollTop, 0);
  assert.equal(nodes.get('#latest').hidden, false);
  nodes.get('#latest').listeners.click();
  assert.equal(transcript.scrollTop, transcript.scrollHeight);
  assert.equal(nodes.get('#latest').hidden, true);
});

test('audio fallback is visible on blocked playback and mute is independent', () => {
  const { nodes, callbacks } = page();
  callbacks.onAudioBlocked();
  assert.equal(nodes.get('#enable-audio').hidden, false);
  nodes.get('#sound').listeners.click();
  assert.equal(nodes.get('#reply').muted, true);
  assert.equal(nodes.get('#sound').textContent, 'Agent sound off');
  callbacks.onStatus('error', 'Connection ended');
  assert.equal(nodes.get('#enable-audio').hidden, true);
  assert.equal(nodes.get('#start').hidden, false);
});
