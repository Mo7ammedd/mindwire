import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import { RootProvider } from "fumadocs-ui/provider/next";
import "./globals.css";
import Nav from "@/components/Nav";
import SiteContent from "@/components/SiteContent";
import LandingFooter from "@/components/landing/LandingFooter";
import HideOnDocs from "@/components/HideOnDocs";

export const metadata: Metadata = {
  title: "Mindwire — Your personal assistant, on your terms",
  description:
    "Your Mindwire agent for everyday work and coding. Bring your supported AI subscriptions, connect your computer, and keep work moving from your phone.",
  metadataBase: new URL("https://mindwire.sh"),
  openGraph: {
    siteName: "Mindwire",
    type: "website",
    locale: "en_US",
  },
  twitter: { card: "summary_large_image" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${GeistSans.variable} ${GeistMono.variable}`} suppressHydrationWarning>
      <body className="font-sans">
        {/* RootProvider owns theme (next-themes, class strategy → the same `.dark` contract every
            marketing page already uses) and the search dialog. It wraps Nav so its ThemeToggle and the
            ⌘K search reach the provider. Default light, opt-in dark — matching the prior behavior. */}
        <RootProvider theme={{ defaultTheme: "light", enableSystem: false }}>
          <a href="#main-content" className="skip-link">Skip to content</a>
          <Nav />
          <SiteContent>{children}</SiteContent>
          {/* The marketing footer is hidden on /docs — the Fumadocs sidebar is a fixed full-height
              column, so a site footer beneath it just adds clutter. */}
          <HideOnDocs>
            <LandingFooter />
          </HideOnDocs>
        </RootProvider>
      </body>
    </html>
  );
}
