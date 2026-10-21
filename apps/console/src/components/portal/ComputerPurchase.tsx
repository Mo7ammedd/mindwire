import { Link } from "react-router-dom";
import { ArrowLeft, ArrowUpRight, Loader2, RefreshCw } from "lucide-react";
import type { CloudComputer } from "@shared/cloud";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { ConfirmAction, ErrorNotice, money, PageTitle } from "./common";

export function ComputerPurchase({
  computer,
  busy,
  error,
  onContinue,
  onRefresh,
  onCancel,
}: {
  computer: CloudComputer;
  busy: boolean;
  error?: string;
  onContinue: () => Promise<void>;
  onRefresh: () => Promise<void>;
  onCancel: () => Promise<void>;
}) {
  const purchase = computer.purchase;
  const status =
    purchase?.status ??
    (computer.state === "payment_pending" ? "awaiting_payment" : "draft");
  const canContinue = purchase?.canContinue ?? true;
  const canCancel = purchase?.canCancel ?? true;
  const title = {
    draft: error ? "Checkout needs attention" : "Ready to check out",
    recovering: "Checkout not confirmed",
    awaiting_payment: "Finish your purchase",
    processing: "Confirming payment",
    expired: "Checkout expired",
    canceling: "Canceling purchase",
  }[status];
  const detail = {
    draft:
      "Continue to secure checkout, or cancel this purchase to choose another computer or plan.",
    recovering:
      "Your purchase is saved. Resume checkout to confirm the payment before continuing or canceling.",
    awaiting_payment:
      "Complete secure checkout to set up your computer. Returning here does not confirm a payment.",
    processing:
      "We’re checking your payment before setting up the computer. You don’t need to pay again.",
    expired:
      "This payment link has expired. Cancel this purchase before choosing a new computer or plan.",
    canceling:
      "We’re confirming cancellation with the payment provider. Refresh to check its progress.",
  }[status];
  return (
    <div className="max-w-3xl space-y-6">
      <Button asChild size="sm" variant="ghost">
        <Link to="/computers">
          <ArrowLeft />
          All computers
        </Link>
      </Button>
      <PageTitle
        title={computer.name}
        description="Your Cloud Computer purchase"
      />
      <Card>
        <CardContent className="space-y-6 p-6 sm:p-8">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p className="text-sm text-muted-foreground">
                {computer.plan.name}
              </p>
              <p className="mt-2 text-3xl font-medium">
                {money(computer.plan.monthlyCents)}
                <span className="text-sm font-normal text-muted-foreground">
                  {" "}
                  /month
                </span>
              </p>
            </div>
            <p className="rounded-full bg-secondary px-3 py-1.5 text-xs">
              {title}
            </p>
          </div>
          <p className="text-sm text-muted-foreground">
            {computer.plan.vcpus} shared vCPU · {computer.plan.memoryMb / 1024}{" "}
            GB RAM · {computer.plan.diskGb} GB storage
          </p>
          <div className="space-y-2 border-t border-border pt-6">
            <h2 className="text-lg font-medium">{title}</h2>
            <p className="text-sm leading-relaxed text-muted-foreground">
              {detail}
            </p>
          </div>
          {error && (
            <ErrorNotice
              message={error}
              reference={purchase?.error?.reference}
            />
          )}
          <div className="flex flex-wrap gap-3">
            {canContinue ? (
              <Button disabled={busy} onClick={() => void onContinue()}>
                {busy ? <Loader2 className="animate-spin" /> : <ArrowUpRight />}
                {status === "recovering"
                  ? "Resume checkout"
                  : "Continue checkout"}
              </Button>
            ) : (
              status !== "expired" && (
                <Button disabled={busy} onClick={() => void onRefresh()}>
                  {busy ? <Loader2 className="animate-spin" /> : <RefreshCw />}
                  {status === "processing" ? "Check payment" : "Check status"}
                </Button>
              )
            )}
            {status !== "processing" && (
              <ConfirmAction
                label={
                  status === "canceling"
                    ? "Retry cancellation"
                    : "Cancel purchase"
                }
                title="Cancel this purchase?"
                cancelLabel="Keep purchase"
                description="We’ll confirm that payment hasn’t completed before closing this purchase. Your other computers are unaffected."
                disabled={busy || !canCancel}
                onConfirm={onCancel}
              />
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
