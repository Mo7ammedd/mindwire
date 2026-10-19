import Link from "next/link";
import { ArrowUpRight } from "lucide-react";
import BotAvatar from "./BotAvatar";
import base from "./landing.module.css";
import styles from "./product.module.css";

export default function FinalInvite() {
  return <section className={styles.finalInvite} aria-labelledby="invite-title">
    <div className={styles.inviteBots} aria-hidden="true"><BotAvatar character="sprout" size={62} /><BotAvatar size={87} /><BotAvatar character="robot" size={66} /></div>
    <h2 id="invite-title">What’s on your mind?</h2>
    <p>There’s a bot for that. And you get to make it yours.</p>
    <Link href="/download" className={base.primaryButton}>Meet your Mindwire <ArrowUpRight size={18} /></Link>
    <span>Your agents. Your accounts. Your little team.</span>
  </section>;
}
