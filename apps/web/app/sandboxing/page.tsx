import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight, Files, KeyRound, Network, Terminal } from "lucide-react";
import SandboxPreview from "@/components/landing/SandboxPreview";
import base from "@/components/landing/landing.module.css";
import styles from "@/components/landing/resource-pages.module.css";

export const metadata: Metadata = {
  title: "Workspace isolation — Mindwire",
  description: "Your own computer, a Docker workspace, or a Cloud Computer. Choose where your agents work and what they can access.",
};

export default function Sandboxing() {
  return <div className={base.landing}>
    <section className={styles.hero}>
      <p className={styles.kicker}>A place for the work</p>
      <h1>Big ideas.<br /><span>Their own little world.</span></h1>
      <p>Give your agents the files, tools, and space they need. Work on your own computer, separate a project in Docker, or make a home for it in the cloud.</p>
      <div className={styles.actions}><Link href="/docs/guides/quickstart" className={base.primaryButton}>Set up a workspace<ArrowRight size={17} /></Link><Link href="/pricing" className={base.secondaryButton}>Explore Cloud Computers</Link></div>
    </section>
    <SandboxPreview />
    <section className={styles.capabilities}>
      <div><p className={styles.kicker}>You choose the boundaries</p><h2>Room to get things done.<br /><span>With a little structure.</span></h2><p>A workspace keeps the environment around your work together. Choose access that fits the task, and use a separate workspace when a project needs its own space.</p><Link href="/docs" className={styles.textLink}>Explore the documentation<ArrowRight size={16} /></Link></div>
      <div className={styles.features}>
        {[
          { icon: Files, title: "Files that stay with the work", description: "Keep a project directory and its tools across conversations. Pick up the next task in the same environment." },
          { icon: Terminal, title: "A real place to run things", description: "Agents can use a terminal, read and edit files, and work with the tools available on their computer." },
          { icon: KeyRound, title: "An intentional boundary", description: "Direct host access uses your machine. Docker separates a workspace. A Cloud Computer runs on a separate machine." },
          { icon: Network, title: "Connect the way you work", description: "Use the local app, connect to your infrastructure over SSH, or choose a managed Cloud Computer." },
        ].map(({icon: Icon,title,description}) => <article key={title}><span><Icon size={21} /></span><div><h3>{title}</h3><p>{description}</p></div></article>)}
      </div>
    </section>
    <section className={styles.closing}><p className={styles.kicker}>Your next project has a home</p><h2>Your computer. Or a little more room.</h2><p>Start with the machine you have. Add a Cloud Computer whenever your work needs one.</p><div className={styles.actions}><Link href="/download" className={base.primaryButton}>Get Mindwire<ArrowRight size={17} /></Link><Link href="/pricing" className={base.secondaryButton}>See the plans</Link></div></section>
  </div>;
}
