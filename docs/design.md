# Design foundations

One design language for the main window, Settings, onboarding and the overlay. Every token lives in the `DesignSystem` module (`OpenVocallyKit/Sources/DesignSystem`). UI code outside that module uses the tokens and never writes the value. `scripts/check-design-tokens.sh` runs in `make lint` and fails on a literal font, spacing, padding, corner radius, system color, material, Liquid Glass call or animation curve, a switch style or a button style.

Build UI from native controls first, the components in [Components](#components) second and the tokens third. Reach for a raw token only when nothing else fits.

Native first. Use the standard macOS control or layout (`Form`, `List`, `NavigationSplitView`, toolbar, `Menu`, `Toggle`, `Picker`, `Settings`) before any custom component, so focus, VoiceOver, accessibility settings and future system restyles come for free. The components here only pick a native style or compose native views. Build a custom look only where macOS has no equivalent, such as the overlay. This borrows the discipline of a web kit like shadcn (one set of tokens, named variants) without its custom-drawn controls.

The direction is clean and simple, with subtle color. The chrome is monochrome like the black and white app icon, and light and dark are both first-class. The numbered rules below are cited by the tables on this page:

1. Use SF Pro through the system text styles. Ship no custom UI font.
2. Give each screen one large title with an icon or symbol. Keep row text at Body 13 pt with a grey secondary line.
3. Use one strong numeric anchor for a group or stat: a big number with a smaller grey label beside it.
4. Show hierarchy through weight and grey levels, not extra color.
5. Align every label, icon and control in the sidebar and headers on a shared grid, both ways.
6. Use an 8 pt base grid with 4 pt half steps, 20 pt content margins and about 12 pt between cards.
7. Make the content pane quieter than the sidebar: the window background, with no borders around rows.
8. Keep the chrome neutral. Use the accent color for selection and one or two signals only.
9. Use fixed icon colors only where the color carries meaning.
10. Support light and dark with high contrast.
11. Let the system sidebar and toolbar carry Liquid Glass. Keep cards, charts and lists on standard materials.
12. Use floating rounded panels for tools only, not for content.
13. Use motion to keep the user's place: unfold in place, never jump.
14. Keep motion short. Skip it on frequent actions. Let it be interrupted.

## See it

The debug build has a **Design Gallery** window (Window menu). It renders every token in four columns: light, dark, Increase Contrast light and Increase Contrast dark. Motion tokens play below the columns, with a switch that previews their Reduce Motion variant.

```sh
make run                                                   # then Window › Design Gallery
open "<Debug app>" --args -designGallery YES               # opens the gallery at launch
open "<Debug app>" --args -designGallery YES -designGallerySection color   # one section
make onboarding                                            # replays the first-run onboarding (-onboarding YES)
make onboarding STEP=overlay                               # opens it on one step (welcome, permissions, overlay, shortcut, model, tryIt)
make onboarding FRESH=1                                    # with an empty model folder (.build/onboarding-models): the welcome starts the Parakeet v3 download
```

Sections are `type`, `spacing`, `radius`, `color`, `surface`, `options`, `components`, `panels` and `motion`. Each section below matches one gallery section; Icon size renders in the `radius` section. Screenshots are not committed because they go stale. Open the gallery to see the current rendering.

Each column hosts its views with a forced `NSAppearance`, so system colors, materials and glass resolve the way they do in a real window. Reduce Transparency is different. Materials and Liquid Glass read it from the system, and no view can force it. To check the fallback, turn it on in System Settings › Accessibility › Display and reopen the gallery. The gallery prints the current Reduce Transparency, Increase Contrast and Reduce Motion settings at the top.

Screenshots of each section are in [design/](design/).

## Color

The chrome is monochrome, like the app icon: black ink on white in light mode, white ink on black in dark mode. Hue appears only where it carries a signal, and only on small glyphs such as a status icon or the recording dot. Use `.foregroundStyle(.token(.success))` and the other tokens.

| Token | Value | Use it for | Why |
| --- | --- | --- | --- |
| `accent` | label color (black or white) | Selection, the app tint, the one highlight per screen | Keep the chrome neutral and use the accent once (rule 8). |
| `onAccent` | text background color (white or black) | Text and glyphs on an `accent` fill | A mono fill needs inverted ink to stay readable in both modes. |
| `recording` | system red | The recording dot | The one hue a dictation user must read at a glance. |
| `success` | system green | Done, granted, ready | Signal only (rule 9). |
| `attention` | system orange | A missing permission, a recoverable failure | Signal only (rule 9). |
| `destructive` | system red | Delete and other destructive actions | HIG convention. |
| `selection` | quinary label color | Behind the selected sidebar row | A faint wash that keeps the row's text color reads calmer than a filled row. |
| `separator` | separator color | Hairlines and outlines | Adapts to Increase Contrast. |
| `windowBackground` | window background color | Window and pane backgrounds | Things and Bear keep the content pane plain (rule 7). |
| `contentBackground` | control background color | Behind lists and scrolling content | Quiet content layer (rule 7). |

Text never takes a color token. It uses the hierarchical styles `.primary`, `.secondary` and `.tertiary`, which stay vibrant on materials. Hierarchy comes from weight and grey level, not extra color (rule 4).

Every value is a dynamic system color, so each one follows light, dark and Increase Contrast with no code. The app tints its windows with `accent`, so standard controls (prominent buttons, selection) are monochrome too. This overrides the user's system accent color on purpose. AppKit draws sidebar selection and sidebar icons from the app accent and ignores `.tint`, so the app also ships a graphite `AccentColor` asset and sidebar rows are `SidebarRow`s that draw their own `selection` pill, so AppKit's accent selection never shows.

Switches are the exception. A mono switch that is on looks almost the same as one that is off in dark mode, so every switch uses `.switchStyle()`, which tints it the system green. The lint rejects `.toggleStyle(.switch)` outside the module.

## Type

SF Pro through the system text styles. Do not ship a custom UI font (rule 1). macOS has no Dynamic Type, so each style has one size. The system styles carry Apple's tracking and leading for that size. Use `.textStyle(.body)` and change weight with `.fontWeight(_:)`.

| Token | Size (pt) | Use it for |
| --- | --- | --- |
| `largeTitle` | 26 | The one title per screen (rule 2) |
| `title1` | 22 | Rare. A second-level page title |
| `title2` | 17 | Section titles, the app name on small windows |
| `title3` | 15 | Card titles, gallery columns |
| `headline` | 13 bold | Row titles, section labels |
| `body` | 13 | Row text and paragraphs (rule 2) |
| `callout` | 12 | Secondary lines under a row title |
| `subheadline` | 11 | Metadata |
| `footnote` | 10 | Fine print |
| `caption` | 10 | Labels under thumbnails and swatches |
| `numeral` | 28 semibold, monospaced digits | One big number with a grey label, for stats (rule 3, Things "16 Tomorrow") |
| `code` | 10 monospaced | Paths and identifiers the user may copy |
| `overlayLabel` | 12 medium | Status word in the overlay |
| `overlayGlyph` | 11 semibold | SF Symbols in the overlay |

Sizes are the HIG macOS text style table, quoted in section 3 of the research note. Avoid Ultralight, Thin and Light at these sizes.

Long text read in full gets extra line spacing on top of the style's own leading, with `.lineSpacing(LineSpacing.reading.points)`.

| Token | pt | Use it for |
| --- | --- | --- |
| `LineSpacing.reading` | 4 | A transcript or other long text in a detail, with `body` (apple-design, leading) |

## Spacing

An 8 pt grid with 4 pt half steps (rule 6). Use `.padding(.xl)`, `.padding(.horizontal, .m)` or `spacing: Space.s.points`.

| Token | pt | Use it for |
| --- | --- | --- |
| `xxs` | 2 | Title to subtitle in one block. The only off-grid step. |
| `xs` | 4 | Tight groups |
| `s` | 8 | Icon to label, related controls |
| `m` | 12 | Between rows and between cards (rule 6) |
| `l` | 16 | Card padding |
| `xl` | 20 | Window content margins (rule 6) |
| `xxl` | 24 | Between sections |
| `xxxl` | 32 | Between major regions |

Align labels, icons and controls on the same grid in both directions (rule 5, Linear). A test fails if a step leaves the grid.

## Icon size

Use `IconSize.row.points` for the frame of an icon beside a row's text.

| Token | pt | Use it for |
| --- | --- | --- |
| `row` | 20 | An app icon or a symbol in a list row, such as a transcript or a top app |
| `detail` | 32 | The app icon heading a detail, such as the selected transcript's |

## Corner radius

Continuous (squircle) corners. Use `Radius.card.shape`. Capsules use `Capsule()`.

| Token | pt | Use it for |
| --- | --- | --- |
| `small` | 6 | Thumbnails, badges, inline code |
| `card` | 12 | Stat cards, chart panels, grouped lists |
| `panel` | 18 | Floating panels and popovers. The overlay has its own radii (see The overlay). |

Bigger surfaces get bigger radii, so nested shapes stay roughly concentric. Window corners belong to the system.

## Surfaces

Use `.surface(.card, in: Radius.card.shape)` or `.surface(.control, in: Capsule())`.

| Token | Renders as | Use it for | Why |
| --- | --- | --- | --- |
| `control` | Liquid Glass (`.regular`), `.regularMaterial` before macOS 26 | Custom controls | The macOS 26 HIG keeps Liquid Glass in the control and navigation layer (rule 11). Standard controls, the sidebar and the toolbar already get it from the system. |
| `notch` | Always black, white content | The notch overlay | The notch is hardware and always black, so anything that grows out of it is black too, like Apple's Dynamic Island. |
| `card` | Regular material, plus a separator outline under Increase Contrast | Stat cards, chart panels, grouped lists | The HIG asks for standard materials in the content layer (rule 11). Liquid Glass reception is mixed for legibility, so content stays off it (section 3). |

Never put glass on content. The lint rejects `glassEffect` and named materials outside the module, so `.surface` is the only way in.

Floating rounded panels are for tools, not content (rule 12). `control` and `card` fall back to an opaque fill under Reduce Transparency, which the system applies. `notch` is already opaque.

## Window background

The whole window's backdrop, behind the sidebar and the detail pane. The user picks it with the Translucent window switch in Settings › Appearance, shown on macOS 26 and later, stored as `windowBackground` in UserDefaults. Apply it once at the top of a window with `.windowBackground(_:)`.

| Token | Renders as | Why |
| --- | --- | --- |
| `solid` | The standard opaque window background. The default. | Plain content pane (rule 7). |
| `translucent` | `.thinMaterial` as the window's container background, and scrolling lists and forms hide their own backgrounds, so the window reads as one surface. The toolbar keeps its automatic background, so content fades out under the title instead of overlapping it | A see-through window. It is a standard material, not Liquid Glass, so content stays off glass. Reduce Transparency turns it opaque. |

The gallery can't show it, because its columns host views inside one window. Check it in the main window.

## Motion

Use `.motion(.content, value: phase)`. It plays the token's Reduce Motion variant when that setting is on. For an explicit change, use `withAnimation(Motion.windowUnfold.resolved(reduceMotion:))`.

| Token | Animation | Reduce Motion | Use it for |
| --- | --- | --- | --- |
| `grow` | spring, response 0.3, damping 0.9 | 0.2 s crossfade | The dictation notch appears from hidden, whatever the cause, or grows to a bigger footprint for anything but a key press, such as a notice arriving. An entry is instant under Reduce Motion. |
| `shrink` | spring, response 0.25, damping 1.0 | 0.2 s crossfade | The dictation notch shrinks or leaves. No overshoot, so the shape never dips inside the notch. |
| `keyboard` | spring, response 0.15, damping 1.0 | none (instant) | The dictation notch, already on screen, resizes because of a key press. A key's feedback never fades in, so under Reduce Motion it is instant, and the recording mark is on screen in the first frame. |
| `content` | `.smooth(duration: 0.3)` with `.transition(.blurReplace)` | 0.2 s crossfade | Dictation notch content changes within one footprint. The shape does not move. |
| `meter` | linear 0.05 s | none (static) | The dictation notch's live meter bars between 50 ms level ticks. Decoration. |
| `windowReveal` | ease-out curve (0.23, 1, 0.32, 1), 0.2 s | 0.15 s fade | A banner or row appearing in a window |
| `windowUnfold` | spring, response 0.35, damping 1.0 | 0.15 s fade | A row or section opening in place (rule 13, Things) |
| `press` | ease-out curve (0.23, 1, 0.32, 1), 0.12 s, to `Motion.pressScale` (0.97) | 0.1 s dim to `Motion.pressDim` (0.6), no scale | A control answering the pointer going down. Feedback on the press, not the release (apple-design, response). |
| `confirm` | spring, response 0.2, damping 1.0 | 0.15 s crossfade | A control confirming its action, such as Copy morphing into a green checkmark with SF Symbols Magic Replace at `Motion.symbolSpeed` (1.5x), no bounce. It starts on the press, not after the copy, and holds for `Motion.confirmationHold` (1.2 s). |
| `confirmEnd` | ease-out curve (0.23, 1, 0.32, 1), 0.18 s | 0.15 s crossfade | The confirmation going back, faster than it came (emil-design-eng, asymmetric timing). |
| `keyCap` | ease-out curve (0.23, 1, 0.32, 1), 0.15 s | 0.1 s fade, the cap dims instead of shrinking | A key cap fading in while a shortcut is recorded, and a held cap going down to `Motion.pressScale`. The hotkey itself never animates. |
| `onboardingIntro` | spring, response 0.45, damping 0.86, each element `Motion.introStagger` (0.07 s) after the last | 0.2 s crossfade, no scale, offset or blur | The onboarding welcome: icon from 0.9 scale with a 4 pt blur, then title, tagline and button. Rare and first-time, so it may delight. |
| `onboardingStep` | spring, response 0.42, damping 0.9 | 0.2 s crossfade | An onboarding step entering from the trailing side by `Motion.stepTravel` (20 pt) with a blur, through `Motion.stepTransition(_:reduceMotion:)`; going Back mirrors it (`StepDirection.backward`, from the leading side); also step dots and in-step swaps such as "You're all set" (`.blurReplace`). Interruptible (apple-design). |
| `onboardingExit` | ease-out curve (0.23, 1, 0.32, 1), 0.18 s | 0.15 s fade | The onboarding step leaving (to the leading side, or the trailing side going Back), faster than the next one enters (emil-design-eng, asymmetric timing). |

Under Reduce Motion, views that move or resize switch to an opacity transition, and the meter bars freeze. A test fails if a token other than the decoration and `keyboard` has no Reduce Motion variant.

Window motion follows the research rules. Animate only to keep the user's place (rule 13). Keep it short and interruptible, and skip it on frequent actions (rule 14). Nothing animates on a keyboard shortcut except the overlay, which is the shortcut's feedback.

## The overlay

`OverlayMetrics`, in the `Overlay` module, holds the notch geometry. The notch draws on `Surface.notch`, always black.

The dictation notch (`NotchFrameView`), the only overlay, draws one frame from `NotchCore`: a scene and the cue for moving into it. Its animations are scoped by structure, never by `withAnimation` or `withTransaction` (`scripts/check-overlay-motion.sh` rejects both under `Sources/Overlay`). The shape's size comes from the footprint alone (hidden, strip, notice) and animates with `.animation(_:value:)` keyed on the footprint, on the cue's token: `appear` → `grow`, `grow` → `grow`, `shrink` → `shrink`, `keyboard` → `keyboard`, `content` → `content` (`MotionCue+Motion.swift`). Any change from hidden is `appear`, so the entry is visible even on a key press; a key press on a notch already on screen is `keyboard`. Content animates on `content`, keyed on the strip lead: new content swaps in with `.blurReplace`, and a change that keeps the content, such as the bars going from live to sweep, interpolates the tint and crossfades the bars. A change within one footprint never moves the shape. Content that arrives with a key press or on `appear` is inserted without a transition, at full opacity in the first frame. Under Reduce Motion the shape and content crossfade, and a key press and `appear` are instant. On a display without a notch it draws at the simulated notch's size on the top edge, and hidden draws nothing. The Design Gallery's `notch` section renders every scene through `NotchFramePreview`, and `notch-reduce-motion` renders their Reduce Motion variants.

| Value | pt | Meaning |
| --- | --- | --- |
| `notchIdleShrink` | 4 by 2 | The idle shape is this much smaller than the hardware notch, so it never shows an edge. |
| `notchWing` | 64 | Width added on each side of the notch at the compact level |
| `notchWingInset` | 10 | Gap between the camera edge and the content in each wing |
| `notchDropInset` | 12 | Side inset of a notice below the camera |
| `notchSimulated` | 185 by 32 | The notch the Design Gallery draws on a Mac without one; on a display without a camera notch the width, at the menu bar's height |
| `notchHiddenRadii` | 0 top, 12 bottom | Notch at the hidden level, inside the hardware notch |
| `notchCompactRadii` | 6 top, 12 bottom | Notch at the compact level |
| `notchAlertRadii` | 10 top, 20 bottom | Notch at the alert level |
| `glyphSize` | 14 | SF Symbol frame |
| `canvas` | 600 by 180 | The fixed panel the notch animates inside, one per display |
| `barCount`, `barWidth`, `barSpacing` | 16, 2, 2 | The meter bars |
| `barMinHeight`, `barMaxHeight` | 3, 16 | A silent and a full bar |

One shape stays mounted at every level: hidden, it sits inside the hardware notch, so appearing and hiding grow out of and back into the camera housing. Strip content sits beside the camera in two equal wings: a mic or result glyph on the left, the meter or status word on the right. Notices drop below the camera.

The notch size itself comes from `NSScreen` (`safeAreaInsets` and the auxiliary top areas), never from a constant.

## Components

Ready-made views in the `DesignSystem` module, built only from the tokens on this page. Actions are `@ViewBuilder` slots that default to nothing.

| Component | Use it for | Notes |
| --- | --- | --- |
| `.appButton(_ variant:size:)` | Every button | `ButtonVariant`: `primary` (one per view, the mono accent fill), `secondary` (the default), `quiet` (inline, no bezel), `destructive` (red fill) and `card` (a whole card as a button, such as onboarding's notch or island choice: no bezel, shrinks to `Motion.pressScale` on press, dims under Reduce Motion). `ControlScale`: `small`, `regular` and `large`. Each except `card` wraps a system style, so press, focus and glass stay native; `card` is drawn by the module and keeps keyboard focus through the system focus ring of its content. The lint rejects `.buttonStyle(.bordered)` and the other system styles outside the module. |
| `Card { }` | Any grouped content | The native `GroupBox`, with padding `s` inside. |
| `StatTile(value:label:detail:) { accessory }` | One number and its label | A secondary `callout` label, a `numeral` and an optional tertiary `subheadline` detail, on a card. The accessory, such as a change `Tag`, sits at the end of the detail line. Tiles in a row share its height. |
| `TimeChart(_:points:unit:style:noun:detail:emptyText:) { accessory }` | Values per day, week or month | Swift Charts under a `SectionHeader`. `.area` in `accent` ink with a fading fill for words over many periods, and `.bars` with history in faded ink and the current period in full `accent` for a few periods. The average goes in the title's second line, and `.area` also draws it as a dashed line over the data, so no label covers a mark. Hovering names the period's value there instead. With no data, a faded skeleton of bars sits behind `emptyText`. |
| `WeekHeatmap(_:values:noun:emptyText:)` | A value for each hour of the week | Seven day rows, Monday first, of 24 rounded cells drawn in one canvas with one hover handler. Rows grow with the width up to a limit so cells stay near square. Busier hours take more `accent` ink, with a floor so a quiet hour still reads apart from an empty one. The second line names the busiest hour, or the hovered one. |
| `Columns(minWidth:spacing:) { }` | Tiles or cards that sit side by side on a wide window and wrap on a narrow one | A `Layout` of equal columns. It halves the column count until each is at least `minWidth`, and every view in a row takes the row's height. It measures each view once, where `ViewThatFits` measures every candidate, so the page keeps up with a live resize such as the sidebar collapsing. |
| `SectionHeader(title:detail:)` | Headings above rows or cards | `headline`, plus an optional secondary line. |
| `SettingRow(_:subtitle:) { control }` | Every settings row with a subtitle: a switch, a picker or a shortcut button | A `body` title over a secondary `subheadline`, with the control centered against both lines. A native form row lines the control up with the title alone. Hide the control's own label. |
| `StatusRow(title:detail:status:)`, `StatusIcon` | Checklists such as readiness | `Status`: `ok` (green check), `progress` (spinner), `attention` (orange, the user can fix it) and `failed` (red, retry only). `StatusRow.textInset` lines up extra lines with the title. |
| `Banner(tone:title:message:) { actions }` | A message to read before going on | `tone`: `info` or `attention`. Actions are `small` buttons. |
| `ContentUnavailableView` (native) | A list or page with no content yet | SwiftUI's own empty state, not a component of ours. One symbol, one line and one action. |
| `Tag(_:systemImage:tint:)` | Short facts under a row's description, such as a size, a language count or a state | A secondary `subheadline` on a `selection` capsule. `tint` colors only the symbol. A changed symbol or title morphs in place under the caller's animation. A tag that confirms a new state enters with `Motion.confirmEntrance(reduceMotion:)`. |
| `LanguagePicker(languages:chosen:choose:)` | The language a system speech model transcribes, on its own line under the row's tags | A secondary `callout` "Language" label and a small `appButton` showing the chosen language with an up and down chevron, or "Choose…". It opens a 300 by 360 popover: a focused search field that matches names and identifiers ignoring case and accents, then a list with the preferred languages under "Suggested" before the rest by name. The chosen one has a checkmark. A click chooses and closes it, and Return chooses the first match once something is typed. The button is disabled while its model installs. |
| `KeyCap("⌘V", isPressed:)` | Keyboard shortcuts in text, and the live keys while a shortcut is recorded | A key-shaped label. `isPressed` shrinks it under `keyCap` (dims under Reduce Motion); an empty string draws a blank cap for "waiting for a key". |
| `KeyCap("Space", isPressed:, size: .large)` | The shortcut as the hero of a page, such as the empty Home | One key per cap (`HotkeyTrigger.keyCaps`), drawn like a Mac key: a modifier shows its symbol and name, Space is wide, other keys are one glyph. A 4 pt side shows below. `isPressed` sets the top down onto its side with no animation, since it follows a key press (rule 14); disabled, the legends fade to tertiary. |
| `ConfettiBurst(trigger:palette:)` | A rare celebration, such as the first dictation in onboarding | A Canvas burst of 80 rectangles, capsules and circles from the bottom center, with gravity, drag, spin and a fade over 2.2 s each time `trigger` changes. Seeded per burst (`ConfettiField`, tested). Ten vivid system hues by default (`ConfettiBurst.festive`), a one-off celebration exception to the monochrome brand. A caller can pass its own `palette`. The timeline is paused between bursts, ignores hits, is hidden from VoiceOver and draws nothing under Reduce Motion. |
| `NotchFrameView` (via `NotchFramePreview(phases:)`) | The dictation notch, drawn from one `NotchCore` frame | Always black on `Surface.notch` with dark content. A fixed shape per footprint: the strip holds the mic or glyph and bars or one word beside the notch; a notice drops one line, with the ⌘V key cap and a `CountdownBar` for manual paste, below it. Animates only through `.animation(_:value:)` on the cue's token. |
| `CountdownBar(until:total:)` | Time left before something closes, such as the manual paste window | A 2 pt line that shrinks toward its leading edge; takes the offered width; steps once a second under Reduce Motion. |
| `CopyButton(_:showsTitle:copied:copy:)` | Copying text the user asked for, in a row or a detail | Icon-only by default; `showsTitle` adds the title. `copy` is async and returns whether it copied; the doc symbol morphs into a `success` checkmark under `confirm` on the press itself, holds for 1.2 s and goes back under `confirmEnd`; a failed copy takes it back at once. A press during the hold restarts it. The press shrinks it under `press`. Under Reduce Motion the symbols crossfade and the press dims. `copied` lets the caller keep it on screen while it confirms. |
| `IconButton(_:systemImage:action:)` | Quiet icon-only actions beside a `CopyButton`, such as Delete and Close in a detail header | A secondary symbol with the title as its help tag and label; shrinks under `press`, or dims under Reduce Motion, like the copy button. |
| `SidebarRow(_:systemImage:isSelected:action:)`, `SidebarFooter { }`, `SidebarFooter(notice:content:)` | Every sidebar row; rows pinned to the bottom of a sidebar, such as Settings | A secondary icon and a label. Selected, the row sits on a `selection` pill and keeps its text color. The footer adds a hairline above its rows, and puts a notice above the hairline. |
| `SidebarNotice(_:detail:systemImage:action:)` | A calm notice in a `SidebarFooter`'s `notice` slot, above its divider, such as Restart to Update | An `accent` icon, a label and a secondary caption under it, such as "Version 1.4.0", on a `selection` pill. Both lines wrap rather than truncate. Enters with `SidebarNotice.entrance(reduceMotion:)` on `windowReveal`. Never `attention`: it is news, not a problem. |

### Adding a component

1. Add it to `OpenVocallyKit/Sources/DesignSystem`, using only tokens.
2. Render every variant and size in the gallery's `components` or `panels` section, and check all four columns.
3. Add a row to the table above.

## Adding a token

1. Add the case to the enum in `OpenVocallyKit/Sources/DesignSystem`.
2. Add a row here with the reason, citing the research note or the decision it comes from.
3. The gallery picks up new cases on its own. Check it in all four columns.
4. A deliberate one-off literal outside the module ends its line with `// allowed: <reason>`.
