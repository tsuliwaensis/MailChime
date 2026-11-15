# MailChime Relay

The **MailChime Relay** is a private, lightweight Cloudflare Worker and SQLite-backed Durable Object that acts as the server-side bridge between Fastmail and Apple Push Notification service (APNs).

---

## Overview

Fastmail does not natively send Apple Push Notifications directly to macOS apps. The MailChime Relay fills this gap securely and efficiently by running in your personal Cloudflare account:

1. **JMAP State Ingestion:** Subscribes to real-time Fastmail mailbox changes via JMAP Push (`PushSubscription`), with automatic fallback to an authenticated EventSource stream.
2. **Inbox Filtering:** Monitors only newly created emails in your Inbox. Messages moved, updated, or filed into other folders by Fastmail rules are ignored.
3. **End-to-End Encryption:** Encrypts sender and subject metadata using AES-256-GCM before sending anything across Apple's servers.
4. **APNs Dispatch:** Sends high-priority push notifications directly to APNs so that your Mac receives instant alerts even when the MailChime app is closed.
5. **Missed-Mail Buffering:** Keeps a short-term queue of recent notification sequences (up to 1,000 entries or 7 days) to support catch-up queries when a Mac wakes from sleep.
6. **Read-Status Lookup:** Provides an authenticated check (`POST /read-status`) allowing MailChime on macOS to automatically dismiss notification banners once emails are marked read ($seen) in Fastmail.

---

## Architecture

The relay consists of two main parts:

- **Cloudflare Worker Entry Point:** Routes incoming webhooks from Fastmail and authenticated requests from your Mac. It verifies credentials using constant-time comparison before passing requests to the mailbox instance.
- **MailboxRelay (Durable Object):** A single-tenant, persistent service backed by embedded SQLite. It maintains the current JMAP sync checkpoint, device APNs token, encryption key, and temporary missed-mail queue. Scheduled alarms handle periodic reconciliation, subscription renewals, and retry backoffs.

---

## Configuration & Secrets

The relay is deployed using [Wrangler](https://developers.cloudflare.com/workers/wrangler/) and requires the following secrets configured in your Cloudflare Worker:

| Secret | Description |
| --- | --- |
| `FASTMAIL_API_TOKEN` | Fastmail API token with strictly **Mail read-only** scope. |
| `APNS_KEY_ID` | The 10-character Key ID for your Apple Push Notification auth key. |
| `APNS_KEY_P8` | The contents of your Apple APNs private key file (`.p8`). |
| `DEVICE_SECRET` | A secure random string shared between this relay and your Mac app. |
| `PUSH_PATH_SECRET` | A secure random string used as a private URL path component for Fastmail callbacks. |

---

## HTTP Endpoints Overview

All endpoints (except `/health` and Fastmail's webhook) require authentication using your `DEVICE_SECRET` as a Bearer token:

- **`GET /health`**: Public liveness check returning service and deployment version.
- **`POST /devices`**: Registers or updates your Mac's APNs token, environment, and encryption payload key.
- **`DELETE /devices/:id`**: Unregisters the Mac and stops active push dispatches.
- **`GET /missed`**: Retrieves queued notifications that arrived while the Mac was offline or asleep.
- **`POST /ack`**: Acknowledges delivered notification sequences so they can be safely retired from the queue.
- **`POST /read-status`**: Checks whether specific notification message IDs have been marked as read (`$seen`) in Fastmail.
- **`POST /test`**: Triggers a synthetic, encrypted test notification to verify end-to-end delivery through APNs.
- **`GET /status`**: Returns safe operational metrics, queue depth, and last sync/push timestamps.
- **`POST /jmap/push/:secret`**: Fastmail's webhook callback for real-time mailbox state changes.

> [!NOTE]
> Subscription records now track both the configured client identifier and callback
URL. Missing/mismatched values trigger replacement of that exact stored subscription
once its retry gate permits, rather than renewal of an obsolete callback. Invalid
client configuration leaves an existing subscription untouched. A fresh Worker
namespace cannot retire a different Worker's subscription automatically; follow the
migration plan before switching production traffic.
````