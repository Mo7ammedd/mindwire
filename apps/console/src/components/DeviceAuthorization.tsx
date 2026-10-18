import { useEffect, useState } from "react";
import { Check, Loader2, Monitor } from "lucide-react";
import { BrandMark } from "@/components/BrandMark";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

/** The verification code is public. Device secrets and account tokens never enter this page's URL. */
export function DeviceAuthorization({ email }: { email: string }) {
  const code = new URLSearchParams(window.location.search).get("user_code") ?? "";
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState("");
  const [verified, setVerified] = useState(false);
  useEffect(() => {
    if (!code) return;
    const controller = new AbortController();
    fetch(`/api/account/device?user_code=${encodeURIComponent(code)}`, { credentials: "same-origin", signal: controller.signal })
      .then(response => { if (!response.ok) throw new Error("This sign-in request expired or belongs to another account. Start again from Mindwire."); setVerified(true); })
      .catch(error => { if (!controller.signal.aborted) setError(error.message); });
    return () => controller.abort();
  }, [code]);
  async function decide(approve: boolean) {
    setBusy(true); setError("");
    try {
      const response = await fetch(`/api/account/device/${approve ? "approve" : "deny"}`, {
        method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ userCode: code }),
      });
      if (!response.ok) throw new Error("This sign-in request expired or could not be approved. Start again from Mindwire.");
      setDone(true);
    } catch (e) { setError(e instanceof Error ? e.message : "Could not finish sign-in."); }
    finally { setBusy(false); }
  }
  return <main className="grid min-h-dvh place-items-center p-5">
    <Card className="w-full max-w-md">
      <CardHeader className="space-y-5"><BrandMark size={24} /><CardTitle className="flex items-center gap-2">
        {done ? <Check className="size-5" /> : <Monitor className="size-5" />}
        {done ? "Return to Mindwire" : "Sign in on your device"}
      </CardTitle></CardHeader>
      <CardContent className="space-y-5">
        {done ? <p className="text-sm text-muted-foreground">Your choice is saved. You can close this window.</p> : <>
          <p className="text-sm text-muted-foreground">Continue as {email}. Approve only if you started this request in Mindwire and the code matches your device.</p>
          <p className="text-center text-2xl font-semibold tracking-widest" aria-label="Verification code">{code || "Missing code"}</p>
          {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
          <div className="flex gap-3"><Button className="flex-1" disabled={busy || !verified} onClick={() => void decide(true)}>
            {busy && <Loader2 className="size-4 animate-spin" />}Sign in
          </Button><Button variant="outline" disabled={busy || !verified} onClick={() => void decide(false)}>Cancel</Button></div>
        </>}
      </CardContent>
    </Card>
  </main>;
}
