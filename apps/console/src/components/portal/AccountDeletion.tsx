import { useEffect, useState, type FormEvent } from "react";
import { Loader2, Trash2 } from "lucide-react";
import { toast } from "sonner";
import type { AccountDeletionOptions, AccountDeletionRequest, SocialProvider } from "@shared/api";
import { api } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { ErrorNotice } from "./common";

export function AccountDeletion({ userId, onDeleted }: { userId: string; onDeleted: () => void }) {
  const [open, setOpen] = useState(new URLSearchParams(location.search).has("deleteAccount"));
  const [options, setOptions] = useState<AccountDeletionOptions>();
  const [progress, setProgress] = useState<AccountDeletionRequest>();
  const [confirmation, setConfirmation] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let live = true;
    api.account.deletionOptions().then(async value => {
      if (!live) return;
      const expected = sessionStorage.getItem("mindwire.delete.expectedUser");
      if (expected && expected !== userId) {
        setError("You signed in to a different account. Return to the account you want to delete.");
        setOpen(false);
      }
      sessionStorage.removeItem("mindwire.delete.expectedUser");
      setOptions(value);
      if (value.status === "pending") {
        const pending = await api.account.delete(userId);
        if (live) setProgress(pending);
      }
    }).catch(reason => { if (live) setError((reason as Error).message); });
    return () => { live = false; };
  }, [userId, reload]);

  useEffect(() => {
    if (!progress) return;
    let live = true;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        const value = await api.account.deletionProgress(progress.receipt);
        if (!live) return;
        if (value.status === "deleted") {
          toast.success(value.message);
          onDeleted();
          return;
        }
        setProgress(previous => previous ? { ...previous, ...value } : previous);
        setError("");
      } catch { if (live) setError("Progress is temporarily unavailable. Cleanup continues automatically."); }
      if (live) timer = setTimeout(() => void poll(), 5000);
    };
    timer = setTimeout(() => void poll(), 3000);
    return () => { live = false; clearTimeout(timer); };
  }, [progress?.receipt, onDeleted]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy || confirmation !== "DELETE") return;
    setBusy(true); setError("");
    try {
      setProgress(await api.account.delete(userId, password || undefined));
      setPassword(""); setConfirmation(""); setOpen(false);
    } catch (reason) { setError((reason as Error).message); }
    finally { setBusy(false); }
  }

  async function signIn(provider: SocialProvider) {
    setBusy(true); setError("");
    try {
      sessionStorage.setItem("mindwire.delete.expectedUser", userId);
      const value = await api.account.socialSignIn(provider, new URL("/account?deleteAccount=1", location.origin).href);
      if (!value.url) throw new Error("Could not open sign-in. Please retry.");
      location.assign(value.url);
    } catch (reason) { setError((reason as Error).message); setBusy(false); }
  }

  return <Card className="border-destructive/20">
    <CardContent className="space-y-4 p-6">
      <h2 className="text-base font-medium">Delete account</h2>
      {progress ? <div role="status" className="flex items-start gap-3 text-sm text-muted-foreground">
        <Loader2 className="mt-0.5 size-4 shrink-0 animate-spin" /><p>{progress.message}</p>
      </div> : <>
        <p className="text-sm leading-relaxed text-muted-foreground">Permanently delete your Mindwire account, Cloud Computers and hosted data.</p>
        <Button variant="destructive" disabled={!options || busy} onClick={() => { setError(""); setOpen(true); }}><Trash2 />Delete account</Button>
      </>}
      {error && !open && <><ErrorNotice message={error} />{!options && <Button variant="outline" onClick={() => setReload(value => value + 1)}>Retry</Button>}</>}
    </CardContent>
    <Dialog open={open} onOpenChange={value => { if (!busy) { setOpen(value); setPassword(""); setConfirmation(""); } }}>
      <DialogContent onEscapeKeyDown={event => { if (busy) event.preventDefault(); }} onInteractOutside={event => { if (busy) event.preventDefault(); }}>
        <DialogHeader>
          <DialogTitle>Delete your Mindwire account?</DialogTitle>
          <DialogDescription>This is permanent. Save anything you want to keep first.</DialogDescription>
        </DialogHeader>
        <ul className="list-disc space-y-2 pl-5 text-sm leading-relaxed text-muted-foreground">
          <li>Your profile, sessions, saved credentials and notification registrations will be deleted.</li>
          <li>Mindwire Cloud renewals will stop. Your Cloud Computers, files, backups and published apps will be permanently removed.</li>
          <li>Your personal computers and separate AI or Oblien accounts stay yours. Billing records required by law may be retained.</li>
        </ul>
        {error && <ErrorNotice message={error} />}
        {!options?.hasPassword && options?.needsSignIn ? <div className="space-y-3">
          <p className="text-sm">Verify your identity, then return here to confirm deletion.</p>
          {options.socials.map(provider => <Button key={provider} disabled={busy} variant="outline" onClick={() => void signIn(provider)}>
            {busy && <Loader2 className="animate-spin" />}Sign in again with {provider === "github" ? "GitHub" : provider === "apple" ? "Apple" : "Google"}
          </Button>)}
        </div> : <form onSubmit={event => void submit(event)} className="space-y-4">
          {options?.hasPassword && <label className="block space-y-2 text-sm">Mindwire password
            <Input type="password" autoComplete="current-password" value={password} disabled={busy} required onChange={event => setPassword(event.target.value)} />
          </label>}
          <label className="block space-y-2 text-sm">Type DELETE to confirm
            <Input value={confirmation} autoComplete="off" spellCheck={false} disabled={busy} onChange={event => setConfirmation(event.target.value)} />
          </label>
          <p className="text-xs leading-relaxed text-muted-foreground">Cleanup starts after confirmation and continues if you close this page. It usually takes a few minutes; Cloud cleanup can take longer.</p>
          <DialogFooter>
            <Button type="button" variant="outline" disabled={busy} onClick={() => { setOpen(false); setPassword(""); setConfirmation(""); }}>Cancel</Button>
            <Button type="submit" variant="destructive" disabled={busy || confirmation !== "DELETE" || !options || (options.hasPassword && !password)}>
              {busy && <Loader2 className="animate-spin" />}Permanently delete account
            </Button>
          </DialogFooter>
        </form>}
      </DialogContent>
    </Dialog>
  </Card>;
}
