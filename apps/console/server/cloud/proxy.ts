import type { Context } from "hono";
import { CloudError } from "./types";

export async function forwardComputer(c: Context, origin: string, path: string, token: string, query: URLSearchParams, body?: string): Promise<Response> {
  const url = new URL(origin + path);
  url.search = query.toString();
  const headers = new Headers({ Authorization: `Bearer ${token}` });
  for (const key of ["Accept", "Content-Type", "Range", "If-None-Match", "If-Modified-Since", "X-Proxy-Port", "X-Proxy-Host", "X-Target-Port", "X-Target-Host", "X-Idempotency-Key", "X-Mindwire-Token", "X-Oblien-Proxy-Target"])
    if (c.req.header(key)) headers.set(key, c.req.header(key)!);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  const abort = () => controller.abort();
  c.req.raw.signal.addEventListener("abort", abort, { once: true });
  let response: Response;
  try {
    response = await fetch(url, { method: c.req.method, headers, redirect: "manual", signal: controller.signal,
      ...(["GET", "HEAD"].includes(c.req.method) ? {} : { body: body ?? c.req.raw.body, duplex: "half" } as RequestInit) });
  } catch { c.req.raw.signal.removeEventListener("abort", abort); throw new CloudError(503, "computer_unreachable", "This computer could not be reached. Check its status and retry."); }
  finally { clearTimeout(timer); }
  // Never follow provider redirects server-side or leak provider cookies
  // and hop-by-hop headers to the account client.
  const output = new Headers({ "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
  for (const key of ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified", "Location", "Content-Disposition"])
    if (response.headers.has(key)) output.set(key, response.headers.get(key)!);
  if (response.headers.has("content-encoding")) output.delete("Content-Length");
  const cleanup = () => c.req.raw.signal.removeEventListener("abort", abort);
  if (!response.body) { cleanup(); return new Response(null, { status: response.status, headers: output }); }
  const reader = response.body.getReader();
  const stream = new ReadableStream<Uint8Array>({
    async pull(destination) {
      try {
        const chunk = await reader.read();
        if (chunk.done) { cleanup(); reader.releaseLock(); destination.close(); }
        else destination.enqueue(chunk.value);
      } catch (error) { cleanup(); destination.error(error); }
    },
    async cancel(reason) { controller.abort(); cleanup(); await reader.cancel(reason); },
  });
  return new Response(stream, { status: response.status, headers: output });
}
