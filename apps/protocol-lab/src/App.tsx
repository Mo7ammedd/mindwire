import { useCallback, useEffect, useMemo, useState } from "react";
import { DaemonClient } from "./lib/daemon";
import type { AgentInfo, ChatSummary } from "./lib/types";
import { AgentCard } from "./components/AgentCard";
import { AuthCard } from "./components/AuthCard";
import { SetupCard } from "./components/SetupCard";
import { SettingsCard } from "./components/SettingsCard";
import { DoctorCard } from "./components/DoctorCard";
import { SessionsCard } from "./components/SessionsCard";
import { Notifications } from "./components/Notifications";
import { Chat } from "./components/Chat";

const LS = { url: "mindwire.daemonURL", token: "mindwire.token" };
const newChatId = () => "web-" + Math.random().toString(36).slice(2, 8);

export function App() {
  const [url, setUrl] = useState(() => localStorage.getItem(LS.url) || "http://localhost:8790");
  const [token, setToken] = useState(() => localStorage.getItem(LS.token) || "");
  const [info, setInfo] = useState<AgentInfo | null>(null);
  const [chats, setChats] = useState<ChatSummary[]>([]);
  const [chatId, setChatId] = useState(newChatId);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const client = useMemo(() => new DaemonClient(url, token), [url, token]);

  const loadChats = useCallback(() => {
    client.chats().then(setChats).catch(() => setChats([]));
  }, [client]);

  const reload = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setInfo(await client.agent());
      loadChats();
    } catch (e) {
      setError((e as Error).message);
      setInfo(null);
    } finally {
      setLoading(false);
    }
  }, [client, loadChats]);

  useEffect(() => { localStorage.setItem(LS.url, url); }, [url]);
  useEffect(() => { localStorage.setItem(LS.token, token); }, [token]);
  useEffect(() => { void reload(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="app">
      <header>
        <h1><span className="brand">●</span> Mindwire — Web Console</h1>
        <input className="grow" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="daemon URL" style={{ maxWidth: 280 }} />
        <input value={token} onChange={(e) => setToken(e.target.value)} placeholder="bearer token (blank in dev)" style={{ maxWidth: 220 }} />
        <button onClick={() => void reload()} disabled={loading}>{loading ? "…" : "Connect"}</button>
      </header>

      {error && (
        <div className="banner err">
          {error} — is the daemon running with <code>DEV_CORS=1</code> at this URL?
        </div>
      )}

      <main>
        <div className="col">
          <SessionsCard chats={chats} activeChatId={chatId} onSelect={setChatId} onNew={() => setChatId(newChatId())} />
          <Notifications client={client} />
          <AgentCard info={info} />
          <DoctorCard client={client} />
          <SetupCard client={client} onChange={reload} />
          <AuthCard client={client} info={info} onChange={reload} />
          <SettingsCard client={client} info={info} onChange={reload} />
        </div>
        <div className="col">
          <Chat client={client} info={info} chatId={chatId} onActivity={loadChats} />
        </div>
      </main>
    </div>
  );
}
