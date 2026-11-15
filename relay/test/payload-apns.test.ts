import { beforeEach, afterEach, describe, it, expect } from 'vitest';
import { fetchMock } from './network';
import { APNs } from '../src/apns';
import { payload, associatedData } from '../src/payload';
import { unbase64 } from '../src/util';
import { bindings, device, email, key, mockAPNs } from './helpers';
import type { Device, ProviderToken } from '../src/types';
beforeEach(() => { fetchMock.activate(); fetchMock.disableNetConnect(); });
afterEach(() => { fetchMock.deactivate(); });
async function decrypt(p: Awaited<ReturnType<typeof payload>>, aad = associatedData(p.seq, p.emailId, p.receivedAt)) {
  const cryptoKey = await crypto.subtle.importKey('raw', unbase64(key), 'AES-GCM', false, ['decrypt']);
  return crypto.subtle.decrypt({ name: 'AES-GCM', iv: unbase64(p.enc.nonce), additionalData: aad }, cryptoKey, unbase64(p.enc.ciphertext));
}
describe('encrypted payload', () => {
  it('round trips, binds metadata, and never includes plaintext headers', async () => {
    const p = await payload(email('m1'), 1, key);
    const raw = JSON.stringify(p);
    expect(raw).not.toContain('Private'); expect(raw).not.toContain('sender@example.com');
    expect(JSON.parse(new TextDecoder().decode(await decrypt(p)))).toEqual({ from: 'Private Sender <sender@example.com>', subject: 'Private Subject' });
    await expect(decrypt(p, associatedData(2, 'm1', p.receivedAt))).rejects.toThrow();
    await expect(decrypt(p, associatedData(1, 'wrong', p.receivedAt))).rejects.toThrow();
    await expect(decrypt(p, associatedData(1, 'm1', 'tampered'))).rejects.toThrow();
    p.enc.ciphertext = btoa('x'.repeat(40)); await expect(decrypt(p)).rejects.toThrow();
  });
  it('uses a fresh nonce and fits 4 KiB with Unicode and hostile escaped headers', async () => {
    for (const subject of ['😀'.repeat(5000), '\u0000'.repeat(10000), '"\\'.repeat(5000)]) {
      const message = { ...email('m1'), subject, from: [{ email: '\u0000'.repeat(5000) }] };
      const a = await payload(message, 1, key); const b = await payload(message, 1, key);
      expect(a.enc.nonce).not.toBe(b.enc.nonce);
      expect(new TextEncoder().encode(JSON.stringify(a)).length).toBeLessThanOrEqual(4096);
      await expect(decrypt(a)).resolves.toBeDefined();
    }
  });
  it('rejects an invalid encryption key', async () => { await expect(payload(email('m1'), 1, btoa('short'))).rejects.toThrow('invalid_payload_key'); });
});
describe('APNs provider', () => {
  it('signs a verifiable ES256 JWT and persists/reuses it across provider instances', async () => {
    let stored: ProviderToken | undefined;
    const a = new APNs(bindings, () => stored, t => { stored = t; });
    const token = await a.token(); expect(await a.token()).toBe(token);
    expect(await new APNs(bindings, () => stored).token()).toBe(token);
    const parts = token.split('.');
    const decode = (part: string) => unbase64(part.replace(/-/g, '+').replace(/_/g, '/'));
    expect(JSON.parse(new TextDecoder().decode(decode(parts[0])))).toEqual({ alg: 'ES256', kid: bindings.APNS_KEY_ID });
    const privateKey = await crypto.subtle.importKey('pkcs8', unbase64(bindings.APNS_KEY_P8.replace(/-----[^-]+-----/g, '').replace(/\s/g, '')),
      { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign']);
    const jwk = await crypto.subtle.exportKey('jwk', privateKey) as JsonWebKey; delete jwk.d; jwk.key_ops = ['verify'];
    const publicKey = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    expect(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, decode(parts[2]), new TextEncoder().encode(parts.slice(0, 2).join('.')))).toBe(true);
    stored!.issuedAt -= 41 * 60;
    let writes = 0; await new APNs(bindings, () => stored, () => { writes++; }).token(); expect(writes).toBe(1);
  });
  it.each([[410, 'Unregistered', 'remove'], [400, 'BadDeviceToken', 'remove'], [429, 'TooManyRequests', 'retry'],
    [500, 'InternalServerError', 'retry'], [403, 'InvalidProviderToken', 'failed'], [400, 'DeviceTokenNotForTopic', 'failed']])(
    'maps status %s / %s to %s', async (status, reason, kind) => {
      mockAPNs(Number(status), String(reason));
      expect((await new APNs(bindings).send(device as Device, {}, 'm1')).kind).toBe(kind);
    });
  it('refreshes an expired provider token once and retries', async () => {
    mockAPNs(403, 'ExpiredProviderToken', false); const sent = mockAPNs(); let writes = 0;
    const result = await new APNs(bindings, () => undefined, () => { writes++; }).send(device as Device, {}, 'm1');
    expect(result.kind).toBe('sent'); expect(writes).toBe(2); expect(sent).toHaveLength(1);
  });
  it('sets alert headers, a bounded collapse ID, and encrypted body', async () => {
    const sent = mockAPNs(); const p = await payload(email('m1'), 1, key);
    expect((await new APNs(bindings).send(device as Device, p, 'm1')).kind).toBe('sent');
    const headers = new Headers(sent[0].headers);
    expect(headers.get('apns-topic')).toBe('com.rhpt.mailchime'); expect(headers.get('apns-push-type')).toBe('alert');
    expect(headers.get('apns-priority')).toBe('10'); expect(headers.get('apns-collapse-id')!.length).toBeLessThanOrEqual(64);
    expect(JSON.stringify(sent[0].body)).not.toContain('Private Subject');
  });
  it('uses the production endpoint for production registrations', async () => {
    fetchMock.get('https://api.push.apple.com').intercept({ path: `/3/device/${device.apnsToken}`, method: 'POST' }).reply(200, '');
    expect((await new APNs(bindings).send({ ...device, environment: 'production' }, {}, 'm1')).kind).toBe('sent');
  });
});
