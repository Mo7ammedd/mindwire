import type { Metadata } from "next";
import Link from "next/link";
import { ArrowDown, ArrowUpRight } from "lucide-react";
import AgentLogo from "@/components/marketing/AgentLogo";
import HeroWorkspace from "@/components/landing/HeroWorkspace";
import ModeExplorer from "@/components/landing/ModeExplorer";
import PersonalSection from "@/components/landing/PersonalSection";
import BotAvatar from "@/components/landing/BotAvatar";
import ContinuitySection from "@/components/landing/ContinuitySection";
import SDKSection from "@/components/landing/SDKSection";
import Questions from "@/components/landing/Questions";
import FinalInvite from "@/components/landing/FinalInvite";
import styles from "@/components/landing/landing.module.css";
import product from "@/components/landing/product.module.css";

export const metadata: Metadata = {
  title: "Mindwire — Powerful agents. Personal by design.",
  description:
    "Turn Codex, Claude Code and OpenCode into your own personal bots. Bring your AI accounts, give each bot a purpose, and work your way in General or Developer mode.",
};

export default function Home() {
  return (
    <div className={styles.landing}>
      <section className={styles.hero} aria-labelledby="hero-title">
        <div className={styles.heroCopy}>
          <div className={`${styles.heroCompanion} ${styles.companionLeft}`} aria-hidden="true">
            <svg className={styles.companionTrail} viewBox="0 0 180 210" fill="none"><path d="M20 14c100-10 136 22 107 60S18 92 39 142s70 33 109 50" /><circle cx="20" cy="14" r="3" /><circle cx="148" cy="192" r="3" /></svg>
            <BotAvatar size={92} />
            <span>A little less on your mind.</span>
          </div>
          <div className={`${styles.heroCompanion} ${styles.companionRight}`} aria-hidden="true">
            <BotAvatar character="robot" size={94} />
            <BotAvatar character="sprout" size={57} />
            <span>A little more possible.</span>
            <svg className={styles.companionTrail} viewBox="0 0 180 210" fill="none"><path d="M20 14c90 0 127 25 127 78s-87 27-87 73 58 19 93 30" /><circle cx="20" cy="14" r="3" /><circle cx="153" cy="195" r="3" /></svg>
          </div>
          <h1 id="hero-title">Powerful agents.<br /><span>Personal by design.</span></h1>
          <p>Make a little team for your big ideas. Personal bots that know your work,
            use your computer, and turn “what if” into done.</p>
          <div className={styles.heroActions}>
            <Link href="/get-started" className={styles.primaryButton}>Make it yours <ArrowUpRight size={19} /></Link>
            <Link href="#modes" className={styles.secondaryButton}>Find your mode <ArrowDown size={17} /></Link>
          </div>
          <div className={styles.agentLine}>
            <span>The agents you love. The accounts you already have.</span>
            <div>
              <Link href="/docs/reference/agents/codex"><AgentLogo agent="codex" size={19} />Codex</Link>
              <Link href="/docs/reference/agents/claude"><AgentLogo agent="claude" size={21} />Claude Code</Link>
              <Link href="/docs/reference/agents/opencode"><AgentLogo agent="opencode" size={18} />OpenCode</Link>
            </div>
          </div>
        </div>
        <HeroWorkspace />
        <div className={styles.heroCaption}>
          <span>One for your ideas. One for your projects. All yours.</span>
          <span>Interactive examples · No account needed</span>
        </div>
      </section>
      <PersonalSection />
      <ModeExplorer />
      <ContinuitySection />
      <SDKSection />
      <section className={`${product.section} ${product.faqSection}`} aria-labelledby="home-questions">
        <div className={product.sectionCopy}><span className={product.eyebrow}>A few good questions</span><h2 id="home-questions">Before you<br /><em>say hello.</em></h2><p>Getting a little team of your own should feel simple.</p><Link href="/get-started" className={product.textLink}>Walk me through it <ArrowUpRight size={17} /></Link></div>
        <Questions items={[
          { question: "Is this another AI subscription?", answer: <>Mindwire connects to supported agent accounts you already have. Your agent provider’s subscription or API usage stays separate. Use your own computer with no Mindwire runtime fee, or choose an optional <Link href="/pricing">monthly Cloud Computer</Link>.</> },
          { question: "What makes a bot mine?", answer: "Give it a name, a purpose and instructions. Add memory, reference material and reusable skills so it can work with your context. Your saved bots stay with your workspace." },
          { question: "Do I need to know how to code?", answer: "No. General mode focuses on conversations, files and the things your bots make for you. Developer mode brings projects, code changes, Git and terminals forward. Switch modes without starting over." },
          { question: "Where does the work actually happen?", answer: "On the computer you connect: your own machine, a server or a Mindwire Cloud Computer. Your agent uses that computer’s files and tools. Local computers need to stay awake and online during work." },
          { question: "Can I use Mindwire inside my own app?", answer: <>Yes. <Link href="/sdk">Mindwire SDK</Link> gives your product the same runtime: start tasks, stream progress and results, handle supported approvals and keep conversations going across agents.</> },
        ]} />
      </section>
      <FinalInvite />
    </div>
  );
}
