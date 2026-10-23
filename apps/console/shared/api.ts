/** Public account UI configuration. Console is Mindwire’s hosted management service. */
export type SocialProvider = "github" | "google" | "apple";
export interface AccountDeletionProgress {
  status: "pending" | "deleted";
  requestedAt: number;
  message: string;
}
export interface AccountDeletionOptions {
  status: "none" | "pending" | "deleted";
  message?: string;
  hasPassword: boolean;
  needsSignIn: boolean;
  socials: SocialProvider[];
}
export type AccountDeletionRequest = AccountDeletionProgress & { receipt: string };
export interface PublicConfig {
  appName: string;
  mode: "cloud";
  socials: SocialProvider[];
  passwordResetEnabled?: boolean;
  docsUrl: string;
  githubUrl: string;
}
