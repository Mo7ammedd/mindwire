import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight, ArrowUpRight, Check, ChevronRight, Cloud, Code2, Cpu, HardDrive, Laptop, MemoryStick, Sparkles } from "lucide-react";
import styles from "@/components/marketing/marketing.module.css";
import Corners from "@/components/Corners";
import { cloudDashboardUrl, downloadUrl } from "@/lib/product";
import { getComputerPricing, usd } from "@/lib/computer-pricing";

export const metadata: Metadata = {
  title: "Cloud Computer pricing — Mindwire",
  description: "Your own computers stay free. Get a Mindwire Cloud Computer with a monthly subscription for CPU, memory and storage, managed from one Mindwire account.",
  alternates: { canonical: "/pricing/" },
};
export const revalidate = 60;

const questions = [
  { question: "What does a monthly subscription cover?", answer: "Each subscription covers one Cloud Computer with the CPU, memory and storage shown. Compute is covered throughout the paid month. Managed transfer and retained storage follow the terms shown at purchase; backups and AI model usage are separate." },
  { question: "Does every computer need a subscription?", answer: "Only Cloud Computers. Connecting your own computer or server uses the open-source Mindwire service for free. Each Cloud Computer has its own subscription, so you can choose a different size for each one." },
  { question: "Is AI usage included?", answer: "No. Sign in to your coding agent with a supported subscription or use your own API key. Your model provider handles those charges separately." },
  { question: "Can I cancel?", answer: "Yes. Stop renewal in Mindwire Console or manage the subscription from Account in the app. Your paid period is preserved. Stopping renewal does not automatically delete your computer or its data; retained storage remains subject to its subscription terms." },
  { question: "What happens to my existing cloud account?", answer: "Connect your previous account in Mindwire to keep its computers, files and existing paid terms. Connecting does not move, delete or replace those computers with a new subscription." },
];

export default async function Pricing() {
  const pricing = await getComputerPricing();
  return <div className={styles.marketing}>
    <section className={`${styles.wrap} ${styles.pageHero}`}>
      <span className={styles.kicker}>Cloud Computers</span>
      <h1 className={styles.pageTitle}>Your computer.<br /><span>Anywhere you are.</span></h1>
      <p>Keep your own machine, or give your projects and agents a computer in the cloud. Manage both with Mindwire.</p>
    </section>
    <section className={styles.wrap} aria-labelledby="own-title"><div className={styles.ownPricing}><Corners /><div>
      <span className={styles.ownPricingLabel}><Laptop size={22} /> Your computer or server</span>
      <h2 id="own-title">$0 <span>Mindwire runtime fee</span></h2>
      <p>Run the open-source service on hardware you already own. You cover your infrastructure and agent usage.</p>
      <Link href="/get-started#computer" className={styles.textButton}>Connect your computer <ArrowRight size={16} /></Link>
    </div><ul><li><Check size={16} /> Your projects and agent accounts</li><li><Check size={16} /> Chats, files, Git and terminal</li><li><Check size={16} /> No subscription required</li></ul></div></section>
    <section className={`${styles.wrap} ${styles.section}`} aria-labelledby="cloud-title">
      <div className={styles.pricingIntro}><div><span className={styles.kicker}><Cloud size={16} /> Mindwire Cloud</span>
        <h2 id="cloud-title" className={styles.sectionTitle}>A computer for your work.<br /><span>Even when your laptop’s closed.</span></h2>
        <p>One account. One monthly subscription per Cloud Computer. Choose the resources you need and keep working from your phone or browser.</p>
      </div></div>
      {pricing ? <><div className={styles.pricingGrid}><Corners />{pricing.plans.map(plan => <article key={plan.id} className={`${styles.planCard} ${plan.id === "pro" ? styles.planFeatured : ""}`}>
        <h3>{plan.name}</h3><div className={styles.planPrice}>{usd(plan.monthlyCents)}<span>/ month</span></div>
        <p className={styles.planCredits}>One Cloud Computer</p><div className={styles.planSpecs}><div><Cpu size={15} />{plan.vcpus} shared vCPU</div><div><MemoryStick size={15} />{plan.memoryMb / 1024} GB memory</div><div><HardDrive size={15} />{plan.diskGb} GB storage</div></div>
        <a href={`${cloudDashboardUrl}?plan=${encodeURIComponent(plan.id)}`} className={styles.secondaryButton}>{pricing.available ? "Get a computer" : "View in Console"}<ArrowUpRight size={14} /></a>
      </article>)}</div><p className={styles.pricingNote}>Prices in USD per computer, billed monthly. Shared CPU, RAM and included storage are covered for the paid month. Transfer, retained storage, backups and model usage follow their separate terms. Existing paid contracts keep their saved terms.</p></> : <div className={styles.pricingUnavailable} role="status"><h3>Cloud Computer prices are temporarily unavailable.</h3><p>Check Mindwire Console for current plans. Your own computers remain free to connect.</p><a href={cloudDashboardUrl} className={styles.secondaryButton}>Open Mindwire Console <ArrowUpRight size={15} /></a></div>}
      <div className={styles.costBreakdown}><h2>Know what you’re paying for.</h2><div className={styles.costGrid}>
        <article><h3><Code2 size={19} /> Mindwire service</h3><p>The open-source runtime has no license fee. Run it on your own hardware or a Cloud Computer.</p></article>
        <article><h3><Cloud size={19} /> Cloud Computer</h3><p>A monthly subscription covers the selected computer’s CPU, memory and included storage.</p></article>
        <article><h3><Sparkles size={19} /> Your coding agent</h3><p>Use a supported agent subscription or your API key. Model usage is billed by that provider.</p></article>
      </div></div>
    </section>
    <section className={`${styles.wrap} ${styles.section} ${styles.faqSection}`} aria-labelledby="pricing-questions"><div><span className={styles.kicker}>Simple choices</span><h2 id="pricing-questions" className={styles.sectionTitle}>A little<br /><span>more detail.</span></h2></div><div className={styles.faqList}>{questions.map(item => <details key={item.question}><summary>{item.question}<ChevronRight size={18} /></summary><p>{item.answer}</p></details>)}</div></section>
    <section className={`${styles.wrap} ${styles.finalCta}`}><div className={styles.ctaPanel}><Corners /><span className={styles.kicker}>Your agents, your way</span><h2>Start with the computer<br />you already have.</h2><div className={styles.actions}><Link href="/get-started" className={styles.primaryButton}>Get connected <ArrowRight size={16} /></Link><Link href={downloadUrl} className={styles.textButton}>Download app <ArrowUpRight size={16} /></Link></div></div></section>
  </div>;
}
