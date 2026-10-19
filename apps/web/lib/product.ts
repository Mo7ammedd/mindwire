export const githubUrl = "https://github.com/oblien/mindwire";
function consoleOrigin(): string {
  try {
    const url = new URL(process.env.NEXT_PUBLIC_CONSOLE_URL ?? "https://console.mindwire.sh");
    if (url.username || url.password || url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname))) throw new Error();
    return url.origin;
  } catch { return "https://console.mindwire.sh"; }
}
export const cloudDashboardUrl = consoleOrigin() + "/computers";
export const cloudPricingUrl = "/pricing";
export const cloudRatesUrl = "https://console.mindwire.sh/computers";

// Native download buttons only appear once a public release URL is configured.
// The download page offers setup guidance and the CLI while a release is pending.
function iosDownload() {
  const value = process.env.NEXT_PUBLIC_IOS_APP_URL?.trim();
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password) return null;
    if (url.hostname === "apps.apple.com") {
      return { href: url.href, label: "Download on the App Store" };
    }
    if (url.hostname === "testflight.apple.com") {
      return { href: url.href, label: "Join on TestFlight" };
    }
  } catch {
    // An invalid deployment value must not turn a download CTA into an unsafe URL.
  }
  return null;
}

export const iosApp = iosDownload();
function macDownload() {
  const value = process.env.NEXT_PUBLIC_MAC_APP_URL?.trim();
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password) return null;
    return { href: url.href, label: url.hostname === "apps.apple.com" ? "Download on the Mac App Store" : "Download for Mac" };
  } catch { return null; }
}

export const macApp = macDownload();
export const downloadUrl = "/download";

export const productAgents = [
  { id: "codex", name: "Codex", href: "/docs/reference/agents/codex" },
  { id: "claude", name: "Claude Code", href: "/docs/reference/agents/claude" },
  { id: "grok", name: "Grok Build", href: "/docs/reference/agents/grok" },
  { id: "opencode", name: "opencode", href: "/docs/reference/agents/opencode" },
] as const;

export type ProductAgent = (typeof productAgents)[number]["id"];
