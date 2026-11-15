# MailChime

**MailChime** is a native macOS notification app for Fastmail. It delivers desktop alerts whenever new email arrives in your Inbox, even when your email client or the MailChime app itself isn't open.

---

## Overview

MailChime connects your Fastmail account to macOS Notification Center using Apple Push Notification service (APNs) and a private Cloudflare relay. It gives you immediate desktop alerts for incoming mail with zero impact on battery life and complete privacy.

### Key Highlights

- **Instant Push Alerts:** Receives real-time notifications via APNs as soon as Fastmail receives new mail, without keeping a heavy email client running.
- **Privacy-First (End-to-End Encrypted):** Email headers (Sender and Subject) are encrypted with AES-256-GCM before transiting Apple's push servers and decrypted locally on your Mac. Apple never sees who emailed you or what the subject is, and message bodies are never accessed.
- **Offline Catch-Up:** If your Mac is asleep or offline, an event-driven background agent checks for any missed messages the moment your computer wakes or reconnects to the network.
- **Auto-Clearing Read or Deleted Mail:** Once an email is read or deleted on your phone, in webmail, or in any mail client, MailChime automatically removes its notification banner from Notification Center.
- **Inbox-Only Focus:** Alerts only trigger for new mail landing directly in your Inbox; messages sorted or filtered into other folders by Fastmail rules are ignored.
- **Non-Destructive:** Fastmail access is strictly read-only. MailChime never marks messages as read, moves mail, or modifies your mailbox.
- **One-Click Action:** Clicking a notification banner brings up your default macOS email client right away.

---

## System Architecture

```
Fastmail (JMAP Push)
       │
       ▼
┌────────────────────────────────────────────────────────┐
│  Cloudflare Relay (Worker + Durable Object)            │
│  - Listens for Inbox changes via JMAP push             │
│  - Encrypts sender & subject (AES-256-GCM)             │
│  - Dispatches alert pushes to APNs                     │
│  - Buffers missed mail for sleeping Macs               │
│  - Answers read-status checks ($seen)                  │
└──────────────┬───────────────────────────┬─────────────┘
               │ (Alert Push)              │ (Catch-Up / Read Status)
               ▼                           ▼
┌──────────────────────────────┐  ┌──────────────────────────────────────┐
│  macOS Notification Service  │  │  macOS Background Agent              │
│  Extension                   │  │  - Runs on wake, login, & network    │
│  - Decrypts headers locally  │  │  - Reconciles missed notifications   │
│  - Formats local timestamp   │  │  - Automatically clears read banners │
└──────────────┬───────────────┘  └────────┬─────────────────────────────┘
               │                           │
               ▼                           ▼
         ┌───────────────────────────────────────┐
         │      macOS Notification Center        │
         └───────────────────────────────────────┘
```

---

## How It Works

### 1. Real-Time Push & The Cloudflare Relay
Fastmail does not natively push to Apple's notification servers. The server component in `relay/` acts as a private, secure bridge:
- **JMAP Push Ingestion:** Fastmail notifies the relay via encrypted Web Push (with an automatic EventSource stream fallback) whenever your mailbox state changes.
- **Inbox Filtering:** The relay checks for newly created messages in your Inbox. Messages filed into other folders or existing messages are ignored.
- **Header Encryption:** The relay fetches only the basic header metadata (Sender, Subject, Received date). It encrypts the sender and subject using a 256-bit AES-GCM key unique to your Mac before dispatching to APNs.
- **APNs Dispatch:** Sends high-priority alert pushes directly to Apple Push Notification service. The visible alert payload sent across Apple's servers contains only a generic "New message" label; the real headers remain secure ciphertext.

### 2. Local Decryption on macOS
- A native **Notification Service Extension** intercepts the push notification as it arrives on your Mac.
- It retrieves the decryption key from the shared, secure macOS Keychain, decrypts the Sender and Subject, formats the Received timestamp into your local time zone, and attaches the bundled custom chime (`Notification_A.aiff`).
- If the Mac is locked or the key cannot be read, a clean generic alert ("Here's The Mail!" / "New message") is presented as a safe fallback.

### 3. Reliable Catch-Up for Sleeping Macs
- While your Mac sleeps, APNs may coalesce or drop background pushes to preserve device battery and network resources.
- The relay maintains a resilient, temporary queue of message sequence numbers (retaining up to 1,000 entries or 7 days).
- A native macOS **Background Agent** (`com.rhpt.mailchime.agent`) runs automatically at login, on system wake, and upon network restoration. It queries the relay (`GET /missed`), identifies any notifications that were missed during sleep, and displays them locally without duplicate alerts.

