/** Public account UI configuration. Console is Mindwire’s hosted management service. */
export type SocialProvider = "github" | "google";
export interface PublicConfig {
  appName: string;
  mode: "cloud";
  socials: SocialProvider[];
  docsUrl: string;
  githubUrl: string;
}
