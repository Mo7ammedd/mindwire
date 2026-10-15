import type { ChatSummary } from "../lib/types";

export function SessionsCard({
  chats, activeChatId, onSelect, onNew,
}: {
  chats: ChatSummary[];
  activeChatId: string;
  onSelect: (id: string) => void;
  onNew: () => void;
}) {
  // Ensure the active chat shows even before its first message is recorded.
  const list = chats.some((c) => c.chatId === activeChatId)
    ? chats
    : [{ chatId: activeChatId, title: "New chat", messages: 0, updatedAt: "" } as ChatSummary, ...chats];

  return (
    <div className="card">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h2 style={{ margin: 0 }}>Sessions</h2>
        <button className="primary" onClick={onNew}>+ New</button>
      </div>
      <div className="sessions">
        {list.length === 0 && <div className="muted">No sessions yet.</div>}
        {list.map((c) => (
          <button
            key={c.chatId}
            className={"session " + (c.chatId === activeChatId ? "active" : "")}
            onClick={() => onSelect(c.chatId)}
          >
            <div className="session-title">{c.title}</div>
            <div className="session-meta">
              {c.messages} msg{c.lastStatus ? ` · ${c.lastStatus}` : ""}
            </div>
          </button>
        ))}
      </div>
    </div>
  );
}
