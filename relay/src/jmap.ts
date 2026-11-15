import type { Email } from './types';
import { id, object, readJSON, RelayError } from './util';
export const CORE = 'urn:ietf:params:jmap:core';
export const MAIL = 'urn:ietf:params:jmap:mail';
interface Session {
  capabilities: Record<string, any>;
  primaryAccounts: Record<string, string>;
  accounts: Record<string, any>;
  apiUrl: string;
  eventSourceUrl: string;
}
export class JMAPError extends RelayError {
  constructor(public type: string, fields: string[] = []) { super(`jmap_${type}${fields.length ? '_' + fields.join('_') : ''}`); }
}
export class JMAP {
  private cached?: Session;
  constructor(private token: string) {}
  private trusted(url: string): string {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || !(parsed.hostname === 'api.fastmail.com' || parsed.hostname.endsWith('.api.fastmail.com')) || parsed.port || parsed.username || parsed.password)
      throw new RelayError('untrusted_jmap_url');
    return parsed.toString();
  }
  async session(): Promise<Session> {
    if (this.cached) return this.cached;
    const response = await fetch('https://api.fastmail.com/jmap/session', { headers: { authorization: `Bearer ${this.token}` },
      redirect: 'manual', signal: AbortSignal.timeout(15_000) });
    if (!response.ok) throw new RelayError('jmap_session_unavailable');
    const value = await readJSON(response, 1_048_576);
    if (!object(value) || !object(value.capabilities) || !value.capabilities[MAIL] || !value.capabilities[CORE] ||
      !object(value.primaryAccounts) || !id(value.primaryAccounts[MAIL]) || !object(value.accounts)) throw new RelayError('invalid_jmap_session');
    this.trusted(value.apiUrl);
    this.cached = value as unknown as Session; return this.cached;
  }
  async call(method: string, args: Record<string, unknown>, mail = true, signal?: AbortSignal): Promise<any> {
    const session = await this.session();
    const response = await fetch(this.trusted(session.apiUrl), {
      method: 'POST', headers: { authorization: `Bearer ${this.token}`, 'content-type': 'application/json' },
      redirect: 'manual', signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(20_000)]) : AbortSignal.timeout(20_000),
      body: JSON.stringify({ using: mail ? [CORE, MAIL] : [CORE], methodCalls: [[method, args, 'mailchime']] })
    });
    if (!response.ok) throw new RelayError('jmap_request_failed');
    const data = await readJSON(response, 2_097_152);
    const tuple = data?.methodResponses?.[0];
    if (!Array.isArray(tuple) || tuple[2] !== 'mailchime' || !object(tuple[1])) throw new RelayError('invalid_jmap_response');
    if (tuple[0] === 'error') {
      const allowed = ['cannotCalculateChanges', 'unknownMethod', 'forbidden', 'accountReadOnly', 'serverFail', 'invalidArguments', 'stateMismatch'];
      throw new JMAPError(allowed.includes(tuple[1].type) ? tuple[1].type : 'method_error');
    }
    if (tuple[0] !== method || (args.accountId && tuple[1].accountId !== args.accountId)) throw new RelayError('invalid_jmap_response');
    return tuple[1];
  }
  async inbox(accountId: string): Promise<string> {
    const result = await this.call('Mailbox/query', { accountId, filter: { role: 'inbox' } });
    if (!Array.isArray(result.ids) || result.ids.length !== 1 || !id(result.ids[0])) throw new RelayError('inbox_not_found');
    return result.ids[0];
  }
  async baseline(accountId: string): Promise<string> {
    const result = await this.call('Email/get', { accountId, ids: [], properties: ['id'] });
    if (typeof result.state !== 'string' || !result.state) throw new RelayError('invalid_email_state');
    return result.state;
  }
  async changes(accountId: string, sinceState: string): Promise<{ created: string[]; newState: string; hasMoreChanges: boolean }> {
    const data = await this.call('Email/changes', { accountId, sinceState, maxChanges: 100 });
    if (!Array.isArray(data.created) || data.created.length > 100 || !data.created.every(id) ||
      data.oldState !== sinceState || typeof data.newState !== 'string' || !data.newState ||
      typeof data.hasMoreChanges !== 'boolean' || (data.hasMoreChanges && data.newState === sinceState)) throw new RelayError('invalid_email_changes');
    return data;
  }
  async emails(accountId: string, ids: string[]): Promise<{ list: Email[]; notFound: string[] }> {
    if (!ids.length) return { list: [], notFound: [] };
    const result = await this.call('Email/get', { accountId, ids, properties: ['id', 'mailboxIds', 'from', 'subject', 'receivedAt'] });
    if (!Array.isArray(result.list) || !Array.isArray(result.notFound)) throw new RelayError('invalid_email_get');
    const expected = new Set(ids); const seen = new Set<string>();
    for (const e of result.list) {
      if (!object(e) || !id(e.id) || !expected.has(e.id) || seen.has(e.id) || !object(e.mailboxIds) ||
        typeof e.subject !== 'string' || typeof e.receivedAt !== 'string' || !Number.isFinite(Date.parse(e.receivedAt)) ||
        !(e.from === null || (Array.isArray(e.from) && e.from.every((a: any) => object(a) && typeof a.email === 'string' &&
          (a.name === undefined || a.name === null || typeof a.name === 'string'))))) throw new RelayError('invalid_email_get');
      seen.add(e.id);
    }
    for (const missing of result.notFound) {
      if (!expected.has(missing) || seen.has(missing)) throw new RelayError('invalid_email_get');
      seen.add(missing);
    }
    if (seen.size !== expected.size) throw new RelayError('incomplete_email_get');
    return result;
  }
  async readStatus(accountId: string, ids: string[]): Promise<{ emailId: string; state: 'read' | 'unread' | 'notFound' }[]> {
    const signal = AbortSignal.timeout(55_000);
    const session = await this.session();
    const advertised = session.capabilities[CORE]?.maxObjectsInGet;
    const limit = advertised === undefined ? 50 : advertised;
    if (!Number.isSafeInteger(limit) || limit < 1) throw new RelayError('invalid_jmap_limit');
    const results: { emailId: string; state: 'read' | 'unread' | 'notFound' }[] = [];
    for (let offset = 0; offset < ids.length; offset += Math.min(limit, 50)) {
      signal.throwIfAborted();
      const batch = ids.slice(offset, offset + Math.min(limit, 50));
      const data = await this.call('Email/get', { accountId, ids: batch, properties: ['id', 'keywords'] }, true, signal);
      if (!Array.isArray(data.list) || !Array.isArray(data.notFound)) throw new RelayError('invalid_read_status');
      const expected = new Set(batch); const seen = new Set<string>();
      for (const email of data.list) {
        if (!object(email) || !expected.has(email.id) || seen.has(email.id) || !object(email.keywords) ||
          !Object.entries(email.keywords).every(([key, value]) => key.length > 0 && value === true)) throw new RelayError('invalid_read_status');
        seen.add(email.id);
        results.push({ emailId: email.id, state: email.keywords.$seen === true ? 'read' : 'unread' });
      }
      for (const emailId of data.notFound) {
        if (!expected.has(emailId) || seen.has(emailId)) throw new RelayError('invalid_read_status');
        seen.add(emailId); results.push({ emailId, state: 'notFound' });
      }
      if (seen.size !== expected.size) throw new RelayError('incomplete_read_status');
    }
    return results;
  }
  private checkSet(result: any, operation: 'created' | 'updated' | 'destroyed', key: string): any {
    if (operation === 'destroyed' ? result.destroyed?.includes(key) : object(result[operation]) && key in result[operation]) return result[operation][key];
    const failure = result[{ created: 'notCreated', updated: 'notUpdated', destroyed: 'notDestroyed' }[operation]]?.[key];
    const error = failure?.type;
    const fields = Array.isArray(failure?.properties) ? failure.properties.filter((field: unknown) =>
      ['keys', 'url', 'expires', 'types', 'verificationCode', 'deviceClientId'].includes(String(field))) : [];
    throw new JMAPError(['forbidden', 'invalidProperties', 'notFound', 'accountReadOnly'].includes(error) ? error : 'subscription_rejected', fields);
  }
  async subscribe(deviceClientId: string, url: string, expires: string, keys: { p256dh: string; auth: string }): Promise<{ id: string; expires: string }> {
    const result = await this.call('PushSubscription/set', { create: { relay: {
      deviceClientId, url, types: ['Email'], expires, keys
    } } }, false);
    const created = this.checkSet(result, 'created', 'relay');
    if (!id(created?.id) || !Number.isFinite(Date.parse(created.expires))) throw new RelayError('invalid_subscription');
    return created;
  }
  async updateSubscription(subscriptionId: string, update: Record<string, string>): Promise<void> {
    const result = await this.call('PushSubscription/set', { update: { [subscriptionId]: update } }, false);
    this.checkSet(result, 'updated', subscriptionId);
  }
  async removeSubscription(subscriptionId: string): Promise<void> {
    const result = await this.call('PushSubscription/set', { destroy: [subscriptionId] }, false);
    this.checkSet(result, 'destroyed', subscriptionId);
  }
  async scopeProbe(): Promise<{ mail: boolean; capabilities: string[]; readOnly: 'confirmed' | 'unverified' }> {
    const session = await this.session();
    // An empty set has no mailbox side effects. Some providers reject it for read-only tokens;
    // others allow no-ops, so success cannot establish write access or read-only scope.
    let readOnly: 'confirmed' | 'unverified' = 'unverified';
    try { await this.call('Email/set', { accountId: session.primaryAccounts[MAIL], update: {} }); }
    catch (error) { if (error instanceof JMAPError && ['forbidden', 'accountReadOnly'].includes(error.type)) readOnly = 'confirmed'; else throw error; }
    return { mail: true, capabilities: Object.keys(session.capabilities), readOnly };
  }
  async events(signal: AbortSignal): Promise<Response> {
    const session = await this.session();
    const url = session.eventSourceUrl.replace('{types}', 'Email').replace('{closeafter}', 'no').replace('{ping}', '60');
    const response = await fetch(this.trusted(url), { headers: { authorization: `Bearer ${this.token}`, accept: 'text/event-stream' },
      signal, redirect: 'manual' });
    if (!response.ok || !response.headers.get('content-type')?.includes('text/event-stream')) throw new RelayError('eventsource_unavailable');
    return response;
  }
}
