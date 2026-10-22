# Menu panel design — 0.4.1

## Intent and scope

Answer three questions at a glance: is EQ working, where is sound going, and which preset is selected? The menu is a control surface; the editor owns curves, band parameters, preamp, sample rate and meters. This redesign changes the menu panel, not the full editor's appearance or audio pipeline.

The standard panel measures **344 × 282 pt** with the default macOS font metrics. It follows system light/dark appearance. The representative paused state is 342 pt tall; a two-line error with recovery actions is 372 pt. Longer diagnostic messages expand vertically rather than hiding instructions.

## Layout specification

```text
                 344 pt — native MenuBarExtra window
┌──────────────────────────────────────────────────┐
│  16 pt inset                                     │
│  [sliders]  myEq                         [switch] │ 38 pt content
│             ✓ Equalizing                         │
│  16 pt                                           │
│ ┌──────────────────────────────────────────────┐ │ 12 pt side insets
│ │  speaker   Output                         ⌃  │ │
│ │            ADAM Audio D3V                  ⌄  │ │ ≥58 pt row
│ │            ───────────────────────────────── │ │ inset divider
│ │  preset    Preset [Edited, when applicable] ⌃ │ │
│ │            Botaniq1                        ⌄ │ │ ≥58 pt row
│ └──────────────────────────────────────────────┘ │
│  [Contextual recovery message, only if needed]    │ 8 pt gaps
│  sliders     Open Equalizer                ⇧⌘E  │ ≥36 pt action
│ ──────────────────────────────────────────────── │ native divider
│  gear Options                      Quit myEq ⌘Q │ ≥30 pt controls
└──────────────────────────────────────────────────┘ 6 pt footer top/bottom
```

Header: 34 pt hierarchical SF Symbol tile; 10 pt symbol/text gap; app name uses `.headline` (semibold), status uses `.caption` (regular) with 3 pt spacing. The switch is the native small switch, not a custom power button. Its position conveys the requested enabled state; the text reports the actual engine state.

Selection group: 320 pt wide, 10 pt continuous content corners, semantic control background and a `separatorColor` outline (0.5 pt, 1 pt in Increase Contrast). Each row has 12 pt horizontal padding, a 20 pt symbol column, 12 pt gap, `.caption` role label and `.body` medium-weight value separated by 3 pt. Native-style up/down chevrons communicate selection. Edited is a text badge, not a color-only dot. Long names truncate in the middle; their full value remains available in native menus, help and accessibility.

Open Equalizer: full-width button, `.subheadline` label, 20 pt symbol column, shortcut aligned to the trailing edge. Footer: `.caption` labels, 12 pt outer horizontal insets, 8 pt button insets. Options contains Launch at Login and Audio Setup; it is a native menu, not a new settings window. There is no misleading Settings-window shortcut.

Typography uses semantic `Font.system` styles with the default design. Values and controls use primary label color; supporting labels derive from semantic `labelColor` at 74% opacity, promoted to full opacity in Increase Contrast. This keeps hierarchy while improving small-text contrast over the standard secondary label in light appearance. App accent follows the system accent. Green/orange status symbols always accompany a text status, so color is not the only signal.

## Material and platform decisions

`MenuBarExtra(.window)` owns the outer shape, shadow, placement and screen-edge behavior. The content uses `.ultraThinMaterial`; it does not draw a second outer rounded rectangle or a decorative shadow. Selection rows share one quiet control-background group. Native switches, menus and recovery buttons keep their system geometry.

Reduce Transparency replaces the material with an opaque `windowBackgroundColor`. Reduce Motion removes custom hover/recovery animations. Increase Contrast strengthens content borders and supporting text. These values come from SwiftUI environment preferences; the offscreen renderer can inject the same policy without modifying the user's macOS settings.

Apple recommends a standard menu for simple menu-bar commands. The requested window-style control surface is retained for the persistent power switch and inline recovery state; output/preset/options choices use actual `NSMenu` instances. This is an intentional tradeoff, not a claim that a custom panel is Apple's default recommendation. References: [menu bar extras](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar), [materials](https://developer.apple.com/design/human-interface-guidelines/materials), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra).

## Interaction specification

| Target | Behavior |
| --- | --- |
| Enable switch | Immediate requested-state change; existing engine handles startup/bypass. Preset and edits survive bypass. Header independently shows Starting, Equalizing, Bypassed, Paused or Needs attention. |
| Output row | The entire row opens an anchored native menu with a checkmark on the selected output. Selection uses the existing routing action. Empty lists show a disabled explanation. |
| Preset row | Opens all factory and personal presets, with a checkmark. Selection replaces current edits using the existing preset behavior; the accessibility hint explains this. |
| Hover | Neutral 100 ms fill change; Increase Contrast adds an outline. No scaling, bounce or moving targets. |
| Press | Open/Quit buttons darken briefly; switches and choice menus use native feedback. |
| Recovery | Error detail appears inline with Audio Setup and Retry. Paused states show the reason without irrelevant repair buttons. Detail changes crossfade over 160 ms; Reduce Motion removes this animation. |
| Open Equalizer | Closes the panel, opens/activates the existing editor. |
| Quit | Uses the existing asynchronous audio shutdown and restoration path. |

Keyboard: Tab/Shift-Tab use the native focus chain and macOS Keyboard Navigation settings. Up/Down move among available panel controls; disabled power/recovery controls are omitted. Native choice menus own arrows, type-to-select, Return and Escape while open. Space activates the focused control. Escape closes the panel. ⌘E toggles EQ, ⇧⌘E opens the editor and ⌘Q quits while the app/panel receives commands. These are app shortcuts, not global hotkeys; the existing editor ⌘0 Flat command remains unchanged. Native focus indication stays enabled.

VoiceOver: controls have names, selected output/preset values and explanatory hints; the status exposes a label and value. Decorative branding and displayed shortcut glyphs are excluded from spoken labels. No audio meters, continuously animated status indicators or timers are introduced. Menu visibility never computes response curves or enables DSP metering.

## Implementation and verification

- [MenuBarPanel.swift](../Sources/MyEqApp/MenuBarPanel.swift): composed header, selection rows, contextual notice, action/footer, semantic styles and keyboard focus.
- [PopupMenuButton.swift](../Sources/MyEqApp/PopupMenuButton.swift): existing anchored native menu adapter.
- [MyEqApp.swift](../Sources/MyEqApp/MyEqApp.swift): system appearance for the panel; editor appearance unchanged.
- [AppModel.swift](../Sources/MyEqApp/AppModel.swift): editor-only graph computation, independent menu visibility.
- [design-preview.swift](../scripts/design-preview.swift): offscreen light/dark fixtures, status/long-name/accessibility variants and regression checks.

Run `bash scripts/render-design.sh` to reproduce the previews. They are source-rendered, never-shown windows: they omit native popover chrome and do not demonstrate wallpaper vibrancy. Native switches may appear inactive because these fixture windows never become key. Actual menu tracking, Full Keyboard Access, VoiceOver reading order and live wallpaper/material appearance need an installed-window check. Automated fixtures do not certify full HIG or accessibility compliance.
