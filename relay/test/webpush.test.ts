import { it, expect } from 'vitest';
import { createWebPushKeys, decryptWebPush } from '../src/webpush';
import { base64url, unbase64 } from '../src/util';
// Published interoperability vector: https://www.rfc-editor.org/rfc/rfc8291.html#section-5
const publicKey = 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4';
const decode = (s: string) => unbase64(s.replace(/-/g, '+').replace(/_/g, '/'));
const point = decode(publicKey);
const keys = { publicKey, auth: 'BTBZMqHH6r4Tts7J_aSIgg', privateKey: {
  kty: 'EC', crv: 'P-256', x: base64url(point.slice(1, 33)), y: base64url(point.slice(33)),
  d: 'q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94', ext: true, key_ops: ['deriveBits']
} };
const body = decode('DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN');
it('decrypts the independent RFC 8291 test vector', async () => {
  expect(new TextDecoder().decode(await decryptWebPush(body, keys))).toBe('When I grow up, I want to be a watermelon');
});
it('rejects tampered, truncated, oversized and wrong-key Web Push bodies', async () => {
  const bad = body.slice(); bad[bad.length - 1] ^= 1;
  for (const bytes of [bad, body.slice(0, 100), new Uint8Array(4097)]) await expect(decryptWebPush(bytes, keys)).rejects.toThrow('invalid_webpush');
  await expect(decryptWebPush(body, await createWebPushKeys())).rejects.toThrow('invalid_webpush');
});
it('generates distinct, exportable subscription keys with a 128-bit auth secret', async () => {
  const a = await createWebPushKeys(); const b = await createWebPushKeys();
  expect(a.publicKey).not.toBe(b.publicKey); expect(decode(a.auth)).toHaveLength(16); expect(decode(a.publicKey)).toHaveLength(65);
});
