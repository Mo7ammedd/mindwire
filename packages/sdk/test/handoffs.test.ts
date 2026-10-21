import { expect, test } from "bun:test";
import { Mindwire } from "../src/client.js";
import { remote } from "../src/target/index.js";

test("handoffs preserve retry IDs, select the saved target, and return a run handle", async () => {
  const calls: { url: URL; body: unknown }[] = [];
  const client = new Mindwire({ agent: "claude-code", target: remote("https://workspace.test"), fetch: async (url, init) => {
    calls.push({ url: new URL(String(url)), body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (init?.method === "GET") return Response.json({ source: { chatId: "source/chat", agentId: "claude-profile", title: "Implement" }, context: "Keep the API", truncated: false, historySource: "native", digest: "a".repeat(64), capsule: { version: 1, source: { agentType: "claude-code", chatId: "source/chat", revision: "native-revision", history: "native" }, summary: { text: "Keep the API" }, losses: [{ code: "tool_output_omitted", count: 1 }] } });
    return Response.json({ chatId: "review", run: { id: "run", chatId: "review", agent: "codex", status: "running", createdAt: "now" }, snapshot: { chats: [] } });
  } });
  const preview = await client.previewHandoff("source/chat");
  const request = { newChatId: "review", requestId: "stable-receipt", targetAgentId: "codex-profile", task: "Review the changes", context: preview.context, previewDigest: preview.digest };
  const result = await client.handoff("source/chat", request);
  await client.handoff("source/chat", request);
  expect(preview.capsule.summary?.text).toBe("Keep the API");
  expect(preview.capsule.losses?.[0]?.code).toBe("tool_output_omitted");
  expect(result.run.id).toBe("run");
  expect(result.run.agent).toBe("codex");
  expect(result.run.chatId).toBe("review");
  expect(calls.map(x => x.url.pathname)).toEqual(Array(3).fill("/chats/source%2Fchat/handoff"));
  expect(calls.every(x => !x.url.searchParams.has("agent"))).toBe(true);
  expect(calls[1]!.body).toEqual(request);
  expect(calls[2]!.body).toEqual(request);
});
