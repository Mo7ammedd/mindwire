import { useCallback, useEffect, useState } from "react";
import { ArrowLeft, ExternalLink, Loader2, Monitor, RefreshCw } from "lucide-react";
import type { CloudComputer, ComputerPlan } from "@shared/cloud";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { BrandMark } from "@/components/BrandMark";

async function request<T>(path: string, method = "GET", body?: object): Promise<T> {
  const response = await fetch(`/api/cloud${path}`, { method, credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error ?? "Could not load Cloud Computers. Try again.");
  return data as T;
}

export function CloudComputers({ email, onSignOut }: { email: string; onSignOut: () => void }) {
  const [catalog, setCatalog] = useState<{ available: boolean; plans: ComputerPlan[] }>();
  const [computers, setComputers] = useState<CloudComputer[]>([]);
  const [images, setImages] = useState<Array<{ id: string; image: string; label: string; base_os?: { family: string }; minimum_resources?: { cpus?: number; memory_mb?: number; disk_size_mb?: number } }>>([]);
  const [name, setName] = useState("My computer"), [planId, setPlan] = useState(() => { const plan = new URLSearchParams(window.location.search).get("plan"); return ["essential", "pro", "max"].includes(plan ?? "") ? plan! : "essential"; }), [image, setImage] = useState("");
  const [error, setError] = useState(""), [busy, setBusy] = useState<string | null>(null), [loaded, setLoaded] = useState(false);
  const [purchaseKey, setPurchaseKey] = useState(() => crypto.randomUUID());
  const reload = useCallback(async () => {
    const result = await request<{ computers: CloudComputer[] }>("/computers"); setComputers(result.computers);
  }, []);
  useEffect(() => {
    let disposed = false;
    (async () => {
      try {
        const pricing = await request<{ available: boolean; plans: ComputerPlan[] }>("/catalog");
        if (disposed) return;
        setCatalog(pricing); await reload();
        if (pricing.available) {
          const result = await request<{ images: typeof images }>("/provider/workspace/images?monthly=true");
          if (!disposed) { setImages(result.images); setImage(result.images[0]?.id ?? ""); }
        }
      } catch (error) { if (!disposed) setError((error as Error).message); }
      finally { if (!disposed) setLoaded(true); }
    })();
    return () => { disposed = true; };
  }, [reload]);
  const pending = computers.some(c => ["checkout_pending", "payment_pending", "paid", "provisioning"].includes(c.state));
  useEffect(() => {
    if (!pending) return;
    let running = false;
    const timer = setInterval(async () => {
      if (running || document.hidden) return;
      running = true;
      try {
        for (const computer of computers.filter(c => ["checkout_pending", "payment_pending", "paid", "provisioning"].includes(c.state)))
          await request(`/computers/${computer.id}/reconcile`, "POST");
        await reload();
      } catch (error) { setError((error as Error).message); }
      finally { running = false; }
    }, 5000);
    return () => clearInterval(timer);
  }, [pending, computers, reload]);
  async function action(id: string, operation: string) {
    setBusy(id); setError("");
    try {
      const result = await request<{ url?: string; computer?: CloudComputer }>(`/computers/${id}/${operation}`, "POST");
      if (result.url) window.location.assign(result.url);
      else if (operation === "checkout" && result.computer?.checkout) window.location.assign(result.computer.checkout.url);
      await reload();
    } catch (error) { setError((error as Error).message); }
    finally { setBusy(null); }
  }
  const selectedImage = images.find(i => i.id === image);
  const fitsImage = (plan: ComputerPlan) => plan.vcpus >= (selectedImage?.minimum_resources?.cpus ?? 0) && plan.memoryMb >= (selectedImage?.minimum_resources?.memory_mb ?? 0) && plan.diskGb * 1024 >= (selectedImage?.minimum_resources?.disk_size_mb ?? 0);
  async function purchase() {
    setBusy("new"); setError("");
    try {
      const result = await request<{ computer: CloudComputer }>("/computers", "POST", { name, imageId: image, planId, idempotencyKey: purchaseKey });
      await reload(); await action(result.computer.id, "checkout");
      setPurchaseKey(crypto.randomUUID());
    } catch (error) { setError((error as Error).message); }
    finally { setBusy(null); }
  }
  return <main className="mx-auto min-h-dvh max-w-6xl space-y-8 p-5 md:p-10">
    <header className="flex flex-wrap items-center justify-between gap-4"><a href="/" className="flex items-center gap-3 text-sm"><BrandMark size={24} /><ArrowLeft className="size-4" /> Console</a><div className="flex items-center gap-3 text-sm text-muted-foreground"><span>{email}</span><Button variant="ghost" size="sm" onClick={onSignOut}>Sign out</Button></div></header>
    <div><h1 className="text-2xl font-semibold">Cloud Computers</h1><p className="mt-2 text-sm text-muted-foreground">A computer for your projects, agents and development tools. One monthly subscription per computer.</p></div>
    {error && <div role="alert" className="flex items-center justify-between gap-4 border border-destructive/30 p-4 text-sm"><p>{error}</p><Button size="sm" variant="outline" onClick={() => void reload().then(() => setError("")).catch(e => setError(e.message))}>Retry</Button></div>}
    {!loaded ? <Loader2 className="size-5 animate-spin" /> : <div className="grid gap-8 lg:grid-cols-[1fr_22rem]">
      <section className="space-y-4"><div className="flex items-center justify-between"><h2 className="font-medium">Your computers</h2><Button size="sm" variant="ghost" onClick={() => void reload().catch(e => setError(e.message))}><RefreshCw className="size-4" />Refresh</Button></div>
        {!computers.length && <Card><CardContent className="space-y-3 py-10 text-center"><Monitor className="mx-auto size-8 text-muted-foreground" /><p>No Cloud Computers yet</p><p className="text-sm text-muted-foreground">Choose a plan to get started. Your own computers and SSH connections stay free.</p></CardContent></Card>}
        {computers.map(computer => <Card key={computer.id}><CardHeader><CardTitle className="flex items-center justify-between gap-4 text-base"><span>{computer.name}</span><span className="text-xs font-normal capitalize text-muted-foreground">{computer.state.replaceAll("_", " ")}</span></CardTitle></CardHeader><CardContent className="space-y-4"><p className="text-sm text-muted-foreground">{computer.plan.name} · {computer.plan.vcpus} vCPU · {computer.plan.memoryMb / 1024} GB RAM · {computer.plan.diskGb} GB storage · ${computer.plan.monthlyCents / 100}/month</p>
          {computer.subscription?.paidThrough && <p className="text-sm text-muted-foreground">{computer.subscription.cancelAtPeriodEnd ? "Renewal stopped. Paid through " : "Next renewal "}{new Date(computer.subscription.paidThrough).toLocaleDateString()}</p>}
          {computer.error && <p role="status" className="text-sm text-muted-foreground">{computer.error}</p>}
          <div className="flex flex-wrap gap-2">{["paid", "provisioning"].includes(computer.state) && <Button size="sm" variant="outline" disabled={busy !== null} onClick={() => void action(computer.id, "reconcile")}>Check setup</Button>}{["draft", "checkout_pending", "payment_pending"].includes(computer.state) ? <><Button size="sm" disabled={busy !== null} onClick={() => void action(computer.id, "checkout")}>{busy === computer.id && <Loader2 className="size-4 animate-spin" />}Continue checkout<ExternalLink className="size-3" /></Button>{(["draft", "checkout_pending", "payment_pending"].includes(computer.state)) && <Button size="sm" variant="ghost" disabled={busy !== null} onClick={() => void action(computer.id, "checkout/cancel")}>Cancel checkout</Button>}</> : <><Button size="sm" variant="outline" disabled={busy !== null} onClick={() => void action(computer.id, "billing-portal")}>Manage billing</Button><Button size="sm" disabled={busy !== null || !computer.workspaceId} onClick={() => void action(computer.id, "use")}>Use in Console</Button><Button size="sm" variant="ghost" disabled={busy !== null} onClick={() => void action(computer.id, `subscription/${computer.subscription?.cancelAtPeriodEnd ? "resume" : "cancel"}`)}>{computer.subscription?.cancelAtPeriodEnd ? "Resume renewal" : "Stop renewal"}</Button></>}</div>
        </CardContent></Card>)}
      </section>
      <aside><Card><CardHeader><CardTitle className="text-base">New Cloud Computer</CardTitle></CardHeader><CardContent className="space-y-5">
        {!catalog?.available ? <p className="text-sm text-muted-foreground">Cloud Computer purchases are not enabled on this Console yet.</p> : <>
          <label className="block space-y-2 text-sm"><span>Name</span><Input value={name} maxLength={100} onChange={e => { setName(e.target.value); setPurchaseKey(crypto.randomUUID()); }} /></label>
          <label className="block space-y-2 text-sm"><span>Image</span><select aria-label="Image" className="h-9 w-full border border-input bg-background px-3" value={image} onChange={e => { setImage(e.target.value); setPurchaseKey(crypto.randomUUID()); }}>{images.map(i => <option key={i.id} value={i.id}>{i.label || i.id}</option>)}</select></label>
          {selectedImage?.minimum_resources && <p className="text-xs text-muted-foreground">This image requires at least {selectedImage.minimum_resources.cpus ?? 1} vCPU and {(selectedImage.minimum_resources.memory_mb ?? 1024) / 1024} GB RAM. Choose a compatible plan below.</p>}
          <fieldset className="space-y-2"><legend className="mb-2 text-sm">Monthly plan</legend>{catalog.plans.map(plan => <label key={plan.id} className="flex cursor-pointer items-center gap-3 border border-input p-3 has-checked:border-primary"><input type="radio" name="plan" value={plan.id} disabled={!fitsImage(plan)} checked={planId === plan.id} onChange={() => { setPlan(plan.id); setPurchaseKey(crypto.randomUUID()); }} /><span className="flex-1 text-sm"><span className="font-medium">{plan.name}</span><span className="mt-1 block text-xs text-muted-foreground">{plan.vcpus} vCPU · {plan.memoryMb / 1024} GB RAM · {plan.diskGb} GB</span></span><span className="text-sm">${plan.monthlyCents / 100}<span className="text-muted-foreground">/mo</span></span></label>)}</fieldset>
          <Button className="w-full" disabled={busy !== null || !image || !name.trim() || !catalog.plans.some(p => p.id === planId && fitsImage(p))} onClick={() => void purchase()}>{busy === "new" && <Loader2 className="size-4 animate-spin" />}Continue to checkout</Button>
          <p className="text-xs leading-relaxed text-muted-foreground">Shared CPU, RAM and included storage are covered for the paid month. Transfer and retained storage follow the subscription terms. Data retention follows the saved subscription terms.</p>
        </>}
      </CardContent></Card></aside>
    </div>}
  </main>;
}
