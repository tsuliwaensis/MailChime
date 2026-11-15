export {};
// Run with: RELAY_URL=https://... DEVICE_SECRET=... npm run probe
// Optional APNS_TEST_TOKEN and APNS_ENVIRONMENT=sandbox|production send a real test push.
const relayURL = process.env.RELAY_URL;
const secret = process.env.DEVICE_SECRET;
if (!relayURL || !secret) { console.error('Set RELAY_URL and DEVICE_SECRET.'); process.exit(1); }
const url = new URL(relayURL);
if (url.protocol !== 'https:' || url.username || url.password) { console.error('RELAY_URL must use HTTPS without embedded credentials.'); process.exit(1); }
try {
  const response = await fetch(new URL('/probe', url), { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(90_000),
    headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: JSON.stringify({ apnsToken: process.env.APNS_TEST_TOKEN, environment: process.env.APNS_ENVIRONMENT }) });
  const result = await response.json() as any;
  // The deployed endpoint returns safe diagnostics only; never output the request or credentials.
  console.log(JSON.stringify(result, null, 2));
  if (!response.ok) process.exitCode = 1;
  else if (result.scope?.readOnly !== 'confirmed' || !result.subscription?.accepted || result.apns?.kind !== 'sent') process.exitCode = 2;
} catch { console.error('Probe failed; check the relay URL, deployment, and network.'); process.exitCode = 1; }
