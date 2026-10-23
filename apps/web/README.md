# @mindwire/web

Mindwire’s mobile product site and developer documentation. Built with Next.js App
Router, React, Tailwind CSS, and Fumadocs. The Node deployment uses Next’s
`standalone` output.

## Develop and build

Run `bun install` at the repository root, then from this directory:

```sh
bun run dev          # Fumadocs + Next development server
bun run check        # TypeScript
bun run build        # Generate reference docs, then production build
bun run serve        # Run the production site on port 4327
```

The web build generates REST, TypeScript, Go, and agent-catalog reference pages.
Build the TypeScript SDK first when starting from a clean checkout:

```sh
bun --filter=mindwire run build
bun --filter=@mindwire/web run build
```

The Docker build does both. It needs a running Node server; `out/` static exports
are not used.

## Product pages

- `/`: personal-bot hero, interactive everyday creations, General / Developer mode explorer, computer/phone
  continuity, SDK showcase, questions and a download invitation.
- `/get-started/`: app, computer/server/cloud and agent setup.
- `/pricing/`: free own-computer runtime and monthly Mindwire Cloud Computer plans.
- `/download/`: Mac and iOS app availability, CLI installation and release links.
- `/developers/`: Developer mode, an interactive project workspace, Git, terminals,
  agent choice, and working across computers and phones.
- `/use-cases/`: 24 use cases across everyday life, work, learning, creating and building,
  with category filters, search and an interactive personal secretary example.
- `/use-cases/[slug]/`: shareable recipes with copyable starter prompts, useful context,
  suggested outcomes and follow-ups. `lib/use-cases.ts` supplies these pages and the sitemap.
- `/sdk/`: SDK integration page with agent/language selectors and copyable examples.
- `/docs/`: developer documentation and generated references.

Shared product URLs live in `lib/product.ts`. Product pages share the components
and scoped styles in `components/landing/`. The changelog and sandboxing content
retain `components/marketing/`; the docs theme stays in `app/globals.css`.

The homepage uses Gellix, soft rounded surfaces, and the native app's peach, blue,
and mint bot palette. `BotAvatar` adapts the native bean, robot, and sprout vectors.
`LandingNav` and `LandingFooter` are shared by marketing routes without changing the documentation shell.
The previews use fictional example content and local interactions only: changing
bots, inspecting their memory and instructions, checking tasks, comparing ideas,
switching bookshelves, trying everyday tools, and exploring General / Developer views. They never contact
an agent or touch an account. Mode switching preserves the example app's state.
The personal secretary example shares one component between the homepage and the
use-case directory. Check a priority, open the meeting brief, or switch with arrow keys.
Use-case prompts start from information the user supplies and tools they connect;
they do not imply built-in email or calendar integrations.

Check the hero at 1512 × 850 and 1280 × 720, and the complete page at narrow tablet
and phone sizes in both themes. Tab sets support arrow keys, Home, and End; the
mobile menu supports Escape and outside-click dismissal. Previews follow document
scrolling, with no nested scroll areas or automatic tab rotation. Short transitions
respect reduced-motion preferences.

The social preview is the checked-in `app/opengraph-image.png`. To change its
artwork, edit `scripts/gen-social-image.tsx` and run `bun run gen:social`. It is
served as a static image and needs no image-generation service at runtime.

### Native app download links

Set `NEXT_PUBLIC_IOS_APP_URL` to the public HTTPS App Store or TestFlight URL before
building. Mac downloads default to the signed universal installer at
`https://github.com/oblien/mindwire/releases/latest/download/Mindwire.dmg`.
Set `NEXT_PUBLIC_MAC_APP_URL` to override it with another HTTPS installer or Mac
App Store URL. The iOS download shows a coming-soon state until its URL is configured.
The native Mac installer and the CLI runtime are separate downloads.

Docker Compose passes both variables as web build arguments. With a direct Docker
build, pass `--build-arg NEXT_PUBLIC_IOS_APP_URL=...` and
`--build-arg NEXT_PUBLIC_MAC_APP_URL=...`. Rebuild the web image after
changing it. `NEXT_PUBLIC_CONSOLE_URL` configures the separate web Console link.

### Cloud Computer pricing

`lib/computer-pricing.ts` reads `/api/cloud/catalog` from the configured Console
origin on the server, with a five-second timeout and 60-second revalidation. The
same catalog powers checkout and the native app. No account token is used.

If the public endpoint is missing, unavailable or malformed, the page imports the
published retail catalog directly from `apps/console/shared/cloud.ts`. It displays
those plans with an availability notice and links to Console, without claiming
that checkout is open. Prices and resource quantities are never duplicated in
marketing components. Live catalog values take precedence when available.

The Node process needs outbound HTTPS and write access to its `.next` cache and
prerendered routes for revalidation. The web Docker image gives its unprivileged
`node` user ownership of those files.

## Documentation

Author `.mdx` files in `content/docs/` with `title` and `description` frontmatter.
Add the page to its directory’s `meta.json` to place it in the navigation. Generated
reference pages and `.source/` are build outputs; edit their source generators.

Fumadocs serves the search, raw markdown, and `llms.txt` routes. A page such as
`/docs/guides/project-sync/` also has a markdown view at
`/docs/guides/project-sync.md`.

### Shared visual theme

The public pages, Fumadocs, and signed-in Console use
[`packages/theme/tokens.css`](../../packages/theme/tokens.css). Adjust shared
colors and radii there. Landing CSS modules own marketing layouts; the docs
layout imports `app/docs-theme.css` for navigation, prose, code, and search
surfaces. Keep Fumadocs' native keyboard navigation and persisted API language
selection when changing its presentation.

Verify public pages, guide and API docs, search, and 404 pages in both themes at
desktop and phone widths. Workspace options on `/sandboxing/` are a local preview;
they never create a computer or change an account.
