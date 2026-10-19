"use client";

import { useEffect } from "react";
import { useSidebar } from "fumadocs-ui/components/sidebar/base";

/** Keep the mobile drawer's keyboard interaction within its visible navigation. */
export default function DocsSidebarKeyboard() {
  const { open, setOpen, mode } = useSidebar();
  useEffect(() => {
    if (!open || mode !== "drawer") return;
    const drawer = document.getElementById("nd-sidebar-mobile");
    if (!drawer) return;
    const trigger = document.querySelector<HTMLButtonElement>('#nd-subnav [aria-controls="nd-sidebar-mobile"]');
    const focusable = () => [...drawer.querySelectorAll<HTMLElement>('a[href], button:not([disabled]), [tabindex="0"]')].filter(element => element.getClientRects().length && getComputedStyle(element).visibility !== "hidden" && !element.closest('[inert], [hidden]'));
    // Presence reveals the drawer after its parent commits.
    const frame = requestAnimationFrame(() => focusable()[0]?.focus());
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setOpen(false);
        trigger?.focus();
      } else if (event.key === "Tab") {
        const items = focusable();
        const first = items[0], last = items.at(-1);
        if (event.shiftKey && (document.activeElement === first || !drawer.contains(document.activeElement))) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && (document.activeElement === last || !drawer.contains(document.activeElement))) { event.preventDefault(); first?.focus(); }
      }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      cancelAnimationFrame(frame);
      document.removeEventListener("keydown", onKey);
      if (drawer.contains(document.activeElement)) trigger?.focus();
    };
  }, [open, mode, setOpen]);
  return null;
}
