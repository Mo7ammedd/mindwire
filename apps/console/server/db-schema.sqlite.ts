import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

export const consoleSecret = sqliteTable("console_secret", {
  ownerId: text("owner_id").notNull(),
  name: text("name").notNull(),
  kind: text("kind").notNull(),
  ciphertext: text("ciphertext").notNull(),
  updatedAt: integer("updated_at").notNull(),
}, (table) => [primaryKey({ columns: [table.ownerId, table.name] })]);

export const computerDirectory = sqliteTable("computer_directory", {
  directoryId: text("directory_id").primaryKey(),
  computerId: text("computer_id").notNull(),
  publicKey: text("public_key").notNull(),
  revoked: integer("revoked").notNull().default(0),
  sequence: integer("sequence").notNull().default(0),
  digest: text("digest"),
  enabled: integer("enabled").notNull().default(0),
  expiresAt: integer("expires_at").notNull().default(0),
  createdAt: integer("created_at").notNull(),
  publication: text("publication"),
}, (table) => [index("computer_directory_expiry").on(table.expiresAt)]);

export const directoryEnrollmentBudget = sqliteTable("computer_directory_enrollment_budget", {
  source: text("source").notNull(),
  day: integer("day").notNull(),
  count: integer("count").notNull(),
}, table => [primaryKey({ columns: [table.source, table.day] }), index("computer_directory_budget_day").on(table.day)]);

export const pushDevice = sqliteTable("push_device", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  ownerId: text("owner_id").notNull(),
  deviceId: text("device_id").notNull(),
  tokenCiphertext: text("token_ciphertext").notNull(),
  tokenHash: text("token_hash").notNull(),
  platform: text("platform").notNull(),
  deviceInfo: text("device_info"),
  status: text("status").notNull().default("active"),
  createdAt: integer("created_at").notNull(),
  lastSeenAt: integer("last_seen_at"),
}, t => [uniqueIndex("push_device_owner_device").on(t.ownerId, t.deviceId), index("push_device_owner_status").on(t.ownerId, t.status)]);

export const pushToken = sqliteTable("push_token", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  ownerId: text("owner_id").notNull(),
  workspaceId: text("workspace_id"),
  tag: text("tag"),
  tokenHash: text("token_hash").notNull(),
  tokenPrefix: text("token_prefix").notNull(),
  name: text("name"),
  metadata: text("metadata"),
  status: text("status").notNull().default("active"),
  createdAt: integer("created_at").notNull(),
  lastUsedAt: integer("last_used_at"),
  expiresAt: integer("expires_at"),
  revokedAt: integer("revoked_at"),
}, t => [uniqueIndex("push_token_hash").on(t.tokenHash), uniqueIndex("push_token_owner_tag").on(t.ownerId, t.tag), index("push_token_owner_status").on(t.ownerId, t.status)]);

// One immutable namespace and saved paid contract per Mindwire Cloud Computer.
export const cloudComputer = sqliteTable("cloud_computer", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull(),
  requestKey: text("request_key").notNull(),
  namespace: text("namespace").notNull(),
  name: text("name").notNull(),
  state: text("state").notNull().default("draft"),
  contract: text("contract").notNull(),
  workspaceId: text("workspace_id"),
  checkoutId: text("checkout_id"),
  checkoutUrl: text("checkout_url"),
  error: text("error"),
  leaseToken: text("lease_token"),
  leaseUntil: integer("lease_until").notNull().default(0),
  createdAt: integer("created_at").notNull(),
  updatedAt: integer("updated_at").notNull(),
}, t => [uniqueIndex("cloud_computer_request").on(t.ownerId, t.requestKey),
  uniqueIndex("cloud_computer_namespace").on(t.namespace), uniqueIndex("cloud_computer_workspace").on(t.workspaceId),
  index("cloud_computer_owner").on(t.ownerId), index("cloud_computer_due").on(t.state, t.updatedAt)]);

export const cloudLegacyAccount = sqliteTable("cloud_legacy_account", {
  providerId: text("provider_id").primaryKey(),
  ownerId: text("owner_id").notNull(),
  credential: text("credential").notNull(),
  nextRefreshAt: integer("next_refresh_at").notNull().default(0),
  createdAt: integer("created_at").notNull(),
}, t => [uniqueIndex("cloud_legacy_account_owner").on(t.ownerId), index("cloud_legacy_account_refresh").on(t.nextRefreshAt)]);
