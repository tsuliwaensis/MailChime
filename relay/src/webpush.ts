// Fastmail requires RFC 8291 Web Push encryption for PushSubscription delivery.
import { base64url, encoder, readJSON, RelayError, unbase64 } from './util';
export interface WebPushKeys { privateKey: JsonWebKey; publicKey: string; auth: string }
function decode(value: string) { return unbase64(value.replace(/-/g, '+').replace(/_/g, '/')); }
function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const result = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
  let offset = 0; for (const part of parts) { result.set(part, offset); offset += part.length; } return result;
}
async function hkdf(raw: Uint8Array, salt: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array<ArrayBuffer>> {
  const key = await crypto.subtle.importKey('raw', raw, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, length * 8));
}
export async function createWebPushKeys(): Promise<WebPushKeys> {
  const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  return { privateKey: await crypto.subtle.exportKey('jwk', pair.privateKey) as JsonWebKey,
    publicKey: base64url(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey) as ArrayBuffer)),
    auth: base64url(crypto.getRandomValues(new Uint8Array(16))) };
}
export async function decryptWebPush(bytes: Uint8Array, keys: WebPushKeys): Promise<Uint8Array<ArrayBuffer>> {
  // RFC 8291 permits exactly one aes128gcm record, at most 4096 octets total.
  if (bytes.length < 103 || bytes.length > 4096) throw new RelayError('invalid_webpush', 400);
  const salt = bytes.slice(0, 16); const size = new DataView(bytes.buffer, bytes.byteOffset + 16, 4).getUint32(0);
  const keyLength = bytes[20];
  if (keyLength !== 65 || bytes[21] !== 4 || size <= bytes.length - 86) throw new RelayError('invalid_webpush', 400);
  try {
    const sender = bytes.slice(21, 86);
    const privateKey = await crypto.subtle.importKey('jwk', keys.privateKey, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
    const publicKey = await crypto.subtle.importKey('raw', sender, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
    const agreement = { name: 'ECDH', public: publicKey };
    const shared = new Uint8Array(await crypto.subtle.deriveBits(agreement, privateKey, 256));
    const ikm = await hkdf(shared, decode(keys.auth), concat(encoder.encode('WebPush: info\0'), decode(keys.publicKey), sender), 32);
    const cek = await hkdf(ikm, salt, encoder.encode('Content-Encoding: aes128gcm\0'), 16);
    const nonce = await hkdf(ikm, salt, encoder.encode('Content-Encoding: nonce\0'), 12);
    const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt']);
    const plaintext = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, key, bytes.slice(86)));
    let end = plaintext.length - 1;
    while (end >= 0 && plaintext[end] === 0) end--;
    if (plaintext[end] !== 2) throw new Error('invalid final record delimiter');
    return plaintext.slice(0, end);
  } catch { throw new RelayError('invalid_webpush', 400); }
}
export async function pushJSON(request: Request, keys?: WebPushKeys): Promise<any> {
  if (request.headers.get('content-encoding') !== 'aes128gcm') return readJSON(request);
  if (!keys || !request.body) throw new RelayError('invalid_webpush', 400);
  const reader = request.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length;
      if (size > 4096) { await reader.cancel(); throw new RelayError('invalid_webpush', 400); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const plaintext = await decryptWebPush(concat(...chunks), keys);
  try { return JSON.parse(new TextDecoder().decode(plaintext)); }
  catch { throw new RelayError('invalid_push', 400); }
}
