import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { BackendError, loadEvaluation } from '../public/session.mjs';
import { AccountBoundary, AccountError } from '../public/account.mjs';

const sessionId = '123e4567-e89b-42d3-a456-426614174000';
const report = { status: 'completed', result: {
  summary: 'You explained your work clearly.', strengths: ['Clear examples'],
  grammar: { score: 4, feedback: 'Good structure.' },
  vocabulary: { score: 4, feedback: 'Good range.' },
  coherence: { score: 4, feedback: 'Easy to follow.' },
  next_steps: ['Practice shorter openings'], corrections: [],
} };

const accountA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const accountB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const feedbackKey = id => `speakwell:last-completed-feedback:${id}`;

function page({ saved = null, legacy = null, accountId = accountA, storageStore = null,
  response = async () => ({ ok: true, json: async () => report }) } = {}) {
  const nodes = new Map();
  const storage = storageStore ?? new Map();
  if (saved) storage.set(feedbackKey(accountId), JSON.stringify(saved));
  if (legacy) storage.set('speakwell:last-completed-feedback', JSON.stringify(legacy));
  const requests = [], documentListeners = {}, windowListeners = [];
  let signedIn = accountId, callbacks, currentSession, reloads = 0;
  function element() {
    return { children: [], hidden: false, disabled: false, scrollTop: 0, clientHeight: 300,
      listeners: {}, style: { setProperty() {} }, classList: { toggle() {} },
      setAttribute() {}, addEventListener(name, fn) { this.listeners[name] = fn; },
      append(node) { this.children.push(node); }, replaceChildren() { this.children = []; },
      get scrollHeight() { return Math.max(300, this.children.length * 100); },
      getBoundingClientRect() { return { height: 120 }; }, scrollIntoView() {}, focus() {} };
  }
  const document = { body: element(), createElement: element, hidden: false,
    addEventListener(name, fn) { documentListeners[name] = fn; },
    querySelectorAll() { return []; },
    querySelector(id) {
      if (!nodes.has(id)) {
        const node = element();
        if (['#feedback-section', '#conversation', '#restore-feedback', '#retry-save',
          '#retry-account', '#sign-in'].includes(id)) node.hidden = true;
        nodes.set(id, node);
      }
      return nodes.get(id);
    } };
  const fetch = async (url, init) => {
    requests.push({ url, ...init });
    if (url === '/me') return signedIn ? { ok: true, status: 200,
      json: async () => ({ account_id: signedIn }) } : { ok: false, status: 401 };
    return response(url, init);
  };
  const context = vm.createContext({ document, fetch,
    window: { addEventListener(name, fn) { windowListeners.push([name, fn]); },
      location: { reload() { reloads++; } } },
    BackendError, AccountBoundary, AccountError,
    localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value),
      removeItem: key => storage.delete(key) },
    loadEvaluation,
    FormData: class { *[Symbol.iterator]() { yield* Object.entries({ speaking_goal: 'Explain ideas clearly',
      level: 'B1', preferred_topic: '', session_duration_minutes: '15' }); } },
    ResizeObserver: class { observe() {} },
    RealtimeCall: class {
      constructor(options) { callbacks = options; this.attempt = null; }
      async start() { callbacks.onSession(sessionId); }
      stop() { this.attempt = null; }
    },
    SessionSync: class {
      constructor(id, options) { this.id = id; this.options = options; this.ready = true;
        this.ended = true; this.cancelled = false; currentSession = this; }
      async evaluate() { return report; }
      async finish() { return {}; }
      cancel() { this.cancelled = true; }
    } });
  const source = readFileSync(new URL('../public/practice.mjs', import.meta.url), 'utf8').replace(/^import .*;\n/gm, '');
  vm.runInContext(source, context);
  return { nodes, callbacks, storage, requests, context, documentListeners,
    setAccount(id) { signedIn = id; }, get currentSession() { return currentSession; },
    get reloads() { return reloads; } };
}

const flush = () => new Promise(resolve => setImmediate(resolve));

