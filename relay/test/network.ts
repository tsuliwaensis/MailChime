import { vi } from 'vitest';
// vi.stubGlobal is the current Cloudflare integration's supported outbound-fetch mocking path.
// No test may reach a real provider: an unmatched request fails closed.
type Options = { body: string; headers: Headers };
type Reply = { statusCode: number; data: unknown; headers?: Record<string, string> };
type Route = { origin: string; path: string | RegExp; method: string; persistent: boolean; reply: (options: Options) => Reply };
let routes: Route[] = [];
export const fetchMock = {
  activate() {
    routes = [];
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init); const url = new URL(request.url);
      const index = routes.findIndex(r => r.origin === url.origin && r.method === request.method &&
        (typeof r.path === 'string' ? r.path === url.pathname + url.search : r.path.test(url.pathname + url.search)));
      if (index < 0) throw new Error(`Unexpected mock request: ${request.method} ${url.origin}${url.pathname}`);
      const route = routes[index]; if (!route.persistent) routes.splice(index, 1);
      const result = route.reply({ body: await request.text(), headers: request.headers });
      return new Response(typeof result.data === 'string' ? result.data : JSON.stringify(result.data), { status: result.statusCode, headers: result.headers });
    });
  },
  disableNetConnect() {}, // Unmatched calls always throw.
  deactivate() { vi.unstubAllGlobals(); routes = []; },
  get(origin: string) {
    return { intercept(match: { path: string | RegExp; method?: string }) {
      return { reply(status: number | ((options: Options) => Reply), data?: unknown, options?: { headers: Record<string, string> }) {
        const route: Route = { origin, ...match, method: match.method ?? 'GET', persistent: false,
          reply: typeof status === 'function' ? status : () => ({ statusCode: status, data, headers: options?.headers }) };
        routes.push(route); return { persist() { route.persistent = true; } };
      } };
    } };
  }
};
