# Mindwire web theme

`tokens.css` is the shared foundation for `apps/web` and `apps/console`. Both import
it directly so the public site, documentation and account portal use one palette.
It is bundled at build time and requires no runtime package.

Use warm page backgrounds, opaque surfaces, soft inset areas, and peach, blue and
mint accents. Gellix is the shared typeface. Keep text contrast distinct from
decorative colors. Use the danger palette for destructive operations.

Controls use 12px corners, cards 22px, panels 28px, and compact actions may be
pills. Navigation selections use soft accent fills. Keep illustrations separate
from the small functional icons used in navigation and buttons.

Feature styles own layout and illustrations; the palette belongs here. Website
CSS modules, Fumadocs tokens and console semantic tokens map to these variables.
Preserve user theme preferences and test both themes, narrow screens, and
keyboard focus whenever shared styles change.
