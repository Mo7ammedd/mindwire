import type { Mindwire } from "./client.js";
import type { WorkspaceSnapshot } from "./workspace.js";

/** An application resource saved on its owning host. */
export interface AppShortcut {
  id: string;
  workspaceId: string;
  projectId: string;
  botId?: string;
  name: string;
  icon?: string;
  url: string;
  startupCommand?: string;
  healthPath?: string;
  archived: boolean;
  createdAt: string;
  revision: number;
  channelIds?: string[];
  notificationsMuted: boolean;
  automation?: boolean;
  staticDirectory?: string;
  publicUrl?: string;
}

export type AppShortcutCreate = Pick<AppShortcut, "projectId" | "name" | "url"> &
  Partial<Pick<AppShortcut, "id" | "botId" | "icon" | "startupCommand" | "healthPath" | "automation" | "channelIds" | "notificationsMuted" | "staticDirectory" | "publicUrl">>;
export type AppShortcutEdit = { expectedRevision: number } &
  Partial<Pick<AppShortcut, "name" | "icon" | "url" | "startupCommand" | "healthPath" | "archived" | "channelIds" | "notificationsMuted" | "staticDirectory" | "publicUrl">>;
export interface AppShortcutMutation { app: AppShortcut; snapshot: WorkspaceSnapshot }
export interface AppPublication { app: AppShortcut; kind: "port" | "static"; port?: number; directory?: string }
export interface AppNotificationChannel { id: string; name: string; type: string }
export interface AppScheduleSpec {
  id?: string;
  expectedRevision?: number;
  name: string;
  runAt?: string;
  intervalSeconds?: number;
  localTime?: string;
  timeZone?: string;
  weekdays?: number[];
  command?: string;
  title?: string;
  body?: string;
  enabled?: boolean;
}
export interface AppSchedule extends Omit<AppScheduleSpec, "id"> {
  id: string;
  appId: string;
  revision: number;
  active: boolean;
  state: string;
  nextRunAt?: string;
  retryAt?: string;
  lastRunAt?: string;
  lastError?: string;
  attempts: number;
}

export class AppsApi {
  constructor(private readonly mw: Mindwire) {}
  list(): Promise<AppShortcut[]> { return this.mw.http.request("GET", "/apps"); }
  get(id: string): Promise<AppShortcut> { return this.mw.http.request("GET", `/apps/${encodeURIComponent(id)}`); }
  register(input: AppShortcutCreate): Promise<AppShortcutMutation> {
    return this.mw.http.request("POST", "/apps", { body: input });
  }
  update(id: string, input: AppShortcutEdit): Promise<AppShortcutMutation> {
    return this.mw.http.request("PATCH", `/apps/${encodeURIComponent(id)}`, { body: input });
  }
  /** Ensures readiness on the owning computer; the client opens the returned URL. */
  open(id: string): Promise<AppShortcut> {
    return this.mw.http.request("POST", `/apps/${encodeURIComponent(id)}/open`, { body: {} });
  }
  /** Validates a plan for the owner's hosting adapter; does not deploy or charge. */
  preparePublication(id: string): Promise<AppPublication> {
    return this.mw.http.request("POST", `/apps/${encodeURIComponent(id)}/publication/prepare`, { body: {} });
  }
  channels(): Promise<AppNotificationChannel[]> { return this.mw.http.request("GET", "/apps/channels"); }
  notifications(id: string, options: { channelIds?: string[]; rotate?: boolean } = {}): Promise<AppShortcutMutation & { credentialFile: string }> {
    return this.mw.http.request("POST", `/apps/${encodeURIComponent(id)}/notifications`, { body: options });
  }
  revokeNotificationAccess(id: string): Promise<{ revoked: boolean }> {
    return this.mw.http.request("DELETE", `/apps/${encodeURIComponent(id)}/notifications/token`);
  }
  schedules(id: string): Promise<AppSchedule[]> {
    return this.mw.http.request("GET", `/apps/${encodeURIComponent(id)}/schedules`);
  }
  saveSchedule(id: string, schedule: AppScheduleSpec): Promise<AppSchedule> {
    return this.mw.http.request("POST", `/apps/${encodeURIComponent(id)}/schedules`, { body: schedule });
  }
  deleteSchedule(id: string, scheduleId: string): Promise<{ removed: boolean }> {
    return this.mw.http.request("DELETE", `/apps/${encodeURIComponent(id)}/schedules/${encodeURIComponent(scheduleId)}`);
  }
}
