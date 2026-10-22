import { useCallback, useEffect, useState } from "react";
import { useLocation } from "react-router-dom";
import { api, type AuthUser } from "@/lib/api";
import { AuthScreen } from "@/components/AuthScreen";
import { DeviceAuthorization } from "@/components/DeviceAuthorization";
import { Portal } from "@/components/portal/Portal";
import { ErrorNotice, Loading } from "@/components/portal/common";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";

export default function App() {
  const [user, setUser] = useState<AuthUser | null>(),
    [error, setError] = useState("");
  const location = useLocation();
  const isRecovery = ["/forgot-password", "/reset-password"].includes(location.pathname);
  const signOut = useCallback(async () => {
    await api.account.signOut();
    setUser(null);
  }, []);
  const refreshAccount = useCallback(async () => {
    try {
      const result = await api.account.me();
      setUser(result?.user ?? null);
      setError("");
    } catch (error) {
      setError((error as Error).message);
    }
  }, []);
  useEffect(() => {
    if (!isRecovery) void refreshAccount();
  }, [refreshAccount, isRecovery]);
  return (
    <TooltipProvider>
      {isRecovery ? (
        <AuthScreen onAuthed={setUser} onPasswordReset={() => setUser(null)} />
      ) : user === undefined ? (
        <div className="mx-auto flex min-h-dvh max-w-lg items-center px-5">
          {error ? (
            <ErrorNotice message={error} retry={() => void refreshAccount()} />
          ) : (
            <Loading />
          )}
        </div>
      ) : user === null ? (
        <AuthScreen onAuthed={setUser} />
      ) : location.pathname === "/device" ? (
        <DeviceAuthorization key={user.id} user={user} onSignOut={signOut} />
      ) : (
        <Portal
          user={user}
          onUpdated={refreshAccount}
          onSignedOut={() => setUser(null)}
          onSignOut={signOut}
        />
      )}
      <Toaster />
    </TooltipProvider>
  );
}
