"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowUpRight, Menu, X } from "lucide-react";
import OblienLogo from "../OblienLogo";
import ThemeToggle from "../ThemeToggle";
import { consoleUrl } from "@/lib/console-url";
import styles from "./landing.module.css";

const links = [{ href: "/#modes", label: "Product" }, { href: "/use-cases", label: "Use cases" }, { href: "/developers", label: "Developers" }, { href: "/pricing", label: "Pricing" }, { href: "/sdk", label: "SDK" }, { href: "/download", label: "Download" }, { href: "/docs", label: "Docs" }];

export default function LandingNav() {
  const [open, setOpen] = useState(false);
  const [docked, setDocked] = useState(false);
  const pathname = usePathname()?.replace(/\/$/, "") || "/";
  const isCurrent = (href: string) => pathname === href || (href === "/use-cases" && pathname.startsWith("/use-cases/"));
  const button = useRef<HTMLButtonElement>(null);
  const root = useRef<HTMLElement>(null);

  useEffect(() => {
    let frame = 0;
    const update = () => {
      frame = 0;
      setDocked(window.scrollY > Math.max(180, window.innerHeight * .25));
    };
    const schedule = () => { if (!frame) frame = requestAnimationFrame(update); };
    schedule();
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
    };
  }, [pathname]);

  useEffect(() => {
    if (!open) return;
    const dismiss = (event: KeyboardEvent) => {
      if (event.key === "Escape") { setOpen(false); button.current?.focus(); }
    };
    const outside = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("keydown", dismiss);
    document.addEventListener("pointerdown", outside);
    return () => { document.removeEventListener("keydown", dismiss); document.removeEventListener("pointerdown", outside); };
  }, [open]);

  return (
    <div className={styles.navSlot}>
      <header className={styles.nav} ref={root} data-docked={docked}>
        <div className={styles.navBlur} aria-hidden="true">
          <div /><div /><div /><div /><div /><div />
        </div>
        <div className={styles.navInner}>
          <Link href="/" className={styles.wordmark} aria-label="Mindwire home" onClick={() => setOpen(false)}><OblienLogo size={30} />Mindwire</Link>
          <nav aria-label="Main navigation" className={styles.desktopLinks}>{links.map(link => <Link key={link.href} href={link.href} aria-current={isCurrent(link.href) ? "page" : undefined}>{link.label}</Link>)}</nav>
          <div className={styles.navActions}>
            <ThemeToggle />
            <a className={styles.accountLink} href={consoleUrl}>Your account <ArrowUpRight size={16} /></a>
            <button ref={button} className={styles.menuToggle} type="button" aria-label={open ? "Close navigation" : "Open navigation"} aria-controls="landing-mobile-menu" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? <X size={22} /> : <Menu size={22} />}</button>
          </div>
        </div>
        <nav id="landing-mobile-menu" aria-label="Mobile navigation" className={styles.mobileLinks} hidden={!open}>
          {links.map(link => <Link key={link.href} href={link.href} aria-current={isCurrent(link.href) ? "page" : undefined} onClick={() => setOpen(false)}>{link.label}<ArrowUpRight size={16} /></Link>)}
          <a href={consoleUrl}>Your account <ArrowUpRight size={16} /></a>
          <Link href="/get-started" onClick={() => setOpen(false)}>Get started <ArrowUpRight size={16} /></Link>
        </nav>
      </header>
    </div>
  );
}
