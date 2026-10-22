# Menu panel refinement — 0.4.1

The graphite, ivory and gold studio panel is retained. This revision removes the redundant Flat/Neutral and Botaniq1/Reference quick-preset cards from **Your sound** and gives **Open equalizer** the same subdued surface, ivory label and fine border as the surrounding controls. All factory and personal presets remain available through the preset name's native menu.

## Layout

```text
             354 pt, 20 pt outer inset
┌────────────────────────────────────────┐
│  myEq · engine status          Power   │
│  Output selector                       │
│  [Recovery message when needed]        │
│ ┌────────────────────────────────────┐ │
│ │ YOUR SOUND                  Edited │ │
│ │ Botaniq1                         ⌄ │ │
│ │ Static frequency-response preview  │ │
│ └────────────────────────────────────┘ │
│  AUTO PREAMP          STEREO OUTPUT    │
│  −4.8 dB              48.0 kHz         │
│  Open equalizer                ⌘⇧E ↗  │
│  Options                     Quit myEq │
└────────────────────────────────────────┘
```

Main groups retain 18 pt spacing. Your sound uses 15 pt padding, 10 pt internal gaps, a 23 pt medium preset name and a 90 pt response canvas. Open equalizer uses the shared `StudioButtonStyle` with a 12 pt medium label and 10 pt corner radius. The panel keeps the existing dark appearance to match the editor. The discarded adaptive menu redesign was not shipped.

## Interaction

- Power, output selection, preset selection, recovery and Options retain their existing actions. Output and preset selectors open anchored native menus with selection checkmarks, arrow navigation and type-to-select.
- Open equalizer closes the panel and activates the editor; its existing ⌘⇧E shortcut is retained. The shared button style provides pressed feedback without scale or movement.
- Options contains Launch at Login and Background Items. Quit retains ⌘Q and the existing shutdown path.
- The graph is static and cached. Menu-only visibility computes its 128-point curve on opening/settings changes, never starts live meters, and leaves editor curves parked. When both surfaces are hidden, visual calculations stop.

## Implementation and verification

`Sources/MyEqApp/MenuBarPanel.swift` owns the panel and its mini response graph. `DesignSystem.swift` supplies the shared button style. `AppModel.swift` gates the menu/editor calculations independently.

Run `bash scripts/render-design.sh` for never-shown source fixtures of the editor and menu (enabled, bypassed, attention and long names), including existing focus, selection and hidden-visual-work checks. These previews omit native outer popover chrome and do not establish live keyboard or VoiceOver behavior. The installed app and audio route are not modified by the renderer.