test('completed feedback reloads from the saved session ID and can be forgotten locally', async () => {
  const h = page({ saved: { id: sessionId, goal: 'Explain ideas clearly' } });
  await flush();
  const evaluationRequests = h.requests.filter(request => request.url.endsWith('/evaluation'));
  assert.equal(evaluationRequests.length, 1);
  assert.equal(evaluationRequests[0].url, `/sessions/${sessionId}/evaluation`);
  assert.equal(evaluationRequests[0].method, 'GET');
  assert.equal(evaluationRequests[0].headers['X-Expected-Account-ID'], accountA);
  assert.equal(h.nodes.get('#feedback-section').hidden, false);
  assert.equal(h.nodes.get('#conversation').hidden, true);
  assert.equal(h.nodes.get('#feedback').children[0].textContent, 'Progress toward: Explain ideas clearly');
  h.nodes.get('#forget-feedback').listeners.click();
  assert.equal(h.storage.size, 0);
  assert.equal(h.nodes.get('#forget-feedback').hidden, true);
});

test('a new completed evaluation saves its ID for the next visit', async () => {
  const h = page();
  await flush();
  await h.nodes.get('#preferences').listeners.submit({ preventDefault() {} });
  h.nodes.get('#evaluate').listeners.click();
  await flush();
  assert.deepEqual(JSON.parse(h.storage.get(feedbackKey(accountA))), { id: sessionId, goal: 'Explain ideas clearly' });
  assert.equal(h.nodes.get('#feedback-section').hidden, false);
});

test('missing saved feedback is forgotten; a temporary failure offers retry', async () => {
  const missing = page({ saved: { id: sessionId, goal: 'Fluency' },
    response: async () => ({ ok: false, status: 404 }) });
  await flush();
  assert.equal(missing.storage.size, 0);
  assert.equal(missing.nodes.get('#restore-feedback').hidden, true);

  let attempts = 0;
  const retry = page({ saved: { id: sessionId, goal: 'Fluency' }, response: async () => {
    attempts++;
    return attempts === 1 ? { ok: false, status: 503 } : { ok: true, json: async () => report };
  } });
  await flush();
  assert.equal(retry.nodes.get('#restore-feedback').hidden, false);
  retry.nodes.get('#restore-feedback').listeners.click();
  await flush();
  assert.equal(retry.nodes.get('#feedback-section').hidden, false);
  assert.equal(attempts, 2);
});

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

test('legacy report key is discarded and a different account cannot see saved metadata', async () => {
  const storage = new Map([[feedbackKey(accountA), JSON.stringify({ id: sessionId, goal: 'Private goal' })],
    ['speakwell:last-completed-feedback', JSON.stringify({ id: sessionId, goal: 'Legacy goal' })]]);
  const h = page({ accountId: accountB, storageStore: storage });
  await flush();
  assert.equal(storage.has('speakwell:last-completed-feedback'), false);
  assert.equal(storage.has(feedbackKey(accountA)), true);
  assert.equal(h.requests.some(request => request.url.endsWith('/evaluation')), false);
  assert.equal(h.nodes.get('#feedback-section').hidden, true);
  assert.equal(h.nodes.get('#feedback').children.length, 0);
});

test('expired sign-in blocks practice until the same account is verified', async () => {
  const h = page({ accountId: null });
  await flush();
  assert.equal(h.nodes.get('#start').disabled, true);
  assert.equal(h.nodes.get('#sign-in').hidden, false);
  assert.equal(h.requests.every(request => request.url === '/me'), true);
  h.setAccount(accountA);
  h.nodes.get('#retry-account').listeners.click();
  await flush();
  assert.equal(h.nodes.get('#start').disabled, false);
  assert.equal(h.nodes.get('#sign-in').hidden, true);
});

test('account switch during report load discards the old response and clears the page', async () => {
  let release;
  const pending = new Promise(resolve => { release = resolve; });
  const h = page({ saved: { id: sessionId, goal: 'Private goal' }, response: () => pending });
  await flush();
  assert.equal(h.requests.some(request => request.url.endsWith('/evaluation')), true);
  h.setAccount(accountB);
  h.documentListeners.visibilitychange();
  await flush();
  release({ ok: true, json: async () => report });
  await flush();
  assert.equal(h.nodes.get('#feedback-section').hidden, true);
  assert.equal(h.nodes.get('#feedback').children.length, 0);
  assert.equal(h.nodes.get('#start').disabled, true);
  assert.equal(h.nodes.get('#retry-account').textContent, 'Reload page');
  assert.equal(h.storage.has(feedbackKey(accountA)), true);
});
