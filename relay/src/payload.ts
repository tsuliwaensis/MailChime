import type { Email } from './types';
import { base64, encoder, unbase64, RelayError } from './util';

// v1 wire contract: standard padded base64; ciphertext includes the 16-byte GCM tag.
// AAD is UTF-8 JSON.stringify([1, seq, emailId, receivedAt]).
export function associatedData(seq: number, emailId: string, receivedAt: string): Uint8Array<ArrayBuffer> {
  return new Uint8Array(encoder.encode(JSON.stringify([1, seq, emailId, receivedAt])));
}
function truncate(text: string, bytes: number): string {
  let result = ''; let used = 0;
  for (const c of text) { used += encoder.encode(c).length; if (used > bytes) break; result += c; }
  return result;
}
export async function payload(email: Email, seq: number, payloadKey: string) {
  const raw = unbase64(payloadKey);
  if (raw.length !== 32) throw new RelayError('invalid_payload_key', 400);
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt']);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const from = truncate((email.from ?? []).slice(0, 10).map(a => a.name ? `${a.name} <${a.email}>` : a.email).join(', '), 512);
  const plaintext = encoder.encode(JSON.stringify({ from, subject: truncate(email.subject, 1024) }));
  const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce,
    additionalData: associatedData(seq, email.id, email.receivedAt), tagLength: 128 }, key, plaintext);
  const result = {
    aps: { alert: { title: "Here's The Mail!", body: 'New message' }, sound: 'Notification_A.aiff',
      'mutable-content': 1, 'thread-id': 'mailchime-inbox' },
    v: 1, seq, emailId: email.id, receivedAt: email.receivedAt,
    enc: { alg: 'A256GCM', nonce: base64(nonce), ciphertext: base64(new Uint8Array(ciphertext)) }
  };
  // Escaped hostile text can expand. Fail closed rather than send plaintext or an oversized push.
  if (encoder.encode(JSON.stringify(result)).length > 4096) {
    if (email.subject.length > 64 || from.length > 64) {
      return payload({ ...email, subject: truncate(email.subject, 64), from: [{ email: truncate(from, 64) }] }, seq, payloadKey);
    }
    throw new RelayError('payload_too_large');
  }
  return result;
}
