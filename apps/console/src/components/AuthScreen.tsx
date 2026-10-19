import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { ArrowUpRight, Loader2 } from "lucide-react";

import { api, type AuthUser } from "@/lib/api";
import type { PublicConfig, SocialProvider } from "@shared/api";
import { BrandMark } from "@/components/BrandMark";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { AccountArtwork } from "./AccountArtwork";
import { ThemeButton } from "./ThemeButton";
import styles from "./auth.module.css";

type Mode = "signin" | "signup";

const DOCS_FALLBACK = "https://mindwire.sh/docs";
const GITHUB_FALLBACK = "https://github.com/oblien/mindwire";

export function AuthScreen({
  onAuthed,
}: {
  onAuthed: (user: AuthUser) => void;
}) {
  const [mode, setMode] = useState<Mode>("signin");
  const [cfg, setCfg] = useState<PublicConfig | null>(null);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [social, setSocial] = useState<SocialProvider | null>(null);
  const [error, setError] = useState<string | null>(null);

  // The one pre-auth call: branding + which sign-in options to offer. Failure is non-fatal — the gate
  // simply falls back to email/password with default links.
  useEffect(() => {
    let alive = true;
    api.publicConfig().then(
      (c) => alive && setCfg(c),
      () => {},
    );
    return () => {
      alive = false;
    };
  }, []);

  const appName = !cfg?.appName || cfg.appName === "MindWire" ? "Mindwire" : cfg.appName;
  const socials = cfg?.socials ?? [];
  const docsUrl = cfg?.docsUrl ?? DOCS_FALLBACK;
  const githubUrl = cfg?.githubUrl ?? GITHUB_FALLBACK;
  const isSignup = mode === "signup";
  const locked = busy || social !== null;

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    const identifier = email.trim();
    if (!identifier || !password) {
      setError("Email and password are required.");
      return;
    }
    if (isSignup && password.length < 8) {
      setError("Password must be at least 8 characters.");
      return;
    }
    setBusy(true);
    try {
      const accountEmail = identifier;
      const res = isSignup
        ? await api.account.signUp(
            accountEmail,
            password,
            name.trim() || accountEmail.split("@")[0]!,
          )
        : await api.account.signIn(accountEmail, password);
      onAuthed(res.user);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Authentication failed.");
    } finally {
      setBusy(false);
    }
  }

  // OAuth: ask the server for the provider's authorize URL, then hand the browser to it. On return the
  // session cookie is set and the app re-bootstraps as the signed-in user (no onAuthed needed here).
  async function onSocial(provider: SocialProvider) {
    setError(null);
    setSocial(provider);
    try {
      const res = await api.account.socialSignIn(
        provider,
        window.location.origin +
          window.location.pathname +
          window.location.search,
      );
      if (res.url) {
        window.location.href = res.url;
        return;
      }
      throw new Error("Couldn’t start sign-in.");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Sign-in failed.");
      setSocial(null);
    }
  }

  function switchMode(next: Mode) {
    setMode(next);
    setError(null);
  }

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <a href="https://mindwire.sh" aria-label="Mindwire home"><BrandMark size={26} /></a>
        <div className="flex items-center gap-3"><ThemeButton /><a href={docsUrl} className={styles.docsLink}>Documentation<ArrowUpRight className="size-4" /></a></div>
      </header>
      <main className={styles.main}>
        <section className={styles.welcome} aria-label="Your Mindwire account">
          <AccountArtwork className={styles.art} />
          <div><h1>Your ideas.<br />A place to go further.</h1><p>Give your bots a home, keep your devices connected, and pick up wherever life takes you.</p></div>
          <a href="https://mindwire.sh/use-cases">A few things you could do<ArrowUpRight className="size-4" /></a>
        </section>
        <section className={styles.formSection}>
          <div className={styles.form}>
            <div className="mb-6 space-y-1.5">
              <h2 className="text-[28px] font-medium leading-tight tracking-tight">
                {isSignup
                  ? `Create your ${appName} account`
                  : `Sign in to ${appName}`}
              </h2>
              <p className="text-sm text-muted-foreground">
                {isSignup
                  ? "Manage your devices and Cloud Computers with one account."
                  : "Welcome back — pick up where you left off."}
              </p>
            </div>

            <div className="space-y-6">
                {socials.length > 0 && (
                  <>
                    <div className="space-y-2">
                      {socials.includes("github") && (
                        <SocialButton
                          label="Continue with GitHub"
                          icon={<GitHubIcon />}
                          busy={social === "github"}
                          disabled={locked}
                          onClick={() => onSocial("github")}
                        />
                      )}
                      {socials.includes("google") && (
                        <SocialButton
                          label="Continue with Google"
                          icon={<GoogleIcon />}
                          busy={social === "google"}
                          disabled={locked}
                          onClick={() => onSocial("google")}
                        />
                      )}
                    </div>
                    <Divider>or continue with email</Divider>
                  </>
                )}

                <form onSubmit={onSubmit} className="space-y-4">
                  {isSignup && (
                    <div className="space-y-1.5">
                      <Label htmlFor="name">Name</Label>
                      <Input
                        id="name"
                        className="h-12"
                        autoComplete="name"
                        value={name}
                        onChange={(e) => setName(e.target.value)}
                        placeholder="Ada Lovelace"
                        disabled={locked}
                      />
                    </div>
                  )}
                  <div className="space-y-1.5">
                    <Label htmlFor="email">Email</Label>
                    <Input
                      id="email"
                      className="h-12"
                      type="email"
                      autoComplete="email"
                      required
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                      placeholder="you@example.com"
                      disabled={locked}
                    />
                  </div>
                  <div className="space-y-1.5">
                    <Label htmlFor="password">Password</Label>
                    <Input
                      id="password"
                      className="h-12"
                      type="password"
                      autoComplete={
                        isSignup ? "new-password" : "current-password"
                      }
                      required
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      placeholder={
                        isSignup ? "At least 8 characters" : "••••••••"
                      }
                      disabled={locked}
                    />
                  </div>

                  {error && <p role="alert" className="rounded-xl bg-destructive/8 p-3 text-sm text-destructive">{error}</p>}

                  <Button
                    type="submit"
                    className="h-12 w-full"
                    disabled={locked}
                  >
                    {busy && <Loader2 className="size-4 animate-spin" />}
                    {isSignup ? "Create account" : "Sign in"}
                  </Button>
                </form>
            </div>

            <p className="mt-7 text-center text-sm text-muted-foreground">
              {isSignup ? "Already have an account?" : "Need an account?"}{" "}
              <button
                type="button"
                disabled={locked}
                onClick={() => switchMode(isSignup ? "signin" : "signup")}
                className="font-medium text-foreground underline-offset-4 hover:underline"
              >
                {isSignup ? "Sign in" : "Create one"}
              </button>
            </p>
          </div>
        </section>
      </main>

      {/* Account service links. */}
      <footer className={styles.footer}>
        <div className="flex flex-wrap items-center justify-center gap-x-4 gap-y-2 px-5 pb-5 pt-4 text-xs text-muted-foreground lg:pt-5">
          <FooterLink href={docsUrl}>Docs</FooterLink>
          <Dot />
          <FooterLink href={githubUrl}>
            <GitHubIcon className="size-3.5" />
            GitHub
          </FooterLink>
          <Dot />
          <span className="inline-flex items-center gap-1.5">
            <span className="size-1.5 rounded-full bg-ink/40" />
            Mindwire Cloud
          </span>
        </div>
      </footer>
    </div>
  );
}

