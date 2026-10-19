"use client";

import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

export default function SiteContent({ children }: { children: ReactNode }) {
  // Fumadocs supplies its own main landmark; public pages use the site landmark.
  const pathname = usePathname();
  const Tag = pathname === "/docs" || pathname?.startsWith("/docs/") ? "div" : "main";
  return <Tag id="main-content" tabIndex={-1} className="relative">{children}</Tag>;
}
