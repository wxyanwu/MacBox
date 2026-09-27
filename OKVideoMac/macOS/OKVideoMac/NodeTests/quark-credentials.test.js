'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createQuarkCredentialCoordinator } = require('../Resources/NodePatches/catpaw-quark-transfer-lifecycle.js');
function fixture() {
  let stored = '__uid=a; __puus=old';
  const store = createQuarkCredentialCoordinator({
    read: async () => stored,
    compareAndSet: async (old, next) => {
      if (stored !== old) return false;
      stored = next; return true;
    }
  });
  return { store, read: () => stored, set: (value) => { stored = value; } };
}
const response = (value) => ({ 'set-cookie': [`__puus=${value}; Path=/; HttpOnly; Expires=Wed, 21 Oct 2030 07:28:00 GMT`] });
test('rotation persists and old in-flight account snapshots resolve to latest cookie', async () => {
  const f = fixture(), ticket = await f.store.begin();
  assert.equal(await f.store.rotate(ticket, response('new')), true);
  assert.equal(f.read(), '__uid=a; __puus=new');
  assert.equal((await f.store.begin(ticket.cookie)).cookie, f.read());
  assert.equal(await f.store.rotate(ticket, response('stale')), false);
  assert.equal(f.read(), '__uid=a; __puus=new');
});
test('manual reauthorization for same account invalidates old response and snapshot', async () => {
  const f = fixture(), ticket = await f.store.begin();
  f.set('__uid=a; __puus=manual');
  assert.equal(await f.store.rotate(ticket, response('late')), false);
  await assert.rejects(f.store.begin(ticket.cookie), { code: 'OKVIDEO_ACCOUNT_CHANGED' });
  assert.equal(f.read(), '__uid=a; __puus=manual');
});
test('account switch or removal cannot be overwritten by late server rotation', async () => {
  for (const value of ['__uid=b; __puus=other', '']) {
    const f = fixture(), ticket = await f.store.begin(); f.set(value);
    assert.equal(await f.store.rotate(ticket, response('late')), false);
    assert.equal(f.read(), value);
  }
});
test('malformed, ambiguous, deletion and unrelated cookies do not mutate authorization', async () => {
  for (const headers of [{}, response(''), response('bad\r\nvalue'),
    { 'set-cookie': ['__puus=x; Max-Age=0'] },
    { 'set-cookie': ['__uid=b', 'token=secret'] },
    { 'set-cookie': ['__puus=x', '__puus=y'] }]) {
    const f = fixture(), ticket = await f.store.begin();
    assert.equal(await f.store.rotate(ticket, headers), false);
    assert.equal(f.read(), ticket.cookie);
  }
});
test('parallel responses cannot roll back a newer committed credential', async () => {
  const f = fixture(), ticket = await f.store.begin();
  const results = await Promise.all([f.store.rotate(ticket, response('one')), f.store.rotate(ticket, response('two'))]);
  assert.deepEqual(results, [true, false]);
  assert.equal(f.read(), '__uid=a; __puus=one');
  assert.equal(JSON.stringify(f.store.snapshot()).includes('__puus'), false);
});
test('recreated coordinator reads persisted credential without old in-memory state', async () => {
  const f = fixture(); await f.store.rotate(await f.store.begin(), response('persisted'));
  const restored = createQuarkCredentialCoordinator({ read: async () => f.read(), compareAndSet: async () => false });
  assert.equal((await restored.begin()).cookie, '__uid=a; __puus=persisted');
});
