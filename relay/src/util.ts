export class RelayError extends Error {
  constructor(public code: string, public status = 502) { super(code); }
}
export const encoder = new TextEncoder();
export function base64(bytes: Uint8Array): string { return btoa(String.fromCharCode(...bytes)); }
export function unbase64(text: string): Uint8Array<ArrayBuffer> {
  try { return Uint8Array.from(atob(text), c => c.charCodeAt(0)); }
  catch { throw new RelayError('invalid_base64', 400); }
}
export function base64url(bytes: Uint8Array): string {
  return base64(bytes).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}
export async function secretEquals(a: string, b: string): Promise<boolean> {
  // Equal-length digests keep timing independent of the supplied secret's prefix/length.
  const [x, y] = await Promise.all([a, b].map(s => crypto.subtle.digest('SHA-256', encoder.encode(s))));
  return crypto.subtle.timingSafeEqual(x, y) && b.length >= 32;
}
export function json(data: unknown, status = 200): Response {
  return Response.json(data, { status, headers: { 'Cache-Control': 'no-store' } });
}
export async function readJSON(message: Request | Response, limit = 16_384): Promise<any> {
  if (Number(message.headers.get('content-length')) > limit) throw new RelayError('body_too_large', 413);
  if (!message.body) throw new RelayError('invalid_json', 400);
  const reader = message.body.getReader();
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length;
      if (size > limit) { await reader.cancel(); throw new RelayError('body_too_large', 413); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes)); }
  catch { throw new RelayError('invalid_json', 400); }
}
export function object(value: unknown): value is Record<string, any> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
export function id(value: unknown): value is string { return typeof value === 'string' && /^[A-Za-z0-9_-]{1,255}$/.test(value); }
export function sequence(value: unknown): value is number { return Number.isSafeInteger(value) && Number(value) >= 0; }
export function safeError(error: unknown): string { return error instanceof RelayError ? error.code : 'upstream_unavailable'; }
