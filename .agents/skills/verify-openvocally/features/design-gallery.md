# Design Gallery

A Debug-only window that shows every design token and DesignSystem component in four columns: light, dark, and both Increase Contrast variants. It is the reference for checking a UI change against the design system.

## Sub-features

- `gallery-tokens` type, spacing, radius, color and surface sections.
- `gallery-overlay` every overlay state.
- `gallery-components` buttons, status, tags, copy button, icon buttons and key caps.
- `gallery-panels` panel layouts.
- `gallery-motion` the named animations with Play buttons.

## How to get to it (user POV)

- Debug builds only. Launch with `-designGallery YES`, or choose **Design Gallery** in the **Window** menu while the main window is open. Release builds don't contain it.

## Driving it with the scripts

Preconditions:

- Screen Recording for the screenshots.

- **All sections.** Run `make gallery-shots`. It prints nine PNG paths.
- **Some sections.** Run `scripts/design/gallery-shots.sh components panels`.
- **Proof.** Open each `.build/design-gallery/<section>.png`. The window title reads `Design Gallery` and each column header names its appearance.

## Gotchas

- Reduce Transparency comes from System Settings, so no column can force it. The header line states the current system settings.
- A new DesignSystem component needs a gallery entry; if it is missing from the shot, the change is incomplete.
