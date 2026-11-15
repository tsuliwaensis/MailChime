import type { Env } from './types';
import { json, secretEquals } from './util';
export { MailboxRelay } from './relay';
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === 'GET' && url.pathname === '/health') return json({ ok: true, service: 'mailchime-relay', version: 1, deployment: env.WORKER_VERSION?.id ?? 'local' });
    const push = url.pathname.startsWith('/jmap/push/');
    if (push) {
      if (request.method !== 'POST' || !env.PUSH_PATH_SECRET ||
        !await secretEquals(url.pathname.slice('/jmap/push/'.length), env.PUSH_PATH_SECRET)) return json({ error: 'not_found' }, 404);
    } else {
      const routes: Record<string, string> = { '/devices': 'POST', '/missed': 'GET', '/read-status': 'POST', '/ack': 'POST', '/test': 'POST', '/status': 'GET', '/probe': 'POST' };
      const method = routes[url.pathname] ?? (/^\/devices\/[A-Za-z0-9_-]{1,255}$/.test(url.pathname) ? 'DELETE' : undefined);
      if (!method) return json({ error: 'not_found' }, 404);
      const authorization = request.headers.get('authorization') ?? '';
      if (!env.DEVICE_SECRET || !authorization.startsWith('Bearer ') ||
        !await secretEquals(authorization.slice(7), env.DEVICE_SECRET)) return json({ error: 'unauthorized' }, 401);
      if (request.method !== method) return json({ error: 'method_not_allowed' }, 405);
    }
    return env.MAILBOX_RELAY.getByName('mailbox').fetch(request);
  },
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(env.MAILBOX_RELAY.getByName('mailbox').fetch(new Request('https://relay.internal/internal/tick', { method: 'POST' })).then(() => {}));
  }
} satisfies ExportedHandler<Env>;
