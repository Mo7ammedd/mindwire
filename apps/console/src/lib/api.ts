import type { PublicConfig, SocialProvider, AccountDeletionOptions, AccountDeletionRequest, AccountDeletionProgress } from "@shared/api";

export interface AuthUser {
  id: string;
  email: string;
  name: string;
  image?: string | null;
}
export interface AccountSession {
  id: string;
  current: boolean;
  userAgent: string;
  createdAt: string;
  lastActiveAt: string;
  expiresAt: string;
}
export interface NotificationDevice {
  id: number;
  platform: string;
  device_info: unknown;
  status: string;
  created_at: string;
  last_seen_at: string | null;
}
export class HttpError extends Error {
  constructor(
    public readonly status: number,
    message: string,
    public readonly code?: string,
    public readonly retryable?: boolean,
    public readonly reference?: string,
  ) {
    super(message);
  }
}

export async function request<T>(
  url: string,
  method = "GET",
  body?: unknown,
  headers?: Record<string, string>,
): Promise<T> {
  const response = await fetch(url, {
    method,
    credentials: "same-origin",
    signal: AbortSignal.timeout(30000),
    headers: { "Content-Type": "application/json", ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  let data: unknown;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    throw new HttpError(
      response.status,
      "The service could not be reached. Please retry.",
    );
  }
  if (!response.ok) {
    const error = data as { message?: string; error?: string; code?: string; details?: { retryable?: boolean; reference?: string } } | null;
    throw new HttpError(
      response.status,
      error?.message ??
        error?.error ??
        "This request could not finish. Please retry.",
      error?.code,
      error?.details?.retryable,
      error?.details?.reference,
    );
  }
  return data as T;
}

export const api = {
  publicConfig: () => request<PublicConfig>("/api/public-config"),
  sessions: () =>
    request<{ sessions: AccountSession[] }>("/api/portal/sessions"),
  revokeSession: (id: string) =>
    request<{ current: boolean }>(
      `/api/portal/sessions/${encodeURIComponent(id)}/revoke`,
      "POST",
    ),
  notificationDevices: () =>
    request<{ devices: NotificationDevice[] }>("/api/notifications/devices"),
  removeNotificationDevice: (id: number) =>
    request(`/api/notifications/devices/${id}`, "DELETE"),
  account: {
    deletionOptions: () => request<AccountDeletionOptions>("/api/portal/account/deletion"),
    delete: (userId: string, password?: string) => request<AccountDeletionRequest>("/api/portal/account/deletion", "POST", { confirmation: "DELETE", expectedUserId: userId, ...(password ? { password } : {}) }),
    deletionProgress: (receipt: string) => request<AccountDeletionProgress>("/api/portal/account/deletion/status", "GET", undefined, { "X-Deletion-Receipt": receipt }),
    me: () => request<{ user: AuthUser } | null>("/api/account/get-session"),
    signUp: (email: string, password: string, name: string) =>
      request<{ user: AuthUser }>("/api/account/sign-up/email", "POST", {
        email,
        password,
        name,
      }),
    signIn: (email: string, password: string) =>
      request<{ user: AuthUser }>("/api/account/sign-in/email", "POST", {
        email,
        password,
      }),
    requestPasswordReset: (email: string, redirectTo: string) =>
      request<{ status: boolean }>("/api/account/request-password-reset", "POST", {
        email,
        redirectTo,
      }),
    resetPassword: (token: string, newPassword: string) =>
      request<{ status: boolean }>("/api/account/reset-password", "POST", {
        token,
        newPassword,
      }),
    socialSignIn: (provider: SocialProvider, callbackURL: string) =>
      request<{ url?: string }>("/api/account/sign-in/social", "POST", {
        provider,
        callbackURL,
        errorCallbackURL: callbackURL,
      }),
    signOut: () => request("/api/account/sign-out", "POST", {}),
    update: (name: string) =>
      request("/api/account/update-user", "POST", { name }),
    changePassword: (currentPassword: string, newPassword: string) =>
      request("/api/account/change-password", "POST", {
        currentPassword,
        newPassword,
        revokeOtherSessions: true,
      }),
  },
};