### 4. Smart Auto-Dismissal of Read or Deleted Mail
- If you read an incoming email on another device (e.g., iPhone or Fastmail web), Fastmail marks the message with the `$seen` keyword; if you delete/expunge it, Fastmail reports it as `notFound`.
- While notifications are displayed, MailChime's background agent periodically queries the relay (`POST /read-status`) for those specific message IDs.
- As soon as a message is marked as read or deleted, MailChime automatically removes its banner from macOS Notification Center.

---

## The Cloudflare Relay Component

The `relay/` folder contains the serverless backend deployed to your personal Cloudflare account.

### Architecture

- **Cloudflare Worker Entry Point:** Routes incoming webhooks from Fastmail and authenticated requests from your Mac. It verifies credentials using constant-time comparison before passing requests to the mailbox instance.
- **MailboxRelay (Durable Object):** A single-tenant, persistent service backed by embedded SQLite. It maintains the current JMAP sync checkpoint, device APNs token, encryption key, and temporary missed-mail queue. Scheduled alarms handle periodic reconciliation, subscription renewals, and retry backoffs.

### Required Secrets

The relay requires the following secrets configured in your Cloudflare Worker:

| Secret | Description |
| --- | --- |
| `FASTMAIL_API_TOKEN` | Fastmail API token with strictly **Mail read-only** scope. |
| `APNS_KEY_ID` | The 10-character Key ID for your Apple Push Notification auth key. |
| `APNS_KEY_P8` | The contents of your Apple APNs private key file (`.p8`). |
| `DEVICE_SECRET` | A secure random string shared between this relay and your Mac app. |
| `PUSH_PATH_SECRET` | A secure random string used as a private URL path component for Fastmail callbacks. |

### Relay Endpoints Overview

All endpoints (except `/health` and Fastmail's webhook) require authentication using your `DEVICE_SECRET` as a Bearer token:

- **`GET /health`**: Public liveness check returning service and deployment version.
- **`POST /devices`**: Registers or updates your Mac's APNs token, push environment, and encryption payload key.
- **`DELETE /devices/:id`**: Unregisters the Mac and stops active push dispatches.
- **`GET /missed`**: Retrieves queued notifications that arrived while the Mac was offline or asleep.
- **`POST /ack`**: Acknowledges delivered notification sequences so they can be safely retired from the queue.
- **`POST /read-status`**: Checks whether specific notification message IDs have been marked as read (`$seen`) in Fastmail.
- **`POST /test`**: Triggers a synthetic, encrypted test notification to verify end-to-end delivery through APNs.
- **`GET /status`**: Returns safe operational metrics, queue depth, and last sync/push timestamps.
- **`POST /jmap/push/:secret`**: Fastmail's webhook callback for real-time mailbox state changes.

## macOS App Settings & Controls

MailChime includes a clean, native SwiftUI Settings window:

- **Relay Configuration:** Configure your private Cloudflare Worker URL and shared Device Secret.
- **Live Status Badges:** View live connection and registration statuses for APNs, the Cloudflare Worker, your push environment, and the background agent.
- **Send Test Notification:** Dispatches an end-to-end encrypted synthetic test alert through the relay and APNs to verify live delivery and local decryption.
- **Check for Missed Mail:** Manually triggers an immediate catch-up check against the relay.
- **Background Agent Controls:** Restart or refresh the resident launch agent directly from the settings panel.

---

## Privacy & Security

- **End-to-End Encryption:** Email headers (From and Subject) are encrypted using AES-256-GCM. Apple's servers only handle ciphertext; APNs never sees sender addresses or subject lines.
- **No Message Bodies:** MailChime never accesses, requests, or stores message bodies.
- **Read-Only Access:** The relay uses a Fastmail API token with strictly **Mail read-only** permissions. MailChime cannot alter, delete, or mark your mail read.
- **Secure Local Storage:** Credentials and encryption keys are stored in the macOS Data Protection Keychain with device-only access after first unlock.
- **Private Infrastructure:** The relay runs inside your personal Cloudflare account, protected by private secrets. No shared third-party servers ever touch your email.

---

## Getting Started

1. Deploy the Relay
2. Launch MailChime
3. Save Relay Credentials
4. Enable Notifications
5. Click *Send Test Notification*

---

## License

MailChime is free and open-source software released under the [MIT License](LICENSE).

## Acknowledgements

MailChime is a fork of [MailBell](https://github.com/martonpaulo/mailbell) by [Marton Paulo](https://github.com/martonpaulo), with original code by [Samzong](https://github.com/samzong/).

