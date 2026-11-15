import type { Device, Env, ProviderToken } from './types';
import { base64url, encoder, readJSON, unbase64 } from './util';
export type APNsResult = { kind: 'sent' | 'remove' | 'retry' | 'failed'; status: number; reason: string; retryAfter?: number };
export class APNs {
  private cached?: ProviderToken;
  constructor(private env: Env, private load: () => ProviderToken | undefined = () => undefined,
    private save: (token: ProviderToken) => void = () => {}) {}
  async token(force = false): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    this.cached ??= this.load();
    if (!force && this.cached && this.cached.keyId === this.env.APNS_KEY_ID && this.cached.teamId === this.env.APNS_TEAM_ID &&
      now >= this.cached.issuedAt && now - this.cached.issuedAt < 40 * 60) return this.cached.jwt;
    const pem = this.env.APNS_KEY_P8.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
    const key = await crypto.subtle.importKey('pkcs8', unbase64(pem), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const header = base64url(encoder.encode(JSON.stringify({ alg: 'ES256', kid: this.env.APNS_KEY_ID })));
    const claims = base64url(encoder.encode(JSON.stringify({ iss: this.env.APNS_TEAM_ID, iat: now })));
    const data = `${header}.${claims}`;
    const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, encoder.encode(data));
    this.cached = { jwt: `${data}.${base64url(new Uint8Array(signature))}`, issuedAt: now,
      keyId: this.env.APNS_KEY_ID, teamId: this.env.APNS_TEAM_ID };
    this.save(this.cached); return this.cached.jwt;
  }
  async send(device: Pick<Device, 'environment' | 'apnsToken'>, body: unknown, emailId: string): Promise<APNsResult> {
    const host = device.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    const collapse = base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(emailId))));
    for (let attempt = 0; attempt < 2; attempt++) {
      const token = await this.token(attempt === 1);
      let response: Response;
      try {
        response = await fetch(`https://${host}/3/device/${device.apnsToken}`, {
          method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(15_000),
          headers: { authorization: `bearer ${token}`, 'content-type': 'application/json',
            'apns-topic': this.env.APNS_TOPIC, 'apns-push-type': 'alert', 'apns-priority': '10',
            'apns-expiration': String(Math.floor(Date.now() / 1000) + 86_400), 'apns-collapse-id': collapse },
          body: JSON.stringify(body)
        });
      } catch { return { kind: 'retry', status: 0, reason: 'transport' }; }
      if (response.status === 200) { await response.body?.cancel(); return { kind: 'sent', status: 200, reason: 'Success' }; }
      let reason = 'Unknown';
      try {
        const data = await readJSON(response, 4096);
        // Only known provider reason codes may enter logs/status.
        if (['Unregistered', 'BadDeviceToken', 'ExpiredProviderToken', 'InvalidProviderToken', 'TooManyRequests',
          'TooManyProviderTokenUpdates', 'DeviceTokenNotForTopic', 'BadTopic', 'Forbidden', 'InternalServerError',
          'ServiceUnavailable', 'Shutdown', 'PayloadTooLarge'].includes(data.reason)) reason = data.reason;
      } catch { /* retain safe default */ }
      if ((response.status === 410 && reason === 'Unregistered') || (response.status === 400 && reason === 'BadDeviceToken'))
        return { kind: 'remove', status: response.status, reason };
      if (response.status === 403 && reason === 'ExpiredProviderToken' && attempt === 0) continue;
      if (response.status === 429 || response.status >= 500) {
        const header = response.headers.get('retry-after');
        const delay = header ? (/^\d+$/.test(header) ? Number(header) * 1000 : Date.parse(header) - Date.now()) : 0;
        return { kind: 'retry', status: response.status, reason, retryAfter: Math.min(86_400_000, Math.max(0, delay || 0)) };
      }
      return { kind: 'failed', status: response.status, reason };
    }
    return { kind: 'failed', status: 403, reason: 'ExpiredProviderToken' };
  }
}
