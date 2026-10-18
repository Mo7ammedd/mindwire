import { useState } from "react";
import { Link, Navigate, NavLink, Route, Routes } from "react-router-dom";
import {
  ArrowUpRight,
  CreditCard,
  LayoutDashboard,
  LogOut,
  Monitor,
  Moon,
  Smartphone,
  Sun,
  UserRound,
} from "lucide-react";
import type { AuthUser } from "@/lib/api";
import { CloudProvider, useCloud } from "@/lib/cloud";
import { useTheme } from "@/lib/theme";
import { cn } from "@/lib/utils";
import { BrandMark } from "@/components/BrandMark";
import { Button } from "@/components/ui/button";
import { CloudComputers, NewComputer, Billing } from "../CloudComputers";
import { Overview } from "./Overview";
import { Account } from "./Account";
import { Devices } from "./Devices";
import { ComputerDetail } from "./ComputerDetail";
import { ErrorNotice } from "./common";

const navigation = [
  { to: "/", label: "Overview", icon: LayoutDashboard },
  { to: "/computers", label: "Cloud Computers", icon: Monitor },
  { to: "/devices", label: "Devices", icon: Smartphone },
  { to: "/billing", label: "Plans & billing", icon: CreditCard },
  { to: "/account", label: "Account", icon: UserRound },
];
export function Portal({
  user,
  onUpdated,
  onSignOut,
  onSignedOut,
}: {
  user: AuthUser;
  onUpdated: () => Promise<void>;
  onSignOut: () => Promise<void>;
  onSignedOut: () => void;
}) {
  return (
    <CloudProvider>
      <PortalShell
        user={user}
        onUpdated={onUpdated}
        onSignOut={onSignOut}
        onSignedOut={onSignedOut}
      />
    </CloudProvider>
  );
}
function PortalShell({
  user,
  onUpdated,
  onSignOut,
  onSignedOut,
}: Parameters<typeof Portal>[0]) {
  const { theme, toggle } = useTheme(),
    cloud = useCloud();
  const [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[15rem_minmax(0,1fr)]">
      <aside className="border-b border-border bg-card lg:sticky lg:top-0 lg:flex lg:h-dvh lg:flex-col lg:border-b-0 lg:border-r">
        <div className="flex items-center justify-between gap-4 px-5 py-6">
          <Link to="/" aria-label="Mindwire home">
            <BrandMark size={24} />
          </Link>
          <Button
            size="icon"
            variant="ghost"
            aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
            onClick={toggle}
          >
            {theme === "dark" ? <Sun /> : <Moon />}
          </Button>
        </div>
        <p className="hidden px-5 pb-5 text-xs text-muted-foreground lg:block">
          Your Mindwire account
        </p>
        <nav
          aria-label="Account navigation"
          className="flex gap-1 overflow-x-auto px-3 pb-3 lg:flex-col lg:overflow-visible lg:pb-0"
        >
          {navigation.map((item) => (
            <NavLink
              end={item.to === "/"}
              key={item.to}
              to={item.to}
              className={({ isActive }) =>
                cn(
                  "flex shrink-0 items-center gap-3 px-3 py-2.5 text-sm transition-colors",
                  isActive
                    ? "bg-secondary font-medium text-foreground"
                    : "text-muted-foreground hover:bg-accent/50 hover:text-foreground",
                )
              }
            >
              <item.icon className="size-4" />
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="mt-auto hidden space-y-5 p-5 lg:block">
          <a
            href="https://mindwire.sh/docs"
            target="_blank"
            rel="noreferrer"
            className="flex items-center justify-between text-xs text-muted-foreground hover:text-foreground"
          >
            Help & documentation
            <ArrowUpRight className="size-3" />
          </a>
          <div className="border-t border-border pt-5">
            <p className="truncate text-sm font-medium">
              {user.name || "Your account"}
            </p>
            <p className="mt-1 truncate text-xs text-muted-foreground">
              {user.email}
            </p>
          </div>
        </div>
      </aside>
      <div className="min-w-0">
        <header className="flex h-16 items-center justify-between gap-4 border-b border-border px-5 lg:px-9">
          <p className="truncate text-xs text-muted-foreground">{user.email}</p>
          <Button
            variant="ghost"
            size="sm"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              setError("");
              try {
                await onSignOut();
              } catch (error) {
                setError((error as Error).message);
              } finally {
                setBusy(false);
              }
            }}
          >
            <LogOut className="size-3.5" />
            Sign out
          </Button>
        </header>
        <main className="mx-auto max-w-6xl space-y-6 p-5 py-7 lg:p-9">
          {error && <ErrorNotice message={error} />}
          {cloud.error && (
            <ErrorNotice
              message={cloud.error}
              retry={() => void cloud.reload().catch(() => {})}
            />
          )}
          <Routes>
            <Route path="/" element={<Overview user={user} />} />
            <Route path="/computers" element={<CloudComputers />} />
            <Route path="/computers/new" element={<NewComputer />} />
            <Route path="/computers/:id" element={<ComputerDetail />} />
            <Route path="/billing" element={<Billing />} />
            <Route
              path="/devices"
              element={<Devices onSignedOut={onSignedOut} />}
            />
            <Route
              path="/account"
              element={<Account user={user} onUpdated={onUpdated} />}
            />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}
