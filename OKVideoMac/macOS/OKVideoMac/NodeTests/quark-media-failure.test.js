'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createQuarkMediaFailureStore } = require('../Resources/NodePatches/catpaw-quark-transfer-lifecycle.js');
const id = '11111111-1111-4111-8111-111111111111';
const request = (generation = 1) => ({ query: { __okvideo_playback_request: id, __okvideo_playback_generation: generation } });
const response = (status = 412, host = 'dl-pc-sz.drive.quark.cn') => ({ status,
  config: { url: `https://${host}/secret-path?token=secret` },
  headers: { 'content-type': 'text/html', 'set-cookie': 'secret' }, data: 'private' });
test('CDN failure is bounded, request scoped, consumable once and contains no secrets', () => {
  const store = createQuarkMediaFailureStore(); store.record(request(), response());
  assert.equal(store.consume(request(2)), null);
  const event = store.consume(request());
  assert.equal(event.status, 412); assert.equal(event.provider, 'quark');
  assert.equal(JSON.stringify(event).includes('secret'), false);
  assert.equal(store.consume(request()), null);
});
test('account API, foreign CDN, malformed identity and successful video are ignored', () => {
  const store = createQuarkMediaFailureStore();
  for (const host of ['drive.quark.cn', 'dl-pc-sz.drive.quark.cn.evil.invalid', 'other.invalid']) store.record(request(), response(403, host));
  store.record({}, response());
  store.record(request(), { ...response(206), headers: { 'content-type': 'video/mp4' } });
  assert.equal(store.consume(request()), null);
});
test('old evidence expires and real media failure wins over probe evidence', () => {
  let now = 0; const store = createQuarkMediaFailureStore(() => now);
  store.record(request(), response(403), 'media'); store.record(request(), response(412), 'probe');
  assert.equal(store.consume(request()).status, 403);
  store.record(request(), response()); now = 30001;
  assert.equal(store.consume(request()), null);
});
test('starting a fresh resolution clears old evidence without clearing another request', () => {
  const store = createQuarkMediaFailureStore();
  store.record(request(), response()); store.record(request(2), response());
  store.clear(request()); assert.equal(store.consume(request()), null);
  assert.equal(store.consume(request(2)).status, 412);
});
