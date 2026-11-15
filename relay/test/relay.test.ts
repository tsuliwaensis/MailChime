import { beforeEach, afterEach, it, expect } from 'vitest';
import { runDurableObjectAlarm, runInDurableObject, SELF, reset } from 'cloudflare:test';
import { fetchMock } from './network';
import { accountId, bindings, call, device, email, mockAPNs, mockJMAP, seed, state, stub } from './helpers';
import { JMAP } from '../src/jmap';
beforeEach(() => { fetchMock.activate(); fetchMock.disableNetConnect(); });
afterEach(async () => { await reset(); fetchMock.deactivate(); });
async function register(target: ReturnType<typeof stub>) {
  const r = await call(target, '/devices', device); expect(r.status).toBe(201);
  await call(target, '/jmap/push/secret', { '@type': 'PushVerification', pushSubscriptionId: 'subscription', verificationCode: 'code' });
}
async function change(target: ReturnType<typeof stub>) {
  return call(target, '/jmap/push/secret', { '@type': 'StateChange', changed: { [accountId]: { Email: 'wake' } } });
}
it('protects routes and hides bad push paths', async () => {
  expect((await SELF.fetch('https://relay.test/health')).status).toBe(200);
  for (const path of ['/devices', '/missed', '/ack', '/test', '/status', '/probe', '/read-status']) {
    expect((await SELF.fetch(`https://relay.test${path}`, { headers: { authorization: 'Bearer wrong' } })).status).toBe(401);
  }
  expect((await SELF.fetch('https://relay.test/jmap/push/wrong', { method: 'POST' })).status).toBe(404);
  expect((await SELF.fetch('https://relay.test/internal/tick', { method: 'POST' })).status).toBe(404);
  expect((await SELF.fetch('https://relay.test/status', { headers: { authorization: `Bearer ${bindings.DEVICE_SECRET}` } })).status).toBe(200);
  expect((await SELF.fetch('https://relay.test/status', { method: 'POST', headers: { authorization: `Bearer ${bindings.DEVICE_SECRET}` } })).status).toBe(405);
});
it('baselines without pushing existing mail and completes subscription verification', async () => {
  const calls = mockJMAP(); const sent = mockAPNs(); const target = stub(); await register(target);
  const stored = await state(target); expect(stored.emailState).toBe('s0'); expect(stored.queue).toEqual([]);
  expect(stored.subscription?.verified).toBe(true); expect(stored.pushMode).toBe('subscription'); expect(sent).toHaveLength(0);
  expect(calls.find(c => c.method === 'Email/get')?.args.ids).toEqual([]);
});
it('pages changes, ignores non-Inbox and updated-only mail, and sends each created Inbox email once', async () => {
  mockJMAP({ 'Email/changes': args => ({ accountId, oldState: args.sinceState, newState: args.sinceState === 's0' ? 's1' : 's2',
    hasMoreChanges: args.sinceState === 's0', created: args.sinceState === 's0' ? ['m1', 'archive'] : args.sinceState === 's1' ? ['m2'] : [], updated: ['old'] }),
  'Email/get': args => ({ accountId, state: 's0', list: args.ids.map((id: string) => email(id, id !== 'archive')), notFound: [] }) });
  const sent = mockAPNs(); const target = stub(); await register(target); expect((await change(target)).status).toBe(200);
  expect(sent.map(s => s.body.emailId)).toEqual(['m1', 'm2']);
  expect((await state(target)).queue.map(q => q.seq)).toEqual([1, 2]);
  await change(target); expect(sent).toHaveLength(2);
  expect(JSON.stringify(await state(target))).not.toMatch(/Private Subject|Private Sender|sender@example.com/);
});
it('re-baselines cannotCalculateChanges without historical notifications', async () => {
  mockJMAP({ 'Email/changes': () => ({ error: { type: 'cannotCalculateChanges' } }) });
  const sent = mockAPNs(); const target = stub(); await register(target); await change(target);
  expect((await state(target)).queue).toHaveLength(0); expect(sent).toHaveLength(0);
});
it('preserves checkpoint when Email/get is incomplete and recovers the same message', async () => {
  let broken = true;
  mockJMAP({ 'Email/changes': args => ({ accountId, oldState: args.sinceState, newState: 's1', hasMoreChanges: false, created: ['m1'] }),
    'Email/get': args => ({ accountId, state: 's0', list: broken ? [] : args.ids.map((id: string) => email(id)), notFound: [] }) });
  const sent = mockAPNs(); const target = stub(); await register(target);
  expect((await change(target)).status).toBe(502); expect((await state(target)).emailState).toBe('s0');
  broken = false; await change(target); expect(sent).toHaveLength(1); expect((await state(target)).emailState).toBe('s1');
});
it('serializes simultaneous StateChange callbacks without duplicate sequences or pushes', async () => {
  mockJMAP({ 'Email/changes': args => ({ accountId, oldState: args.sinceState, newState: 's1', hasMoreChanges: false, created: args.sinceState === 's0' ? ['m1'] : [] }) });
  const sent = mockAPNs(); const target = stub(); await register(target);
  await Promise.all([change(target), change(target), change(target)]);
  expect(sent).toHaveLength(1); expect((await state(target)).nextSeq).toBe(2);
});
it('missed mail is encrypted, ack is bounded by offered cursor, and replacements invalidate the old device', async () => {
  mockJMAP(); const target = stub(); await register(target);
  await seed(target, { nextSeq: 3, queue: [1, 2].map(seq => ({ seq, emailId: `m${seq}`, queuedAt: Date.now(), sent: true, attempts: 0, retryAt: 0 })) });
  expect((await call(target, '/ack', { deviceId: device.deviceId, seq: 2 })).status).toBe(400);
  const missed = await (await call(target, '/missed?deviceId=mac-1&after=0')).json() as any;
  expect(missed.messages).toHaveLength(2); expect(missed.nextCursor).toBe(2); expect(JSON.stringify(missed)).not.toContain('Private');
  expect((await call(target, '/ack', { deviceId: device.deviceId, seq: 1 })).status).toBe(200);
  expect((await state(target)).queue.map(q => q.seq)).toEqual([2]);
  await call(target, '/devices', { ...device, deviceId: 'mac-2' });
  expect((await call(target, '/missed?deviceId=mac-1&after=0')).status).toBe(409);
  expect((await call(target, '/ack', { deviceId: 'mac-1', seq: 2 })).status).toBe(409);
  expect((await state(target)).device?.deviceId).toBe('mac-2');
});
it('preserves ack across token/key refresh for the same device and rejects malformed registration', async () => {
  mockJMAP(); const target = stub(); await register(target);
  const stored = await state(target); stored.device!.lastAckedSeq = 7;
  await seed(target, { nextSeq: 8, device: stored.device });
  await call(target, '/devices', { ...device, apnsToken: 'b'.repeat(64) });
  expect((await state(target)).device?.lastAckedSeq).toBe(7);
  expect((await call(target, '/devices', { ...device, payloadKey: 'bad' })).status).toBe(400);
  expect((await call(target, '/devices', { ...device, environment: 'development' })).status).toBe(400);
  expect((await call(target, '/devices', { ...device, timeZone: 'bad-zone' })).status).toBe(400);
});
it('reports retention gaps and advances past deleted messages without plaintext or stuck cursors', async () => {
  mockJMAP({ 'Email/get': args => ({ accountId, state: 's0', list: [], notFound: args.ids }) });
  const target = stub(); await register(target);
  await seed(target, { nextSeq: 3, queue: [
    { seq: 1, emailId: 'expired', queuedAt: Date.now() - 8 * 86_400_000, sent: true, attempts: 0, retryAt: 0 },
    { seq: 2, emailId: 'deleted', queuedAt: Date.now(), sent: true, attempts: 0, retryAt: 0 }
  ] });
  const result = await (await call(target, '/missed?deviceId=mac-1&after=0')).json() as any;
  expect(result.messages).toEqual([]); expect(result.gap).toBe(true); expect(result.droppedThrough).toBe(1); expect(result.nextCursor).toBe(2);
  await call(target, '/ack', { deviceId: 'mac-1', seq: 2 }); expect((await state(target)).queue).toHaveLength(0);
});
it('bounds queue at 1000 entries and paginates missed responses', async () => {
  mockJMAP(); const target = stub(); await register(target);
  await seed(target, { nextSeq: 1003, queue: Array.from({ length: 1002 }, (_, i) => ({ seq: i + 1, emailId: `m${i}`, queuedAt: Date.now(), sent: true, attempts: 0, retryAt: 0 })) });
  const result = await (await call(target, '/missed?deviceId=mac-1&after=0')).json() as any;
  expect((await state(target)).queue).toHaveLength(1000); expect(result.messages).toHaveLength(50); expect(result.hasMore).toBe(true); expect(result.droppedThrough).toBe(2);
});
it.each([[410, 'Unregistered'], [400, 'BadDeviceToken']])('removes device on APNs %s while retaining catch-up entries', async (status, reason) => {
  mockJMAP({ 'Email/changes': args => ({ accountId, oldState: args.sinceState, newState: 's1', hasMoreChanges: false, created: ['m1'] }) });
  mockAPNs(Number(status), String(reason)); const target = stub(); await register(target); await change(target);
  const stored = await state(target); expect(stored.device).toBeUndefined(); expect(stored.queue).toHaveLength(1); expect(stored.queue[0].sent).toBe(false);
});
it('persists transient APNs retry state and retries via alarm', async () => {
  mockJMAP({ 'Email/changes': args => ({ accountId, oldState: args.sinceState, newState: 's1', hasMoreChanges: false, created: args.sinceState === 's0' ? ['m1'] : [] }) });
  mockAPNs(429, 'TooManyRequests', false); const sent = mockAPNs(); const target = stub(); await register(target); await change(target);
  const stored = await state(target); expect(stored.queue[0].attempts).toBe(1); expect(stored.queue[0].retryAt).toBeGreaterThan(Date.now());
  stored.queue[0].retryAt = Date.now() - 1; await seed(target, { queue: stored.queue });
  expect(await runDurableObjectAlarm(target)).toBe(true); expect(sent).toHaveLength(1); expect((await state(target)).queue[0].sent).toBe(true);
});
it('falls back to EventSource when subscriptions are unsupported and keeps reconcile available', async () => {
  mockJMAP({ 'PushSubscription/set': () => ({ error: { type: 'unknownMethod' } }) });
  const target = stub(); expect((await call(target, '/devices', device)).status).toBe(201);
  expect((await state(target)).pushMode).toBe('eventsource'); expect((await state(target)).emailState).toBe('s0');
});
it('renews a verified subscription before expiration', async () => {
  const calls = mockJMAP(); const target = stub(); await register(target);
  await seed(target, { subscription: { id: 'subscription', expires: Date.now() + 60_000, verified: true, createdAt: 0, deviceClientId: bindings.JMAP_DEVICE_CLIENT_ID, callbackURL: `${bindings.RELAY_URL}/jmap/push/${bindings.PUSH_PATH_SECRET}` }, subscriptionRetryAt: 0 });
  await runDurableObjectAlarm(target);
  expect(calls.some(c => c.method === 'PushSubscription/set' && c.args.update?.subscription?.expires)).toBe(true);
  expect((await state(target)).subscription!.expires).toBeGreaterThan(Date.now() + 86_400_000);
});
it('probe leaves an existing registration intact and accurately reports unverified scope/missing APNs token', async () => {
  mockJMAP(); const target = stub(); await register(target);
  const response = await (await call(target, '/probe', {})).json() as any;
  expect(response.scope.readOnly).toBe('unverified'); expect(response.apns.status).toBe('pending_device_token');
  expect((await state(target)).device?.deviceId).toBe('mac-1');
});
it('rejects oversized, malformed, and wrong-subscription requests without mutating registration', async () => {
  mockJMAP(); const target = stub(); await register(target);
  expect((await call(target, '/ack', { deviceId: 'mac-1', seq: -1 })).status).toBe(400);
  expect((await call(target, '/missed?deviceId=mac-1&after=-1')).status).toBe(400);
  expect((await call(target, '/devices', { ...device, appVersion: 'x'.repeat(20_000) })).status).toBe(413);
  expect((await call(target, '/jmap/push/secret', { '@type': 'PushVerification', pushSubscriptionId: 'other', verificationCode: 'code' })).status).toBe(400);
});
it('recognizes explicit read-only denial without changing any messages', async () => {
  const calls = mockJMAP({ 'Email/set': () => ({ error: { type: 'forbidden' } }) });
  const result = await new JMAP('fake').scopeProbe(); expect(result.readOnly).toBe('confirmed');
  expect(calls.find(c => c.method === 'Email/set')?.args.update).toEqual({});
});
it('restores durable queue, checkpoint, device and JWT after a runtime restart', async () => {
  const { abortAllDurableObjects } = await import('cloudflare:test');
  mockJMAP({ 'Email/changes': args => ({ accountId, oldState: args.sinceState, newState: 's1', hasMoreChanges: false, created: args.sinceState === 's0' ? ['m1'] : [] }) });
  const sent = mockAPNs(); const target = stub(); await register(target); await change(target);
  const before = await state(target); await abortAllDurableObjects();
  const restarted = bindings.MAILBOX_RELAY.get(target.id);
  expect(await state(restarted)).toEqual(before); await change(restarted); expect(sent).toHaveLength(1);
});
it('posts an encrypted synthetic test without consuming a mail sequence', async () => {
  mockJMAP(); const sent = mockAPNs(); const target = stub(); await register(target);
  const result = await (await call(target, '/test', { deviceId: 'mac-1' })).json() as any;
  expect(result.kind).toBe('sent'); expect(sent[0].body.test).toBe(true); expect(sent[0].body.enc).toBeDefined();
  expect(JSON.stringify(sent[0].body)).not.toContain('Test notification'); expect((await state(target)).nextSeq).toBe(1);
});
it('does not advance the missed cursor on incomplete fetch results', async () => {
  mockJMAP({ 'Email/get': () => ({ accountId, state: 's0', list: [], notFound: [] }) });
  const target = stub(); await register(target);
  await seed(target, { nextSeq: 2, queue: [{ seq: 1, emailId: 'm1', queuedAt: Date.now(), sent: true, attempts: 0, retryAt: 0 }] });
  expect((await call(target, '/missed?deviceId=mac-1&after=0')).status).toBe(502);
  expect((await state(target)).device?.offeredSeq).toBe(0);
});
it('uses EventSource state changes to reconcile new messages', async () => {
  // Put a one-shot event frame ahead of the default empty stream fixture.
  fetchMock.get('https://api.fastmail.com').intercept({ path: '/jmap/event?types=Email&closeafter=no&ping=60' }).reply(200,
    `event: state\ndata: ${JSON.stringify({ '@type': 'StateChange', changed: { [accountId]: { Email: 's1' } } })}\n\n`,
    { headers: { 'content-type': 'text/event-stream' } });
  mockJMAP({ 'PushSubscription/set': () => ({ error: { type: 'unknownMethod' } }),
    'Email/changes': args => ({ accountId, oldState: args.sinceState, newState: 's1', hasMoreChanges: false, created: args.sinceState === 's0' ? ['m1'] : [] }) });
  const sent = mockAPNs(); const target = stub(); await call(target, '/devices', device);
  await expect.poll(async () => (await state(target)).emailState).toBe('s1');
  expect(sent).toHaveLength(1);
});
it('accepts Fastmail regional API hosts discovered through its trusted session endpoint', async () => {
  fetchMock.get('https://api.fastmail.com').intercept({ path: '/jmap/session' }).reply(200, {
    capabilities: { 'urn:ietf:params:jmap:core': {}, 'urn:ietf:params:jmap:mail': {} },
    primaryAccounts: { 'urn:ietf:params:jmap:mail': accountId }, accounts: { [accountId]: {} },
    apiUrl: 'https://phl.api.fastmail.com/jmap/api/', eventSourceUrl: 'https://phl.api.fastmail.com/jmap/event/'
  });
  fetchMock.get('https://phl.api.fastmail.com').intercept({ path: '/jmap/api/', method: 'POST' }).reply(200, {
    methodResponses: [['Email/get', { accountId, state: 'regional', list: [], notFound: [] }, 'mailchime']]
  });
  expect(await new JMAP('fake').baseline(accountId)).toBe('regional');
});
it('does not forward the Fastmail bearer token to an untrusted session-provided host', async () => {
  fetchMock.get('https://api.fastmail.com').intercept({ path: '/jmap/session' }).reply(200, {
    capabilities: { 'urn:ietf:params:jmap:core': {}, 'urn:ietf:params:jmap:mail': {} },
    primaryAccounts: { 'urn:ietf:params:jmap:mail': accountId }, accounts: { [accountId]: {} },
    apiUrl: 'https://api.fastmail.com.attacker.invalid/jmap/api/'
  });
  await expect(new JMAP('fake').session()).rejects.toThrow('untrusted_jmap_url');
});
it('reads only keywords, distinguishes missing mail, and preserves delivery state', async () => {
  const calls = mockJMAP({ 'Email/get': args => ({ accountId, state: 's0',
    list: args.ids.filter((id: string) => id !== 'missing').map((id: string) => ({ id, keywords: id === 'read' ? { $seen: true } : {} })),
    notFound: args.ids.includes('missing') ? ['missing'] : [] }) });
  const target = stub(); await register(target); const before = await state(target);
  const response = await call(target, '/read-status', { deviceId: device.deviceId, emailIds: ['read', 'unread', 'missing'] });
  expect(response.status).toBe(200);
  expect((await response.json() as any).results).toEqual([
    { emailId: 'read', state: 'read' }, { emailId: 'unread', state: 'unread' }, { emailId: 'missing', state: 'notFound' }
  ]);
  expect(calls.at(-1)?.args.properties).toEqual(['id', 'keywords']);
  expect(await state(target)).toEqual(before);
});
it('rejects invalid read requests and replaced devices before JMAP', async () => {
  const calls = mockJMAP(); const target = stub(); await register(target); const count = calls.length;
  for (const emailIds of [[], ['a', 'a'], ['bad/id'], Array.from({ length: 51 }, (_, i) => `m${i}`)]) {
    expect((await call(target, '/read-status', { deviceId: device.deviceId, emailIds })).status).toBe(400);
  }
  expect((await call(target, '/read-status', { deviceId: 'wrong', emailIds: ['a'] })).status).toBe(409);
  expect(calls).toHaveLength(count);
});
it.each([
  { list: [{ id: 'a' }], notFound: [] },
  { list: [{ id: 'a', keywords: { $seen: false } }], notFound: [] },
  { list: [], notFound: [] },
  { list: [{ id: 'unexpected', keywords: { $seen: true } }], notFound: [] },
  { list: [{ id: 'a', keywords: {} }, { id: 'a', keywords: {} }], notFound: [] },
  { list: [{ id: 'a', keywords: {} }], notFound: ['a'] },
])('rejects malformed read results %#', async (result) => {
  mockJMAP({ 'Email/get': args => args.ids.length ? { accountId, ...result } : { accountId, state: 's0', list: [], notFound: [] } });
  const target = stub(); await register(target);
  expect((await call(target, '/read-status', { deviceId: device.deviceId, emailIds: ['a'] })).status).toBe(502);
});
it('throttles read requests independently of status and ack', async () => {
  mockJMAP({ 'Email/get': args => ({ accountId, state: 's0', list: args.ids.map((id: string) => ({ id, keywords: {} })), notFound: [] }) });
  const target = stub(); await register(target);
  for (let i = 0; i < 8; i++) expect((await call(target, '/read-status', { deviceId: device.deviceId, emailIds: ['a'] })).status).toBe(200);
  expect((await call(target, '/read-status', { deviceId: device.deviceId, emailIds: ['a'] })).status).toBe(429);
  expect((await call(target, '/status')).status).toBe(200);
});
it('honors a lower JMAP get limit', async () => {
  const calls = mockJMAP({ 'Email/get': args => ({ accountId, state: 's0', list: args.ids.map((id: string) => ({ id, keywords: {} })), notFound: [] }) }, 1);
  const target = stub(); await register(target);
  expect((await call(target, '/read-status', { deviceId: device.deviceId, emailIds: ['a', 'b'] })).status).toBe(200);
  expect(calls.filter(c => c.method === 'Email/get' && c.args.ids.length).map(c => c.args.ids)).toEqual([['a'], ['b']]);
});
it('rejects wrong-account read results and oversized bodies', async () => {
  mockJMAP({ 'Email/get': args => ({ accountId: args.ids.length ? 'wrong' : accountId, state: 's0', list: args.ids.map((id: string) => ({ id, keywords: {} })), notFound: [] }) });
  const target = stub(); await register(target);
  expect((await call(target, '/read-status', { deviceId: device.deviceId, emailIds: ['a'] })).status).toBe(502);
  expect((await call(target, '/read-status', { deviceId: device.deviceId, emailIds: ['a'], padding: 'x'.repeat(17000) })).status).toBe(413);
});
it.each(['legacy', 'callback', 'client'])('replaces a %s subscription when identity or origin changes', async mode => {
  const calls = mockJMAP(); const target = stub(); await register(target);
  const previous = (await state(target)).subscription!;
  await seed(target, { subscription: { ...previous,
    deviceClientId: mode === 'legacy' ? undefined : mode === 'client' ? 'prior-client' : bindings.JMAP_DEVICE_CLIENT_ID,
    callbackURL: mode === 'legacy' ? undefined : mode === 'callback' ? 'https://previous.example/callback' : previous.callbackURL
  }, subscriptionRetryAt: 0 });
  calls.length = 0;
  await runDurableObjectAlarm(target);
  const sets = calls.filter(c => c.method === 'PushSubscription/set');
  expect(sets[0]?.args.destroy).toEqual([previous.id]);
  expect(sets[1]?.args.create.relay.deviceClientId).toBe(bindings.JMAP_DEVICE_CLIENT_ID);
  expect(sets[1]?.args.create.relay.url).toBe(`${bindings.RELAY_URL}/jmap/push/${bindings.PUSH_PATH_SECRET}`);
  expect((await state(target)).subscription?.verified).toBe(false);
  await call(target, '/jmap/push/secret', { '@type': 'PushVerification', pushSubscriptionId: 'subscription', verificationCode: 'code' });
  expect((await state(target)).subscription?.verified).toBe(true);
});
it('preserves a stale subscription when its deletion fails', async () => {
  let reject = false;
  mockJMAP({ 'PushSubscription/set': args => args.destroy && reject ? { error: { type: 'serverFail' } } : undefined });
  const target = stub(); await register(target);
  const subscription = { ...(await state(target)).subscription!, deviceClientId: 'prior-client' };
  await seed(target, { subscription, subscriptionRetryAt: 0 }); reject = true;
  await runDurableObjectAlarm(target);
  expect((await state(target)).subscription).toEqual(subscription);
  expect((await state(target)).subscriptionRetryAt).toBeGreaterThan(Date.now());
});

it.each(['', 'invalid value'])('does not destroy a subscription with invalid client configuration %s', async clientId => {
  const calls = mockJMAP(); const target = stub(); await register(target);
  const previous = (await state(target)).subscription;
  calls.length = 0;
  await runInDurableObject(target, async instance => {
    const relay = instance as unknown as { env: { JMAP_DEVICE_CLIENT_ID: string }; maintainSubscription(): Promise<void> };
    const saved = relay.env.JMAP_DEVICE_CLIENT_ID;
    try { relay.env.JMAP_DEVICE_CLIENT_ID = clientId; await relay.maintainSubscription(); }
    finally { relay.env.JMAP_DEVICE_CLIENT_ID = saved; }
  });
  expect(calls.filter(c => c.method === 'PushSubscription/set')).toHaveLength(0);
  expect((await state(target)).subscription).toEqual(previous);
  expect((await state(target)).lastError).toBe('invalid_device_client_id');
});
