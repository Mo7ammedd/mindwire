# Harness artwork

These SVGs are unmodified copies from the Mindwire daemon repository's
`apps/web/public/logos/`. Claude and Codex use the colored marks used by its
console; Grok and OpenCode use their monochrome marks.

The app and notification extension share the generated PDFs in
`Mindwire/Resources/Assets.xcassets`. Xcode's SVG renderer distorts the compact
arc commands in the original Codex file. Exporting through librsvg preserves
the original shapes, gradients, and transparent backgrounds in a vector format
that iOS renders correctly. Do not redraw the marks or edit their SVG paths.

To refresh from the daemon checkout:

```sh
brew install librsvg
python3 scripts/sync-agent-logos.py --daemon-repo /path/to/mindwire
```

To re-export the bundled originals, omit `--daemon-repo`. The generated PDFs
are checked in, so building the app does not require librsvg or a daemon checkout.
