import type { Metadata } from "next";
import Link from "next/link";
import { ArrowUpRight } from "lucide-react";
import BotAvatar from "@/components/landing/BotAvatar";
import InstallBlock from "@/components/landing/InstallBlock";
import { cloudDashboardUrl } from "@/lib/product";
import base from "@/components/landing/landing.module.css";
import styles from "@/components/landing/product.module.css";

export const metadata: Metadata = {
  title: "Get started — Mindwire",
  description: "Give your bots a computer, connect a supported agent account, and make Mindwire yours. Get started on your own hardware or in Mindwire Cloud.",
  alternates: { canonical: "/get-started/" },
};

export default function GetStarted() {
  return <div className={base.landing}>
    <header className={styles.pageHero}><span className={styles.eyebrow}>Let’s meet your little team</span><h1>Start with an idea.<br /><em>We’ll connect the rest.</em></h1><p>A place to work, an agent you like, and a bot that feels like yours.</p></header>
    <div className={styles.pageWrap}>
      <div className={styles.setupLayout}>
        <aside className={styles.setupIntro}><BotAvatar size={82} /><h2>You bring the<br />“what if.”</h2><p>Your bots use a real computer and a supported agent account to turn ideas into work. Start with the computer you already own.</p><Link href="/download" className={base.secondaryButton}>Mac & iOS apps <ArrowUpRight size={16} /></Link></aside>
        <ol className={styles.setupSteps}>
          <li id="computer"><h3>Give your bots a home.</h3><p>On Mac, Windows or Linux, install Node.js 18 or later, then run these commands to connect your computer.</p><InstallBlock /><p>Keep your computer awake, online and Mindwire running while your bots work. Prefer an online home? <Link href="/pricing" className={styles.textLink}>Explore Cloud plans.</Link></p><Link href="/docs/guides/personal-computers" className={styles.textLink}>Computer setup guide <ArrowUpRight size={14} /></Link></li>
          <li id="iphone"><h3>Bring the app along.</h3><p>Already have the iPhone or iPad app? Open <strong>Add computer</strong> and scan the QR code from your terminal. Approve the device on your computer to finish pairing.</p><p>That connection lets the app access files and run commands as your computer account. You can manage your paired devices from the computer.</p><Link href="/download" className={styles.textLink}>Check app availability <ArrowUpRight size={14} /></Link></li>
          <li id="agent"><h3>Connect the agent you like.</h3><p>Choose a supported agent and follow its sign-in flow. Mindwire uses that agent’s account or API key; your provider’s subscription and usage stay separate.</p><Link href="/docs/guides/authentication" className={styles.textLink}>Supported authentication methods <ArrowUpRight size={14} /></Link></li>
          <li><h3>Make a bot feel like you.</h3><p>Choose General or Developer mode. Give your bot a name and purpose, add useful context, then start a conversation. You can switch modes later without starting over.</p><Link href="/#modes" className={styles.textLink}>Find your mode <ArrowUpRight size={14} /></Link></li>
        </ol>
      </div>
      <section className={styles.downloadGuide} id="server" aria-labelledby="other-homes"><h2 id="other-homes">Already have somewhere to work?</h2><div className={styles.includedGrid}>
        <div><h3>Your server</h3><p>Add an SSH connection in the app and choose a project. Use the server directly or a supported Docker workspace.</p><Link href="/docs/guides/destinations" className={styles.textLink}>Workspace destinations <ArrowUpRight size={14} /></Link></div>
        <div><h3>Mindwire Cloud</h3><p>Sign in to your Mindwire account, choose a monthly computer, then connect your agent and start a project.</p><a href={cloudDashboardUrl} className={styles.textLink}>Open your account <ArrowUpRight size={14} /></a></div>
        <div><h3>Your own product</h3><p>Use the SDK to start agent tasks and stream progress inside an experience you build.</p><Link href="/sdk" className={styles.textLink}>Explore the SDK <ArrowUpRight size={14} /></Link></div>
      </div></section>
    </div>
  </div>;
}
