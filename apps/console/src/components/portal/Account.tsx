import { useState, type FormEvent } from "react";
import { Check, Loader2, ShieldCheck } from "lucide-react";
import { api, type AuthUser } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { PageTitle, ErrorNotice } from "./common";
import { AccountDeletion } from "./AccountDeletion";

export function Account({
  user,
  onUpdated,
  onDeleted,
}: {
  user: AuthUser;
  onUpdated: () => Promise<void>;
  onDeleted: () => void;
}) {
  const [name, setName] = useState(user.name),
    [password, setPassword] = useState(""),
    [nextPassword, setNextPassword] = useState("");
  const [busy, setBusy] = useState(""),
    [error, setError] = useState(""),
    [saved, setSaved] = useState("");
  async function submit(event: FormEvent, kind: "profile" | "password") {
    event.preventDefault();
    setBusy(kind);
    setError("");
    setSaved("");
    try {
      if (kind === "profile") {
        await api.account.update(name.trim());
        await onUpdated();
      } else {
        await api.account.changePassword(password, nextPassword);
        setPassword("");
        setNextPassword("");
      }
      setSaved(kind);
    } catch (error) {
      setError((error as Error).message);
    } finally {
      setBusy("");
    }
  }
  return (
    <div className="space-y-7">
      <PageTitle
        title="Account"
        description="Manage your Mindwire profile and sign-in security."
      />
      {error && <ErrorNotice message={error} />}
      <div className="grid items-start gap-6 min-[1250px]:grid-cols-[minmax(0,1fr)_19rem]">
        <div className="space-y-6">
          <Card>
            <CardContent className="p-6">
              <form
                onSubmit={(e) => void submit(e, "profile")}
                className="space-y-5"
              >
                <h2 className="text-base font-medium">Your profile</h2>
                <label className="block space-y-2 text-sm">
                  <span>Name</span>
                  <Input
                    autoComplete="name"
                    value={name}
                    maxLength={100}
                    required
                    onChange={(e) => setName(e.target.value)}
                  />
                </label>
                <label className="block space-y-2 text-sm">
                  <span>Email</span>
                  <Input
                    value={user.email}
                    type="email"
                    readOnly
                    className="text-muted-foreground"
                  />
                </label>
                <div className="flex items-center gap-3">
                  <Button
                    disabled={
                      !!busy || !name.trim() || name.trim() === user.name
                    }
                    type="submit"
                  >
                    {busy === "profile" && <Loader2 className="animate-spin" />}
                    Save changes
                  </Button>
                  {saved === "profile" && (
                    <span
                      role="status"
                      className="flex items-center gap-1 text-xs text-muted-foreground"
                    >
                      <Check className="size-3" />
                      Saved
                    </span>
                  )}
                </div>
              </form>
            </CardContent>
          </Card>
          <Card>
            <CardContent className="p-6">
              <form
                onSubmit={(e) => void submit(e, "password")}
                className="space-y-5"
              >
                <h2 className="text-base font-medium">Change password</h2>
                <p className="text-xs leading-relaxed text-muted-foreground">
                  For accounts using an email and password. Social sign-in
                  credentials are managed by your sign-in provider.
                </p>
                <label className="block space-y-2 text-sm">
                  <span>Current password</span>
                  <Input
                    type="password"
                    autoComplete="current-password"
                    required
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                  />
                </label>
                <label className="block space-y-2 text-sm">
                  <span>New password</span>
                  <Input
                    type="password"
                    autoComplete="new-password"
                    minLength={8}
                    required
                    value={nextPassword}
                    onChange={(e) => setNextPassword(e.target.value)}
                  />
                </label>
                <div className="flex flex-wrap items-center gap-3">
                  <Button
                    variant="outline"
                    type="submit"
                    disabled={!!busy || !password || nextPassword.length < 8}
                  >
                    {busy === "password" && (
                      <Loader2 className="animate-spin" />
                    )}
                    Update password
                  </Button>
                  {saved === "password" && (
                    <span
                      role="status"
                      className="text-xs text-muted-foreground"
                    >
                      Password updated. Other connections were signed out.
                    </span>
                  )}
                </div>
              </form>
            </CardContent>
          </Card>
          <AccountDeletion userId={user.id} onDeleted={onDeleted} />
        </div>
        <aside>
          <Card>
            <CardContent className="space-y-4 p-6">
              <span className="grid size-11 place-items-center rounded-2xl bg-[var(--mw-mint-soft)] text-[var(--mw-mint)]"><ShieldCheck className="size-5" /></span>
              <h2 className="text-base font-medium">One Mindwire account</h2>
              <p className="text-sm leading-relaxed text-muted-foreground">
                Your profile connects your app, devices and Cloud subscriptions.
                Changing your profile does not affect your computers or data.
              </p>
            </CardContent>
          </Card>
        </aside>
      </div>
    </div>
  );
}
