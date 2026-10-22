import { useEffect, useState } from "react";
import { useLocation } from "react-router-dom";
import { ArrowRightLeft, Check, Loader2, LogOut, Monitor, X } from "lucide-react";
import { api, type AuthUser } from "@/lib/api";
import { ThemeButton } from "./ThemeButton";
import { BrandMark } from "@/components/BrandMark";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

type Action = "approve" | "deny" | "switch" | "signout";

/** Only the public verification code belongs in this URL; account switching keeps it intact. */
export function DeviceAuthorization({ user, onSignOut }: {
  user: AuthUser;
  onSignOut: () => Promise<void>;
}) {
  const { search } = useLocation();
  const code = new URLSearchParams(search).get("user_code") ?? "";
  const [busy, setBusy] = useState<Action | null>(null);
  const [done, setDone] = useState<"approved" | "denied" | null>(null);
  const [error, setError] = useState("");
  const [verified, setVerified] = useState(false);

  useEffect(() => {
    setVerified(false); setDone(null); setError("");
    if (!code) { setError("Start sign-in from the Mindwire app to get a verification code."); return; }
    const controller = new AbortController();
    // Better Auth claims a code for the current account on an authenticated GET.
    // Check it anonymously until the user chooses Sign in or Cancel, so opening
    // this page never binds the request to an unwanted browser account.
    fetch(`/api/account/device?user_code=${encodeURIComponent(code)}`, {
      credentials: "omit", cache: "no-store", signal: controller.signal,
    })
      .then(async response => {
        if (!response.ok) throw new Error("This sign-in request expired. Start again from Mindwire.");
        const request = await response.json() as { status: string };
        if (request.status !== "pending") throw new Error("This request has already been completed. Start a new sign-in from Mindwire.");
        setVerified(true);
      })
      .catch(error => { if (!controller.signal.aborted) setError(error instanceof Error ? error.message : "Couldn't check this sign-in request."); });
    return () => controller.abort();
  }, [code]);

  async function decide(approve: boolean) {
    if (busy || !verified) return;
    setBusy(approve ? "approve" : "deny"); setError("");
    try {
      const current = await api.account.me();
      if (current?.user.id !== user.id) { window.location.reload(); return; }
      // Claim only after an explicit decision, retaining Better Auth's ownership checks.
      const claim = await fetch(`/api/account/device?user_code=${encodeURIComponent(code)}`, {
        credentials: "same-origin", cache: "no-store", signal: AbortSignal.timeout(30_000),
      });
      if (!claim.ok) throw new Error("This sign-in request expired. Start again from Mindwire.");
      const request = await claim.json() as { client_id?: string; status: string };
      if (request.status !== "pending") throw new Error("This request has already been completed. Start a new sign-in from Mindwire.");
      if (request.client_id !== "mindwire-native") throw new Error("This request is linked to another account. Start a new sign-in from Mindwire to use this account.");
      const response = await fetch(`/api/account/device/${approve ? "approve" : "deny"}`, {
        method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ userCode: code }),
        signal: AbortSignal.timeout(30_000),
      });
      if (!response.ok) throw new Error("This sign-in request expired or could not finish. Start again from Mindwire.");
      setDone(approve ? "approved" : "denied");
    } catch (e) { setError(e instanceof Error ? e.message : "Could not finish sign-in."); }
    finally { setBusy(null); }
  }

  async function leaveAccount(action: "switch" | "signout") {
    if (busy) return;
    setBusy(action); setError("");
    try {
      // End this browser session only. The device request stays pending at the
      // same URL, and no native sessions or coding-agent credentials are revoked.
      await onSignOut();
    } catch (e) { setError(e instanceof Error ? e.message : "Could not sign out. Please retry."); }
    finally { setBusy(null); }
  }

  return <main className="grid min-h-dvh place-items-center p-5">
    <Card className="w-full max-w-md">
      <CardHeader className="space-y-5">
        <div className="flex items-center justify-between"><BrandMark size={24} /><ThemeButton /></div>
        <CardTitle className="flex items-center gap-2">
          {done === "approved" ? <Check className="size-5" /> : done === "denied" ? <X className="size-5" /> : <Monitor className="size-5" />}
          {done === "approved" ? "You're signed in" : done === "denied" ? "Sign-in cancelled" : "Sign in to Mindwire"}
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-5">
        {done ? <p className="text-sm leading-relaxed text-muted-foreground">
          {done === "approved" ? "Return to the Mindwire app. You can close this window." : "This request was cancelled. You can close this window."}
        </p> : <>
          <div className="space-y-3 rounded-2xl bg-secondary/60 p-4">
            <div className="flex min-w-0 items-center gap-3">
              <span aria-hidden className="grid size-10 shrink-0 place-items-center rounded-full bg-background text-sm font-medium">
                {(user.name || user.email).trim().slice(0, 2).toUpperCase()}
              </span>
              <div className="min-w-0">
                <p className="text-xs text-muted-foreground">Signed in as</p>
                {user.name && <p className="truncate text-sm font-medium">{user.name}</p>}
                <p className="break-all text-sm text-muted-foreground">{user.email}</p>
              </div>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="ghost" size="sm" disabled={busy !== null} onClick={() => void leaveAccount("switch")}>
                {busy === "switch" ? <Loader2 className="animate-spin" /> : <ArrowRightLeft />}Switch account
              </Button>
              <Button variant="ghost" size="sm" className="text-destructive hover:text-destructive" disabled={busy !== null} onClick={() => void leaveAccount("signout")}>
                {busy === "signout" ? <Loader2 className="animate-spin" /> : <LogOut />}Sign out
              </Button>
            </div>
          </div>
          <p className="text-sm leading-relaxed text-muted-foreground">Confirm that this code matches the one in your Mindwire app.</p>
          <p className="rounded-2xl bg-secondary px-4 py-5 text-center font-mono text-2xl font-medium tracking-wider" aria-label="Verification code">{code || "Missing code"}</p>
          <p className="text-xs leading-relaxed text-muted-foreground">Only approve a request you started yourself.</p>
          {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
          <div className="flex gap-3">
            <Button className="flex-1" disabled={busy !== null || !verified} onClick={() => void decide(true)}>
              {busy === "approve" && <Loader2 className="size-4 animate-spin" />}Sign in
            </Button>
            <Button variant="outline" disabled={busy !== null || !verified} onClick={() => void decide(false)}>
              {busy === "deny" && <Loader2 className="size-4 animate-spin" />}Cancel
            </Button>
          </div>
        </>}
      </CardContent>
    </Card>
  </main>;
}