function SocialButton({
  label,
  icon,
  busy,
  disabled,
  onClick,
}: {
  label: string;
  icon: ReactNode;
  busy: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <Button
      type="button"
      variant="outline"
      className="h-12 w-full justify-center gap-2.5"
      disabled={disabled}
      onClick={onClick}
    >
      {busy ? <Loader2 className="size-4 animate-spin" /> : icon}
      {label}
    </Button>
  );
}

function Divider({ children }: { children: ReactNode }) {
  return (
    <div className="flex items-center gap-3">
      <span className="h-px flex-1 bg-border" />
      <span className="text-xs text-muted-foreground">
        {children}
      </span>
      <span className="h-px flex-1 bg-border" />
    </div>
  );
}

function FooterLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="inline-flex items-center gap-1.5 transition-colors hover:text-foreground"
    >
      {children}
    </a>
  );
}

function Dot() {
  return <span aria-hidden className="size-0.5 rounded-full bg-ink/30" />;
}

// Brand marks. GitHub's is genuinely monochrome, so it rides `currentColor` (flips with the theme like
// the rest of the ink). Google's is its official four-color "G" — a deliberate brand-color exception
// (like the agent brand marks), never recolored, so it stays instantly recognizable.
function GitHubIcon({ className = "size-4" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="currentColor"
      aria-hidden
    >
      <path d="M12 .5C5.73.5.5 5.73.5 12a11.5 11.5 0 0 0 7.86 10.92c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.56-.29-5.25-1.28-5.25-5.7 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.8 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.84 1.19 3.1 0 4.43-2.69 5.41-5.26 5.69.41.36.78 1.08.78 2.18v3.23c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12C23.5 5.73 18.27.5 12 .5Z" />
    </svg>
  );
}

function GoogleIcon() {
  return (
    <svg viewBox="0 0 24 24" className="size-4" aria-hidden>
      <path
        fill="#4285F4"
        d="M23.52 12.27c0-.79-.07-1.54-.2-2.27H12v4.51h6.47a5.53 5.53 0 0 1-2.4 3.63v3h3.88c2.27-2.09 3.57-5.17 3.57-8.87Z"
      />
      <path
        fill="#34A853"
        d="M12 24c3.24 0 5.96-1.08 7.95-2.91l-3.88-3c-1.08.72-2.45 1.16-4.07 1.16-3.13 0-5.78-2.11-6.73-4.96H1.29v3.09A12 12 0 0 0 12 24Z"
      />
      <path
        fill="#FBBC05"
        d="M5.27 14.29a7.2 7.2 0 0 1 0-4.58V6.62H1.29a12 12 0 0 0 0 10.76l3.98-3.09Z"
      />
      <path
        fill="#EA4335"
        d="M12 4.75c1.77 0 3.35.61 4.6 1.8l3.44-3.44A11.5 11.5 0 0 0 12 0 12 12 0 0 0 1.29 6.62l3.98 3.09C6.22 6.86 8.87 4.75 12 4.75Z"
      />
    </svg>
  );
}
