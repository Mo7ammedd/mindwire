import { expect, test } from "bun:test";
import { Mindwire, remote, type Bot, type WorkspaceSnapshot } from "../src/index.js";

test("General bots retain chat membership and use conditional updates across harness views", async () => {
  const bot: Bot = { id: "bot", workspaceId: "db", agentId: "agent", projectId: "project", name: "Writer",
    purpose: "Write clearly", icon: "lilac-bloom", instructions: "Ask about the audience", memory: "Short answers", knowledge: [],
    isMaster: false, archived: false, createdAt: "2026-10-01T00:00:00Z", revision: 2 };
  const snapshot: WorkspaceSnapshot = { version: 1, workspaceId: "db", revision: 2, full: true,
    agents: [], projects: [], chats: [], bots: [bot], deleted: [] };
  const calls: { method: string; path: string; body: unknown }[] = [];
  const client = new Mindwire({ target: remote("http://bots"), agent: "codex", fetch: async (input, init) => {
    const url = new URL(input); const method = init?.method ?? "GET";
    calls.push({ method, path: url.pathname, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (url.pathname === "/bots" && method === "GET") return Response.json([bot]);
    if (url.pathname === "/bots/bot" && method === "GET") return Response.json(bot);
    if (url.pathname.endsWith("/chats")) return Response.json(method === "GET" ? [{ id: "chat", botId: bot.id }] : { chatId: "chat", snapshot });
    return Response.json({ bot, snapshot });
  } });
  expect(await client.bots.list()).toEqual([bot]);
  expect((await client.bots.ensure("agent", "project")).snapshot.bots).toEqual([bot]);
  expect((await client.withAgent("claude-code").bots.get(bot.id)).memory).toBe("Short answers");
  await client.bots.create({ agentId: "agent", projectId: "project", name: "Writer", purpose: bot.purpose, instructions: bot.instructions });
  await client.bots.update(bot.id, { expectedRevision: bot.revision, icon: "mint-pebble", instructions: "Write concise prose" });
  expect((await client.bots.createChat(bot.id, { chatId: "chat", title: "Article" })).chatId).toBe("chat");
  expect((await client.bots.chats(bot.id))[0]?.botId).toBe(bot.id);
  expect(calls.find(call => call.method === "PATCH")?.body).toEqual({ expectedRevision: 2, icon: "mint-pebble", instructions: "Write concise prose" });
  expect(calls.map(call => `${call.method} ${call.path}`)).toEqual([
    "GET /bots", "POST /bots/ensure", "GET /bots/bot", "POST /bots", "PATCH /bots/bot", "POST /bots/bot/chats", "GET /bots/bot/chats",
  ]);
});

test("a stale bot edit reaches the caller without being silently retried", async () => {
  let writes = 0;
  const client = new Mindwire({ target: remote("http://bots"), fetch: async () => {
    writes++; return Response.json({ error: "record changed on another client" }, { status: 409 });
  } });
  await expect(client.bots.update("bot", { expectedRevision: 1, memory: "New preference" })).rejects.toMatchObject({ status: 409 });
  expect(writes).toBe(1);
});
