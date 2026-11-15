import { DurableObject } from 'cloudflare:workers';
import { APNs } from './apns';
import { JMAP, JMAPError, MAIL } from './jmap';
import { payload } from './payload';
import { createWebPushKeys, pushJSON } from './webpush';
import type { Device, Email, Env, RelayState } from './types';
import { id, json, object, readJSON, RelayError, safeError, sequence, unbase64 } from './util';
const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
export class MailboxRelay extends DurableObject<Env> {
  private data!: RelayState;
  private readRequests: number[] = [];
  private tail: Promise<unknown> = Promise.resolve();
  private jmap: JMAP;
  private apns: APNs;
  private stream?: { controller: AbortController; started: number };
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS relay_state (id INTEGER PRIMARY KEY CHECK (id = 1), value TEXT NOT NULL)');
    const rows = ctx.storage.sql.exec<{ value: string }>('SELECT value FROM relay_state WHERE id = 1').toArray();
    this.data = rows.length ? JSON.parse(rows[0].value) : {
      version: 1, nextSeq: 1, droppedThrough: 0, queue: [], pushMode: 'pending', subscriptionRetryAt: 0
    };
    this.jmap = new JMAP(env.FASTMAIL_API_TOKEN);
    this.apns = new APNs(env, () => this.data.providerToken, token => { this.data.providerToken = token; this.save(); });
  }
  private save() {
    // One SQLite statement atomically commits the checkpoint and queue, without the KV value-size limit.
    this.ctx.storage.sql.exec('INSERT INTO relay_state (id, value) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET value = excluded.value', JSON.stringify(this.data));
  }
  private serial<T>(operation: () => Promise<T>): Promise<T> {
    const task = this.tail.then(operation);
    this.tail = task.catch(() => {}); return task;
  }
  private prune() {
    const cutoff = Date.now() - 7 * DAY;
    const ack = this.data.device?.lastAckedSeq ?? 0;
    this.data.queue = this.data.queue.filter(entry => {
      if (entry.seq <= ack || entry.queuedAt < cutoff) {
        this.data.droppedThrough = Math.max(this.data.droppedThrough, entry.seq); return false;
      }
      return true;
    });
    while (this.data.queue.length > 1000) this.data.droppedThrough = Math.max(this.data.droppedThrough, this.data.queue.shift()!.seq);
  }
  private async schedule() {
    let next = (this.data.lastReconcile ?? 0) + 5 * MINUTE;
    const due = this.data.queue.filter(q => !q.sent && q.retryAt > 0).map(q => q.retryAt);
    if (this.data.device && due.length) next = Math.min(next, ...due);
    if (this.data.subscription?.verified) next = Math.min(next, Math.max(this.data.subscription.expires - DAY, this.data.subscriptionRetryAt));
    else next = Math.min(next, this.data.subscriptionRetryAt || Date.now() + MINUTE);
    await this.ctx.storage.setAlarm(Math.max(Date.now() + 1000, next));
  }
  private async baseline() {
    const session = await this.jmap.session();
    const accountId = session.primaryAccounts[MAIL];
    const inboxId = await this.jmap.inbox(accountId);
    const emailState = await this.jmap.baseline(accountId);
    if (this.data.accountId && this.data.accountId !== accountId) {
      this.data.droppedThrough = this.data.nextSeq - 1; this.data.queue = [];
    }
    Object.assign(this.data, { accountId, inboxId, emailState, lastReconcile: Date.now() });
    this.save();
  }
  private async reconcile() {
    const session = await this.jmap.session();
    if (!this.data.emailState || this.data.accountId !== session.primaryAccounts[MAIL]) { await this.baseline(); return; }
    // Refresh the role lookup; mailbox IDs are not assumed permanent.
    const inboxId = await this.jmap.inbox(this.data.accountId!);
    this.data.inboxId = inboxId;
    for (let page = 0; page < 20; page++) {
      let changes;
      try { changes = await this.jmap.changes(this.data.accountId!, this.data.emailState!); }
      catch (error) {
        if (error instanceof JMAPError && error.type === 'cannotCalculateChanges') { await this.baseline(); return; }
        throw error;
      }
      const { list } = await this.jmap.emails(this.data.accountId!, changes.created);
      const queued = new Set(this.data.queue.map(q => q.emailId));
      for (const email of list) {
        if (!email.mailboxIds[inboxId] || queued.has(email.id)) continue;
        this.data.queue.push({ seq: this.data.nextSeq++, emailId: email.id, queuedAt: Date.now(), sent: false, attempts: 0, retryAt: Date.now() });
        queued.add(email.id);
      }
      // No header data is retained. A failed get never advances the checkpoint.
      this.data.emailState = changes.newState;
      this.prune(); this.save();
      if (!changes.hasMoreChanges) { this.data.lastReconcile = Date.now(); this.save(); return; }
    }
    // Continue a large change set in a fresh invocation, with the last complete page committed.
    this.data.lastReconcile = Date.now() - 5 * MINUTE; this.save();
  }
  private async maintainSubscription() {
    const now = Date.now(); const subscription = this.data.subscription;
    const clientId = this.env.JMAP_DEVICE_CLIENT_ID;
    if (typeof clientId !== 'string' || !/^[A-Za-z0-9._-]{1,255}$/.test(clientId)) {
      this.data.lastError = 'invalid_device_client_id'; this.save(); return;
    }
    const callback = `${this.env.RELAY_URL.replace(/\/$/, '')}/jmap/push/${this.env.PUSH_PATH_SECRET}`;
    const stale = !!subscription && (subscription.deviceClientId !== clientId || subscription.callbackURL !== callback);
    if (now < this.data.subscriptionRetryAt && this.data.webPushKeys) return;
    if (!stale && subscription?.verified && subscription.expires > now + DAY) return;
    try {
      if (!stale && subscription?.verified && subscription.expires > now) {
        const expires = new Date(now + 7 * DAY).toISOString().replace(/\.\d{3}Z$/, 'Z');
        await this.jmap.updateSubscription(subscription.id, { expires });
        // Re-read server-clamped expiry rather than assuming the requested duration was accepted.
        const current = await this.jmap.call('PushSubscription/get', { ids: [subscription.id] }, false);
        const renewed = current.list?.find((s: any) => s.id === subscription.id);
        if (!renewed || !Number.isFinite(Date.parse(renewed.expires))) throw new RelayError('invalid_subscription');
        subscription.expires = Date.parse(renewed.expires);
        this.data.subscriptionRetryAt = now + MINUTE;
      } else if (!stale && subscription && !subscription.verified && now - subscription.createdAt < 5 * MINUTE) {
        this.data.subscriptionRetryAt = subscription.createdAt + 5 * MINUTE;
      } else {
        if (subscription) {
          try { await this.jmap.removeSubscription(subscription.id); }
          catch (error) { if (!(error instanceof JMAPError && error.type === 'notFound')) throw error; }
        }
        this.data.subscription = undefined;
        this.data.webPushKeys ??= await createWebPushKeys(); this.save();
        const created = await this.jmap.subscribe(clientId, callback, new Date(now + 7 * DAY).toISOString().replace(/\.\d{3}Z$/, 'Z'),
          { p256dh: this.data.webPushKeys.publicKey, auth: this.data.webPushKeys.auth });
        this.data.subscription = { id: created.id, expires: Date.parse(created.expires), verified: false, createdAt: now, deviceClientId: clientId, callbackURL: callback };
        this.data.pushMode = 'pending'; this.data.subscriptionRetryAt = now + 5 * MINUTE;
      }
    } catch (error) {
      this.data.pushMode = 'eventsource'; this.data.subscriptionRetryAt = now + DAY;
      this.data.lastError = safeError(error);
    }
    this.save();
  }
  private async sendPending() {
    if (!this.data.device || !this.data.accountId) return;
    const entries = this.data.queue.filter(q => !q.sent && q.retryAt <= Date.now()).slice(0, 20);
    const { list, notFound } = await this.jmap.emails(this.data.accountId, entries.map(q => q.emailId));
    const emails = new Map(list.map(e => [e.id, e]));
    for (const entry of entries) {
      if (!this.data.device) break;
      if (notFound.includes(entry.emailId)) { entry.sent = true; this.save(); continue; }
      const email = emails.get(entry.emailId)!;
      const result = await this.apns.send(this.data.device, await payload(email, entry.seq, this.data.device.payloadKey), email.id);
      if (result.kind === 'sent') { entry.sent = true; this.data.lastPush = Date.now(); }
      else if (result.kind === 'remove') { this.data.device = undefined; this.data.lastError = `apns_${result.reason}`; }
      else {
        entry.attempts++;
        // Permanent provider/config errors remain available through /missed, without a retry storm.
        entry.retryAt = Date.now() + (result.kind === 'failed' ? DAY : Math.max(result.retryAfter ?? 0,
          Math.min(60 * MINUTE, 30_000 * 2 ** Math.min(entry.attempts - 1, 7))));
        this.data.lastError = `apns_${result.reason}`;
      }
      this.save();
    }
  }
  private async tick(force = false) {
    if (!this.env.DEVICE_SECRET || !this.env.PUSH_PATH_SECRET || !this.env.FASTMAIL_API_TOKEN) throw new RelayError('relay_not_configured', 503);
    this.prune(); this.save();
    // Install a recovery alarm before any upstream I/O, including the first failed baseline.
    await this.ctx.storage.setAlarm(Date.now() + 5 * MINUTE);
    try {
      if (force || !this.data.lastReconcile || Date.now() - this.data.lastReconcile >= 5 * MINUTE) await this.reconcile();
      await this.maintainSubscription();
      await this.sendPending();
    } catch (error) {
      this.data.lastError = safeError(error); this.save();
      await this.ctx.storage.setAlarm(Date.now() + MINUTE); throw error;
    }
    await this.schedule();
  }
  async alarm() {
    await this.serial(async () => { try { await this.tick(); } catch { /* tick installed a recovery alarm */ } });
    this.ensureEventSource();
  }
  private ensureEventSource() {
    if (this.data.subscription?.verified && this.data.subscription.expires > Date.now()) {
      this.stream?.controller.abort(); this.stream = undefined; return;
    }
    if (this.stream && Date.now() - this.stream.started < 10 * MINUTE) return;
    this.stream?.controller.abort();
    const controller = new AbortController();
    const stream = { controller, started: Date.now() }; this.stream = stream;
    this.ctx.waitUntil(this.consumeEvents(controller).catch(() => {}).finally(() => {
      if (this.stream === stream) this.stream = undefined;
    }));
  }
  private async consumeEvents(controller: AbortController) {
    const timer = setTimeout(() => controller.abort(), 10 * MINUTE);
    try {
      const response = await this.jmap.events(controller.signal);
      if (!response.body) return;
      const reader = response.body.getReader(); const decoder = new TextDecoder(); let buffer = '';
      try {
        while (!controller.signal.aborted) {
          const { value, done } = await reader.read(); if (done) break;
          buffer += decoder.decode(value, { stream: true }).replace(/\r/g, '');
          if (buffer.length > 65_536) throw new RelayError('eventsource_frame_too_large');
          let boundary;
          while ((boundary = buffer.indexOf('\n\n')) >= 0) {
            const frame = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 2);
            const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
            if (!data) continue;
            let event: unknown; try { event = JSON.parse(data); } catch { continue; }
            if (this.isMailChange(event)) await this.serial(() => this.tick(true));
          }
        }
      } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
    } finally { clearTimeout(timer); controller.abort(); }
  }
  private isMailChange(event: unknown): boolean {
    return object(event) && event['@type'] === 'StateChange' && object(event.changed) &&
      !!this.data.accountId && object(event.changed[this.data.accountId]) && typeof event.changed[this.data.accountId].Email === 'string';
  }
  private status() {
    return {
      version: 1, deployment: this.env.WORKER_VERSION?.id ?? 'local', baselineEstablished: !!this.data.emailState, pushMode: this.data.pushMode,
      subscriptionVerified: this.data.subscription?.verified ?? false,
      device: this.data.device ? { deviceId: this.data.device.deviceId, environment: this.data.device.environment,
        lastAckedSeq: this.data.device.lastAckedSeq } : null,
      queueLength: this.data.queue.length, latestSeq: this.data.nextSeq - 1, droppedThrough: this.data.droppedThrough,
      lastReconcile: this.data.lastReconcile ?? null, lastPush: this.data.lastPush ?? null, lastError: this.data.lastError ?? null
    };
  }
  async fetch(request: Request): Promise<Response> {
    const operation = async () => {
      try { return await this.route(request); }
      catch (error) {
        return json({ error: safeError(error) }, error instanceof RelayError ? error.status : 502);
      }
    };
    // Read-only lookups must not occupy the delivery queue while awaiting Fastmail.
    const response = new URL(request.url).pathname === '/read-status'
      ? await operation() : await this.serial(operation);
    if (this.data.emailState) this.ensureEventSource();
    return response;
  }
  private device(deviceId: unknown): Device {
    if (!this.data.device || deviceId !== this.data.device.deviceId) throw new RelayError('device_not_registered', 409);
    return this.data.device;
  }
  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url); const path = url.pathname;
    if (path === '/internal/tick') { await this.tick(); return json({ ok: true }); }
    if (path === '/status') return json(this.status());
    if (path === '/devices' && request.method === 'POST') {
      const input = await readJSON(request);
      if (!object(input) || !id(input.deviceId) || typeof input.apnsToken !== 'string' || !/^[a-fA-F0-9]{64,200}$/.test(input.apnsToken) ||
        input.apnsToken.length % 2 || !['sandbox', 'production'].includes(input.environment) ||
        typeof input.timeZone !== 'string' || input.timeZone.length > 100 || typeof input.payloadKey !== 'string' ||
        unbase64(input.payloadKey).length !== 32 || (input.appVersion !== undefined && (typeof input.appVersion !== 'string' || input.appVersion.length > 64)))
        throw new RelayError('invalid_device', 400);
      try { new Intl.DateTimeFormat('en', { timeZone: input.timeZone }); } catch { throw new RelayError('invalid_time_zone', 400); }
      await this.tick();
      const previous = this.data.device;
      const lastAckedSeq = previous?.deviceId === input.deviceId ? previous.lastAckedSeq : 0;
      this.data.device = { deviceId: input.deviceId, apnsToken: input.apnsToken.toLowerCase(), environment: input.environment,
        timeZone: input.timeZone, appVersion: input.appVersion, payloadKey: input.payloadKey, lastAckedSeq, offeredSeq: lastAckedSeq };
      this.save(); await this.schedule();
      return json({ deviceId: input.deviceId, lastAckedSeq, latestSeq: this.data.nextSeq - 1 }, 201);
    }
    if (path.startsWith('/devices/') && request.method === 'DELETE') {
      this.device(path.slice('/devices/'.length)); this.data.device = undefined; this.save(); return new Response(null, { status: 204 });
    }
    if (path === '/read-status' && request.method === 'POST') {
      const input = await readJSON(request);
      if (!object(input) || !id(input.deviceId) || !Array.isArray(input.emailIds) ||
        input.emailIds.length < 1 || input.emailIds.length > 50 || !input.emailIds.every(id) ||
        new Set(input.emailIds).size !== input.emailIds.length) throw new RelayError('invalid_read_request', 400);
      const device = this.device(input.deviceId);
      this.readRequests = this.readRequests.filter(time => time > Date.now() - MINUTE);
      if (this.readRequests.length >= 8) throw new RelayError('read_status_rate_limited', 429);
      this.readRequests.push(Date.now());
      const accountId = this.data.accountId;
      if (!accountId) throw new RelayError('mailbox_not_ready', 409);
      const results = await this.jmap.readStatus(accountId, input.emailIds);
      this.device(input.deviceId);
      return json({ v: 1, deviceId: device.deviceId, results });
    }
    if (path === '/missed') {
      const device = this.device(url.searchParams.get('deviceId'));
      const raw = url.searchParams.get('after');
      const after = raw !== null && /^\d+$/.test(raw) ? Number(raw) : NaN;
      if (!sequence(after) || after > this.data.nextSeq - 1) throw new RelayError('invalid_cursor', 400);
      this.prune(); this.save();
      const entries = this.data.queue.filter(q => q.seq > after).slice(0, 50);
      const result = await this.jmap.emails(this.data.accountId!, entries.map(q => q.emailId));
      const emails = new Map(result.list.map(e => [e.id, e]));
      const messages = [];
      for (const entry of entries) {
        const email = emails.get(entry.emailId);
        if (email) messages.push(await payload(email, entry.seq, device.payloadKey));
      }
      const nextCursor = Math.max(after, this.data.droppedThrough, entries.at(-1)?.seq ?? after);
      device.offeredSeq = Math.max(device.offeredSeq, nextCursor); this.save();
      return json({ v: 1, messages, nextCursor, hasMore: this.data.queue.some(q => q.seq > nextCursor),
        droppedThrough: this.data.droppedThrough, gap: after < this.data.droppedThrough });
    }
    if (path === '/ack') {
      const input = await readJSON(request); if (!object(input)) throw new RelayError('invalid_ack', 400);
      const device = this.device(input.deviceId);
      if (!sequence(input.seq) || input.seq > device.offeredSeq) throw new RelayError('invalid_ack', 400);
      device.lastAckedSeq = Math.max(device.lastAckedSeq, input.seq); this.prune(); this.save();
      return json({ lastAckedSeq: device.lastAckedSeq });
    }
    if (path === '/test') {
      const input = await readJSON(request); if (!object(input)) throw new RelayError('invalid_test', 400);
      const device = this.device(input.deviceId);
      return json(await this.testPush(device));
    }
    if (path === '/probe') {
      const input = await readJSON(request); if (!object(input)) throw new RelayError('invalid_probe', 400);
      const scope = await this.jmap.scopeProbe();
      if (!this.data.subscription) this.data.subscriptionRetryAt = 0;
      await this.tick(true);
      await this.apns.token();
      let apns: unknown = { status: 'pending_device_token', providerTokenSigned: true };
      if (input.apnsToken !== undefined) {
        if (typeof input.apnsToken !== 'string' || !/^[a-fA-F0-9]{64,200}$/.test(input.apnsToken) || input.apnsToken.length % 2 ||
          !['sandbox', 'production'].includes(input.environment)) throw new RelayError('invalid_test_device', 400);
        apns = await this.testPush({ apnsToken: input.apnsToken, environment: input.environment });
      }
      return json({ scope, subscription: { mode: this.data.pushMode, accepted: !!this.data.subscription,
        verified: this.data.subscription?.verified ?? false }, apns });
    }
    if (path.startsWith('/jmap/push/')) {
      const input = await pushJSON(request, this.data.webPushKeys);
      if (object(input) && input['@type'] === 'PushVerification') {
        if (!this.data.subscription || input.pushSubscriptionId !== this.data.subscription.id ||
          typeof input.verificationCode !== 'string' || input.verificationCode.length > 1024) throw new RelayError('invalid_verification', 400);
        await this.jmap.updateSubscription(input.pushSubscriptionId, { verificationCode: input.verificationCode });
        this.data.subscription.verified = true; this.data.pushMode = 'subscription';
        if (this.data.lastError?.startsWith('jmap_')) this.data.lastError = undefined; this.save(); await this.schedule();
        return json({ ok: true });
      }
      if (!object(input) || input['@type'] !== 'StateChange' || !object(input.changed)) throw new RelayError('invalid_push', 400);
      if (this.isMailChange(input)) await this.tick(true);
      return json({ ok: true });
    }
    return json({ error: 'not_found' }, 404);
  }
  private async testPush(device: Pick<Device, 'apnsToken' | 'environment'> & { payloadKey?: string }) {
    // Synthetic generic alert, no queue/cursor mutation and no mailbox headers.
    const emailId = `test-${crypto.randomUUID()}`;
    const receivedAt = new Date().toISOString();
    const content = device.payloadKey ? await payload({ id: emailId, mailboxIds: {},
      from: [{ name: 'MailChime', email: 'test@example.invalid' }], subject: 'Test notification', receivedAt }, 0, device.payloadKey) :
      { aps: { alert: { title: "Here's The Mail!", body: 'New message' }, sound: 'Notification_A.aiff',
        'mutable-content': 1, 'thread-id': 'mailchime-inbox' }, v: 1, seq: 0, emailId, receivedAt };
    const result = await this.apns.send(device, { ...content, test: true }, emailId);
    if (result.kind === 'remove' && device === this.data.device) { this.data.device = undefined; this.save(); }
    return result;
  }
}
