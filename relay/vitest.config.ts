import { defineConfig } from 'vitest/config';
import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { generateKeyPairSync } from 'node:crypto';
const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: './wrangler.jsonc' },
    miniflare: { bindings: {
      FASTMAIL_API_TOKEN: 'fake-fastmail-token', DEVICE_SECRET: 'd'.repeat(64), PUSH_PATH_SECRET: 'p'.repeat(64),
      APNS_KEY_ID: 'TESTKEY123', APNS_KEY_P8: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
    } }
  })],
  test: { fileParallelism: false }
});
