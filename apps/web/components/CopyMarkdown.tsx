"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Check, ChevronDown, Copy, ExternalLink, FileText, LoaderCircle } from "lucide-react";
import styles from "./doc-actions.module.css";

const SITE = "https://mindwire.sh";

export default function CopyMarkdown({ markdownUrl }: { markdownUrl: string }) {
  const [status, setStatus] = useState<"idle" | "copying" | "copied" | "error">("idle");
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const menuId = useId();

  useEffect(() => () => clearTimeout(timerRef.current), []);
  useEffect(() => {
    if (!open) return;
    menuRef.current?.querySelector("a")?.focus();
    const onDown = (event: PointerEvent) => {
      if (!wrapRef.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { setOpen(false); triggerRef.current?.focus(); }
    };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("pointerdown", onDown); document.removeEventListener("keydown", onKey); };
  }, [open]);

  async function copy() {
    clearTimeout(timerRef.current);
    setStatus("copying");
    try {
      const response = await fetch(markdownUrl, { signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw new Error("Document unavailable");
      await navigator.clipboard.writeText(await response.text());
      setStatus("copied");
      timerRef.current = setTimeout(() => setStatus("idle"), 2500);
    } catch { setStatus("error"); }
  }

  const prompt = `Read ${SITE}${markdownUrl} so I can ask you questions about it.`;
  const menu = [
    { label: "View as Markdown", href: markdownUrl, external: false, Icon: FileText },
    { label: "Open in ChatGPT", href: `https://chatgpt.com/?hints=search&q=${encodeURIComponent(prompt)}`, external: true, Icon: ExternalLink },
    { label: "Open in Claude", href: `https://claude.ai/new?q=${encodeURIComponent(prompt)}`, external: true, Icon: ExternalLink },
  ];

  return <div ref={wrapRef} className={`not-prose ${styles.actions}`} onBlur={event => {
    if (open && event.relatedTarget && !event.currentTarget.contains(event.relatedTarget as Node)) setOpen(false);
  }}>
    <div className={styles.buttons}>
      <button type="button" onClick={copy} disabled={status === "copying"}>
        {status === "copied" ? <Check size={15} aria-hidden /> : status === "copying" ? <LoaderCircle size={15} className={styles.spinner} aria-hidden /> : <Copy size={15} aria-hidden />}
        {status === "copied" ? "Copied" : status === "copying" ? "Copying…" : "Copy Markdown"}
      </button>
      <button ref={triggerRef} type="button" aria-label="More document options" aria-expanded={open} aria-controls={open ? menuId : undefined} onClick={() => setOpen(value => !value)}><ChevronDown size={15} aria-hidden /></button>
    </div>
    <span role="status" className={status === "error" ? styles.error : "sr-only"}>{status === "error" ? "Couldn’t copy. Try again or open the Markdown version." : status === "copied" ? "Document copied to clipboard." : ""}</span>
    {open && <div ref={menuRef} id={menuId} className={styles.menu}>{menu.map(item => <a key={item.label} href={item.href} onClick={() => setOpen(false)} {...(item.external ? { target: "_blank", rel: "noopener noreferrer" } : {})}><item.Icon size={15} aria-hidden />{item.label}</a>)}</div>}
  </div>;
}
