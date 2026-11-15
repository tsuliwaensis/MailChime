import { env, runInDurableObject } from 'cloudflare:test';
import { fetchMock } from './network';
import type { Env, Email, RelayState } from '../src/types';
import { CORE, MAIL } from '../src/jmap';
import type { MailboxRelay } from '../src/relay';
export const bindings = env as unknown as Env;
export const accountId = 'account';
export const key = btoa('k'.repeat(32));
export const device = { deviceId: 'mac-1', apnsToken: 'a'.repeat(64), environment: 'sandbox', timeZone: 'America/Chicago', payloadKey: key };
export function email(id: string, inbox = true): Email {
  return { id, mailboxIds: { [inbox ? 'inbox' : 'archive']: true }, from: [{ name: 'Private Sender', email: 'sender@example.com' }],
    subject: 'Private Subject', receivedAt: '2026-11-03T12:00:00Z' };
}
export function stub() { return bindings.MAILBOX_RELAY.get(bindings.MAILBOX_RELAY.newUniqueId()); }
export async function state(target: DurableObjectStub<MailboxRelay>): Promise<RelayState> {
  return runInDurableObject(target, (_instance, ctx) => JSON.parse(ctx.storage.sql.exec<{ value: string }>('SELECT value FROM relay_state WHERE id = 1').one().value));
}
export async function seed(target: DurableObjectStub<MailboxRelay>, changes: Partial<RelayState>) {
  await runInDurableObject(target, (instance, _ctx) => {
    const relay = instance as unknown as { data: RelayState; save(): void };
    Object.assign(relay.data, changes); relay.save();
  });
}
export function call(target: DurableObjectStub<MailboxRelay>, path: string, body?: unknown) {
  return target.fetch(`https://relay.test${path}`, body === undefined ? undefined : {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body)
  });
}
export function mockJMAP(handlers: Record<string, (args: any) => any> = {}, maxObjectsInGet?: number) {
  const calls: { method: string; args: any }[] = [];
  fetchMock.get('https://api.fastmail.com').intercept({ path: '/jmap/session' }).reply(200, {
    capabilities: { [CORE]: maxObjectsInGet === undefined ? {} : { maxObjectsInGet }, [MAIL]: {} }, primaryAccounts: { [MAIL]: accountId }, accounts: { [accountId]: {} },
    apiUrl: 'https://api.fastmail.com/jmap/api/', eventSourceUrl: 'https://api.fastmail.com/jmap/event?types={types}&closeafter={closeafter}&ping={ping}'
  }).persist();
  fetchMock.get('https://api.fastmail.com').intercept({ path: '/jmap/event?types=Email&closeafter=no&ping=60' })
    .reply(200, '', { headers: { 'content-type': 'text/event-stream' } }).persist();
  fetchMock.get('https://api.fastmail.com').intercept({ path: '/jmap/api/', method: 'POST' }).reply(options => {
    const [method, args, tag] = JSON.parse(options.body as string).methodCalls[0];
    calls.push({ method, args });
    const defaults: Record<string, any> = {
      'Mailbox/query': { accountId, ids: ['inbox'] },
      'Email/get': { accountId, state: 's0', list: args.ids?.map((id: string) => email(id)) ?? [], notFound: [] },
      'Email/changes': { accountId, oldState: args.sinceState, newState: args.sinceState, hasMoreChanges: false, created: [] },
      'Email/set': { accountId, updated: {} },
      'PushSubscription/set': args.create ? { created: { relay: { id: 'subscription', expires: new Date(Date.now() + 7 * 86_400_000).toISOString() } } } :
        args.update ? { updated: Object.fromEntries(Object.keys(args.update).map(k => [k, null])) } : { destroyed: args.destroy },
      'PushSubscription/get': { list: [{ id: 'subscription', expires: new Date(Date.now() + 7 * 86_400_000).toISOString() }] }
    };
    const result = handlers[method]?.(args) ?? defaults[method];
    return { statusCode: 200, data: JSON.stringify({ methodResponses: [[result?.error ? 'error' : method, result?.error ?? result, tag]] }) };
  }).persist();
  return calls;
}
export function mockAPNs(status = 200, reason?: string, persist = true) {
  const requests: any[] = [];
  const scope = fetchMock.get('https://api.sandbox.push.apple.com').intercept({ path: /\/3\/device\/[a-f0-9]+/, method: 'POST' })
    .reply(options => { requests.push({ body: JSON.parse(options.body as string), headers: options.headers });
      return { statusCode: status, data: reason ? JSON.stringify({ reason }) : '' }; });
  if (persist) scope.persist();
  return requests;
}
