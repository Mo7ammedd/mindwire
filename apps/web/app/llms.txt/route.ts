import { source } from "@/lib/source";

// The llms.txt index: one line per doc page (title, URL, description) so an LLM can discover the whole
// docs tree and fetch /llms-full.txt for the full corpus. Replaces the old build-docs.mjs public/llms.txt.
// Rendered dynamically from the Fumadocs source at request time — no build step, no committed artifact.
export const dynamic = "force-dynamic";

export function GET() {
  const pages = source.getPages();
  const body = [
    "# MindWire",
    "",
    "> Mindwire is your personal agent for everyday work and coding. Bring your supported AI subscriptions, connect your computer, and get things done from your phone or browser. Existing agent harnesses power the tools under the hood. The runtime and SDKs are Apache-2.0; the Apple client is source-available under a separate license that restricts redistribution and derivative app publication.",
    "",
    "## Docs",
    "",
    ...pages
      .sort((a, b) => a.url.localeCompare(b.url))
      .map((p) => {
        const desc = p.data.description ? `: ${p.data.description}` : "";
        return `- [${p.data.title}](https://mindwire.sh${p.url})${desc}`;
      }),
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
