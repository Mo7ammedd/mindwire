import Link from "next/link";
import { ArrowUpRight } from "lucide-react";
import OblienLogo from "../OblienLogo";
import { consoleUrl } from "@/lib/console-url";
import { githubUrl } from "@/lib/product";
import base from "./landing.module.css";
import styles from "./product.module.css";

const columns = [
  { title: "Mindwire", links: [["Two ways to work", "/#modes"], ["Use cases", "/use-cases"], ["Cloud & pricing", "/pricing"], ["Mac & iPhone", "/download"], ["Get started", "/get-started"]] },
  { title: "For builders", links: [["Developer mode", "/developers"], ["Mindwire SDK", "/sdk"], ["Documentation", "/docs"], ["Sandboxing", "/sandboxing"], ["Source code", githubUrl]] },
  { title: "Stay connected", links: [["Your account", consoleUrl], ["Changelog", "/changelog"], ["Get help", githubUrl + "/issues"], ["Oblien", "https://oblien.com"]] },
];

export default function LandingFooter() {
  return <div className={base.landing}><footer className={styles.siteFooter}>
    <div className={styles.footerTop}>
      <div className={styles.footerIdentity}><Link href="/" className={base.wordmark}><OblienLogo size={28} /> Mindwire</Link><p>A little more possible,<br />every day.</p></div>
      {columns.map(column => <nav key={column.title} aria-label={column.title}><h3>{column.title}</h3>{column.links.map(([label, href]) => <Link href={href} key={label}>{label}{href.startsWith("https:") && <ArrowUpRight size={13} />}</Link>)}</nav>)}
    </div>
    <div className={styles.footerBottom}><span>© {new Date().getFullYear()} Oblien LLC</span><span>Built in the open. Made for you.</span><a href={githubUrl + "/blob/main/LICENSE"}>Apache 2.0 <ArrowUpRight size={13} /></a></div>
  </footer></div>;
}
