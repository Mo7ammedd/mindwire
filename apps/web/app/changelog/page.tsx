import type { Metadata } from "next";
import { ArrowUpRight, Plus } from "lucide-react";
import { githubUrl } from "@/lib/product";
import base from "@/components/landing/landing.module.css";
import styles from "@/components/landing/resource-pages.module.css";

export const metadata: Metadata = {
  title: "Changelog — Mindwire",
  description: "What's new in Mindwire.",
};

const releases = [
  {
    version: "v0.1.0",
    date: "2026",
    tag: "Initial",
    changes: [
      "mindwire — the TypeScript SDK: streaming Run handles (async-iterable events, cancel, wait), step-flow auth, catalog, config, chats, and notifications. Zero runtime deps; ESM + CJS + types.",
      "Go daemon core — a unified event protocol, a per-agent adapter registry, the capabilities matrix (native vs. emulated), dynamic auth/settings, and the HTTP + SSE API.",
      "Claude Code adapter — the first drop-in agent, driven via the CLI.",
      "Provider-agnostic webhook notifications — POST turn events to any URL.",
      "Docs + landing site.",
    ],
  },
];

export default function Changelog() {
  return <div className={base.landing}>
    <header className={styles.hero}><p className={styles.kicker}>The changelog</p><h1>A little better.<br /><span>With every release.</span></h1><p>New tools, thoughtful improvements, and the details behind each Mindwire release.</p><a href={`${githubUrl}/releases`} className={styles.textLink}>Releases on GitHub<ArrowUpRight size={16} /></a></header>
    <section className={styles.journal} aria-label="Release notes">
      {releases.map(release => <article className={styles.release} key={release.version}>
        <div className={styles.releaseMeta}><span>{release.version}</span><time dateTime={release.date}>{release.date}</time></div>
        <div className={styles.releaseBody}><span className={styles.releaseTag}>{release.tag} release</span><h2>The foundations of Mindwire.</h2><ul>{release.changes.map(change => <li key={change}><Plus size={15} /><span>{change}</span></li>)}</ul></div>
      </article>)}
    </section>
  </div>;
}
