import { Link } from "react-router-dom";
import {
  ArrowRight,
  HardDrive,
  Monitor,
  Plus,
  ShieldCheck,
  Smartphone,
} from "lucide-react";
import { useCloud } from "@/lib/cloud";
import type { AuthUser } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { ComputerRow } from "../CloudComputers";
import { Loading, PageTitle, money } from "./common";

export function Overview({ user }: { user: AuthUser }) {
  const cloud = useCloud(),
    allocated = cloud.computers.filter(
      (c) => c.workspaceId && c.state !== "deleting",
    );
  return (
    <div className="space-y-8">
      <PageTitle
        title={`Welcome${user.name ? `, ${user.name.split(" ")[0]}` : ""}`}
        description="Your Mindwire account, connected devices and Cloud Computers in one place."
        action={
          <Button asChild>
            <Link to="/computers/new">
              <Plus />
              New computer
            </Link>
          </Button>
        }
      />
      {!cloud.loaded ? (
        <Loading />
      ) : (
        <div className="grid gap-4 sm:grid-cols-3">
          {[
            {
              icon: Monitor,
              label: "Cloud Computers",
              value: String(allocated.length),
              detail: "Managed in your account",
            },
            {
              icon: HardDrive,
              label: "Included storage",
              value: `${allocated.reduce((n, c) => n + c.plan.diskGb, 0)} GB`,
              detail: "Capacity across your computers",
            },
            {
              icon: ShieldCheck,
              label: "Current plan total",
              value: `${money(allocated.reduce((n, c) => n + c.plan.monthlyCents, 0))}/mo`,
              detail: "Each computer has its own plan",
            },
          ].map((item) => (
            <Card key={item.label}>
              <CardContent className="space-y-4 p-5">
                <div className="flex items-center gap-2 text-xs text-muted-foreground">
                  <item.icon className="size-4" />
                  {item.label}
                </div>
                <p className="text-3xl font-semibold tracking-tight">
                  {item.value}
                </p>
                <p className="text-xs text-muted-foreground">{item.detail}</p>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
      <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <section className="space-y-4">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-medium">Your computers</h2>
            <Link
              className="flex items-center gap-2 text-xs text-muted-foreground hover:text-foreground"
              to="/computers"
            >
              View all
              <ArrowRight className="size-3" />
            </Link>
          </div>
          <Card>
            <CardContent className="p-0">
              {cloud.computers.length ? (
                cloud.computers
                  .slice(0, 4)
                  .map((c) => <ComputerRow key={c.id} computer={c} />)
              ) : (
                <div className="space-y-4 p-7">
                  <Monitor className="size-6 text-muted-foreground" />
                  <h3 className="font-medium">
                    Make room for your next project
                  </h3>
                  <p className="max-w-md text-sm leading-relaxed text-muted-foreground">
                    Get a managed computer for development and agents, then
                    connect from Mindwire. Choose Linux or Mac with a monthly
                    plan.
                  </p>
                  <Button asChild variant="outline">
                    <Link to="/billing">
                      Explore plans
                      <ArrowRight />
                    </Link>
                  </Button>
                </div>
              )}
            </CardContent>
          </Card>
        </section>
        <aside className="space-y-4">
          <Card>
            <CardContent className="space-y-4 p-6">
              <Smartphone className="size-5 text-muted-foreground" />
              <h2 className="text-sm font-medium">
                Keep your connections in check
              </h2>
              <p className="text-sm leading-relaxed text-muted-foreground">
                Review the devices signed in to your account and remove
                connections you no longer use.
              </p>
              <Button asChild variant="outline" className="w-full">
                <Link to="/devices">
                  Manage devices
                  <ArrowRight />
                </Link>
              </Button>
            </CardContent>
          </Card>
          <a
            href="https://mindwire.sh/get-started"
            target="_blank"
            rel="noreferrer"
            className="flex items-center justify-between p-2 text-xs text-muted-foreground hover:text-foreground"
          >
            Get the Mindwire app
            <ArrowRight className="size-3" />
          </a>
        </aside>
      </div>
    </div>
  );
}
