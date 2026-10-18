import WebSocket, { WebSocketServer, type RawData } from "ws";
import type { Hono } from "hono";
import { upgradeWebSocket } from "@hono/node-server";
import type { WSContext } from "hono/ws";
import { env } from "../env";
import { CloudError } from "./types";
import { RUNTIME, runtimeCredential, runtimeOrigin } from "./gateway";

export const cloudWebSockets = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024, perMessageDeflate: false });

/** Native terminals and desktop streams stay on the Mindwire origin too. */
export function registerRuntimeWebSockets(app: Hono) {
  app.use(`${RUNTIME}/*`, async (c, next) => {
    if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") return next();
    const origin = c.req.header("Origin");
    if (origin && !env.trustedOrigins.includes(origin) && origin !== `https://${new URL(c.req.url).hostname}`) throw new CloudError(403, "untrusted_origin", "Connect from Mindwire.");
    const token = await runtimeCredential(c.req.raw.headers, new URL(c.req.url).hostname);
    const request = new URL(c.req.url), upstreamURL = new URL(runtimeOrigin() + request.pathname.slice(RUNTIME.length) + request.search);
    upstreamURL.protocol = upstreamURL.protocol === "https:" ? "wss:" : "ws:";
    const protocols = (c.req.header("Sec-WebSocket-Protocol") ?? "").split(",").map(s => s.trim()).filter(Boolean);
    if (protocols.some(p => !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(p)) || new Set(protocols).size !== protocols.length)
      throw new CloudError(400, "invalid_protocol", "Invalid WebSocket protocol.");
    const upstream = new WebSocket(upstreamURL, protocols, { headers: { Authorization: `Bearer ${token}`, ...(c.req.header("X-Oblien-Proxy-Target") ? { "X-Oblien-Proxy-Target": c.req.header("X-Oblien-Proxy-Target")! } : {}), ...(c.req.header("X-Mindwire-Token") ? { "X-Mindwire-Token": c.req.header("X-Mindwire-Token")! } : {}) }, handshakeTimeout: 15000, maxPayload: 16 * 1024 * 1024, perMessageDeflate: false, followRedirects: false });
    let downstream: WSContext | undefined;
    const pending: Array<{ data: RawData; binary: boolean }> = [];
    let queuedBytes = 0;
    upstream.on("message", (data, binary) => {
      if (downstream?.readyState === WebSocket.OPEN) {
        const socket = downstream.raw as WebSocket;
        if (socket.bufferedAmount > 16 * 1024 * 1024) { socket.close(1013, "Reconnect to continue"); upstream.terminate(); return; }
        downstream.send(binary ? new Uint8Array(Buffer.concat(Array.isArray(data) ? data : [Buffer.from(data as Buffer)])) : data.toString());
      } else {
        queuedBytes += Array.isArray(data) ? data.reduce((n, b) => n + b.length, 0) : data instanceof ArrayBuffer ? data.byteLength : data.length;
        if (queuedBytes > 1024 * 1024) upstream.terminate(); else pending.push({ data, binary });
      }
    });
    upstream.on("close", () => downstream?.close(1001, "Computer connection closed"));
    upstream.on("error", () => downstream?.close(1011, "Computer connection interrupted"));
    try {
      await new Promise<void>((resolve, reject) => { upstream.once("open", resolve); upstream.once("error", reject); upstream.once("close", () => reject(new Error("closed"))); });
    } catch { upstream.terminate(); throw new CloudError(503, "computer_unreachable", "The computer connection could not be opened. Retry shortly."); }
    return upgradeWebSocket(() => ({
      onOpen(_event, socket) {
        downstream = socket;
        if (upstream.readyState !== WebSocket.OPEN) { socket.close(1001, "Computer connection closed"); return; }
        for (const { data, binary } of pending) socket.send(binary ? new Uint8Array(Buffer.concat(Array.isArray(data) ? data : [Buffer.from(data as Buffer)])) : data.toString());
        pending.length = 0;
      },
      onMessage(event, socket) {
        if (upstream.readyState !== WebSocket.OPEN || upstream.bufferedAmount > 16 * 1024 * 1024) { socket.close(1013, "Reconnect to continue"); upstream.terminate(); return; }
        upstream.send(event.data as string | ArrayBuffer);
      },
      onClose() { upstream.close(1000); },
      onError() { upstream.terminate(); },
    }), { onError: () => upstream.terminate() })(c, next);
  });
}
