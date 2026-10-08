import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AccountBoundary, AccountError } from '../public/account.mjs';

const A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const me = accountId => ({ ok: true, status: 200, json: async () => ({ account_id: accountId }) });

test('blocks protected requests until /me verifies the account', async () => {
  const requests = [];
  const account = new AccountBoundary({ fetchImpl: async (url, init) => {
    requests.push({ url, ...init });
    return url === '/me' ? me(A) : { ok: true, status: 200 };
  } });
  await assert.rejects(account.fetchFor(A, '/sessions', { method: 'POST' }),
    error => error instanceof AccountError && error.reason === 'changed');
  assert.equal(requests.length, 0);
  assert.equal(await account.check(), A);
  await account.fetchFor(A, '/sessions', { method: 'POST', headers: { 'Content-Type': 'application/json' } });
  assert.deepEqual(requests.map(request => request.url), ['/me', '/me', '/sessions']);
  assert.deepEqual(requests[2].headers, {
    'Content-Type': 'application/json', 'X-Expected-Account-ID': A,
  });
});

test('expired sign-in can recover only under the original account', async () => {
  let identity = A, expired = false;
  const states = [];
  const account = new AccountBoundary({ fetchImpl: async url => url === '/me' && expired ?
    { ok: false, status: 401 } : me(identity), onState: state => states.push(state) });
  await account.check();
  expired = true;
  await assert.rejects(account.fetchFor(A, '/sessions/x/end'),
    error => error.reason === 'required');
  await assert.rejects(account.fetchFor(A, '/sessions/x/end'),
    error => error.reason === 'required');
  expired = false;
  assert.equal(await account.check({ recover: true }), A);
  assert.deepEqual(states, ['ready', 'required', 'ready']);
  identity = B;
  await assert.rejects(account.fetchFor(A, '/sessions/x/end'),
    error => error.reason === 'changed');
  assert.equal(account.state, 'changed');
});

test('server expected-account rejection detects a cookie switch after /me', async () => {
  const requests = [];
  const account = new AccountBoundary({ fetchImpl: async (url, init) => {
    requests.push(url);
    return url === '/me' ? me(A) : { ok: false, status: 409,
      headers: { get: name => name === 'X-Account-Changed' ? '1' : null } };
  } });
  await account.check();
  await assert.rejects(account.fetchFor(A, '/sessions', { method: 'POST' }),
    error => error.reason === 'changed');
  assert.equal(account.state, 'changed');
  await assert.rejects(account.fetchFor(A, '/sessions', { method: 'POST' }),
    error => error.reason === 'changed');
  assert.deepEqual(requests, ['/me', '/me', '/sessions']);
});

test('platform login redirects become sign-in state without following the redirect', async () => {
  const requests = [];
  const account = new AccountBoundary({ fetchImpl: async (url, init) => {
    requests.push({ url, ...init });
    return { ok: false, status: 0, type: 'opaqueredirect' };
  } });
  await assert.rejects(account.check(), error => error.reason === 'required');
  assert.equal(account.state, 'required');
  assert.equal(requests[0].redirect, 'manual');
});

test('late identity checks cannot restore a page after an account switch', async () => {
  const pending = [];
  const boundary = new AccountBoundary({ fetchImpl: async url => {
    if (!pending.length && !boundary.accountId) return me(A);
    return new Promise(resolve => pending.push(resolve));
  } });
  await boundary.check();
  const first = boundary.check();
  const second = boundary.check();
  pending[0](me(B));
  await assert.rejects(first, error => error.reason === 'changed');
  pending[1](me(A));
  await assert.rejects(second, error => error.reason === 'changed');
  assert.equal(boundary.state, 'changed');
});
