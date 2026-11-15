import type { WebPushKeys } from './webpush';
import type { MailboxRelay } from './relay';
export interface Env {
  WORKER_VERSION?: { id: string; tag: string; timestamp: string };
  MAILBOX_RELAY: DurableObjectNamespace<MailboxRelay>;
  FASTMAIL_API_TOKEN: string;
  DEVICE_SECRET: string;
  PUSH_PATH_SECRET: string;
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
  RELAY_URL: string;
  JMAP_DEVICE_CLIENT_ID: string;
}
export interface Device {
  deviceId: string;
  apnsToken: string;
  environment: 'sandbox' | 'production';
  timeZone: string;
  appVersion?: string;
  payloadKey: string;
  lastAckedSeq: number;
  offeredSeq: number;
}
export interface Email {
  id: string;
  mailboxIds: Record<string, boolean>;
  from: { name?: string; email: string }[] | null;
  subject: string;
  receivedAt: string;
}
export interface QueueEntry {
  seq: number;
  emailId: string;
  queuedAt: number;
  sent: boolean;
  attempts: number;
  retryAt: number;
}
export interface ProviderToken { jwt: string; issuedAt: number; keyId: string; teamId: string }
export interface RelayState {
  version: 1;
  accountId?: string;
  inboxId?: string;
  emailState?: string;
  nextSeq: number;
  droppedThrough: number;
  queue: QueueEntry[];
  device?: Device;
  subscription?: { id: string; expires: number; verified: boolean; createdAt: number; deviceClientId?: string; callbackURL?: string };
  pushMode: 'pending' | 'subscription' | 'eventsource';
  subscriptionRetryAt: number;
  webPushKeys?: WebPushKeys;
  lastReconcile?: number;
  lastPush?: number;
  lastError?: string;
  providerToken?: ProviderToken;
}
