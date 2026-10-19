import { useCallback, useEffect, useState } from "react";
import { Monitor, RefreshCw, ShieldCheck, Smartphone } from "lucide-react";
import { api, type AccountSession, type NotificationDevice } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { ConfirmAction, date, ErrorNotice, Loading, PageTitle } from "./common";

function deviceName(agent: string) {
  if (/iPhone/i.test(agent)) return "iPhone";
  if (/iPad/i.test(agent)) return "iPad";
  if (/Android/i.test(agent)) return "Android device";
  if (/Mindwire|CFNetwork/i.test(agent)) return "Mindwire app";
  if (/Macintosh|Mac OS X/i.test(agent)) return "Mac";
  if (/Windows/i.test(agent)) return "Windows computer";
  if (/Linux/i.test(agent)) return "Linux computer";
  return "Connected device";
}
export function Devices({ onSignedOut }: { onSignedOut: () => void }) {
  const [sessions, setSessions] = useState<AccountSession[]>([]),
    [devices, setDevices] = useState<NotificationDevice[]>([]);
  const [loaded, setLoaded] = useState(false),
    [error, setError] = useState("");
  const reload = useCallback(async () => {
    try {
      const [a, b] = await Promise.all([
        api.sessions(),
        api.notificationDevices(),
      ]);
      setSessions(a.sessions);
      setDevices(b.devices);
      setError("");
    } catch (error) {
      setError((error as Error).message);
    } finally {
      setLoaded(true);
    }
  }, []);
  useEffect(() => {
    void reload();
  }, [reload]);
  return (
    <div className="space-y-7">
      <PageTitle
        title="Devices"
        description="Manage the connections signed in to your Mindwire account."
        action={
          <Button variant="outline" onClick={() => void reload()}>
            <RefreshCw />
            Refresh
          </Button>
        }
      />
      {error && <ErrorNotice message={error} retry={() => void reload()} />}
      {!loaded ? (
        <Loading />
      ) : (
        <>
          <div className="grid items-start gap-6 min-[1250px]:grid-cols-[minmax(0,1fr)_19rem]">
            <section className="space-y-4">
              <h2 className="text-base font-medium">Signed-in devices</h2>
              <Card>
                <CardContent className="divide-y divide-border p-0">
                  {sessions.map((session) => (
                    <div
                      key={session.id}
                      className="flex flex-wrap items-center gap-4 p-5"
                    >
                      <span className="grid size-11 shrink-0 place-items-center rounded-2xl bg-[var(--mw-blue-soft)] text-[var(--mw-blue)]">
                        {/iPhone|iPad|Android/i.test(session.userAgent) ? (
                          <Smartphone className="size-4" />
                        ) : (
                          <Monitor className="size-4" />
                        )}
                      </span>
                      <div className="min-w-0 flex-1">
                        <p className="text-base font-medium">
                          {deviceName(session.userAgent)}
                          {session.current && (
                            <span className="ml-2 text-xs font-normal text-muted-foreground">
                              This connection
                            </span>
                          )}
                        </p>
                        <p className="mt-1 text-xs text-muted-foreground">
                          Signed in {date(session.createdAt)} · Last active{" "}
                          {date(session.lastActiveAt)}
                        </p>
                      </div>
                      <ConfirmAction
                        label="Sign out"
                        title={
                          session.current
                            ? "Sign out of this device?"
                            : "Sign out this device?"
                        }
                        description="This connection will need to sign in again. Your Cloud Computers and files are preserved."
                        onConfirm={async () => {
                          const result = await api.revokeSession(session.id);
                          if (result.current) onSignedOut();
                          else await reload();
                        }}
                      />
                    </div>
                  ))}
                  {!sessions.length && (
                    <p className="p-6 text-sm text-muted-foreground">
                      No active connections were returned. Refresh to check
                      again.
                    </p>
                  )}
                </CardContent>
              </Card>
              <p className="text-xs leading-relaxed text-muted-foreground">
                Each sign-in appears as a separate connection. Removing a
                connection does not stop your computers.
              </p>
            </section>
            <aside>
              <Card>
                <CardContent className="space-y-4 p-6">
                  <span className="grid size-11 place-items-center rounded-2xl bg-[var(--mw-mint-soft)] text-[var(--mw-mint)]"><ShieldCheck className="size-5" /></span>
                  <h2 className="text-base font-medium">
                    Your account stays with you
                  </h2>
                  <p className="text-sm leading-relaxed text-muted-foreground">
                    Sign out devices you no longer use. Personal computers
                    paired with the Mindwire app remain under your control in
                    the app.
                  </p>
                </CardContent>
              </Card>
            </aside>
          </div>
          <section className="space-y-4">
            <h2 className="text-base font-medium">Notification devices</h2>
            <Card>
              <CardContent className="divide-y divide-border p-0">
                {devices
                  .filter((d) => d.status === "active")
                  .map((device) => (
                    <div
                      key={device.id}
                      className="flex flex-wrap items-center gap-4 p-5"
                    >
                      <Smartphone className="size-5 text-muted-foreground" />
                      <div className="min-w-0 flex-1">
                        <p className="text-base font-medium">
                          {device.platform === "ios"
                            ? "Apple device"
                            : device.platform || "Mobile device"}
                        </p>
                        <p className="mt-1 text-xs text-muted-foreground">
                          Notifications enabled · Last registered{" "}
                          {date(device.last_seen_at ?? device.created_at)}
                        </p>
                      </div>
                      <ConfirmAction
                        label="Remove"
                        title="Remove this notification device?"
                        description="This device will stop receiving push notifications until it registers again. This does not sign it out."
                        onConfirm={async () => {
                          await api.removeNotificationDevice(device.id);
                          await reload();
                        }}
                      />
                    </div>
                  ))}
                {!devices.some((d) => d.status === "active") && (
                  <p className="p-6 text-sm text-muted-foreground">
                    Sign in to the Mindwire app and enable notifications to
                    connect a device here.
                  </p>
                )}
              </CardContent>
            </Card>
          </section>
        </>
      )}
    </div>
  );
}
