# TinyNES Control Deck: a settings app and `nes.ini`

Status on 2026-10-14: **design for review; nothing built.** The layout is the
one the user approved, with button remapping as the first working tab and
video options to follow. This file is the thing to argue with before code.

Revised on 2026-10-14 (core-log entry 36): the Audio tab and its `volume`,
`mute` and `channels` keys are dropped. The Pmod I2S2's Line Out is a fixed
level for the amplifier to set, the NES's sound is mono, and muting a line
output is the amplifier's job too, so none of the three had anything to do.

## Goal

An app on the desktop, opened while a game runs, that changes how the game
behaves: which controller button answers to which NES button, and later
aspect and palette. Settings live in `/nes.ini` at the card
root, beside `/tang.ini`, so they survive a power cycle and can be edited from
a PC.

## `nes.ini`

Same shape as `tang.ini`: flat `key = value` under section headers, `#`
comments, and **an absent file or key means the default**, so a card with no
`nes.ini` behaves exactly as today.

```ini
# TinyNES settings.  Read when a cartridge is launched and applied to the core
# and the player.  The app on the desktop writes this file.

[tinynes]
version = 1

[input]
# Which controller button each NES button answers to, per player.  Names are
# the Wii Classic Controller's own: a b x y l r zl zr lstick rstick plus minus
# home up down left right.  HOME is never assignable: it swaps to TinyDesk.
p1_a = b          p1_b = y        p1_select = minus   p1_start = plus
p1_up = up        p1_down = down  p1_left = left      p1_right = right
p2_a = b          p2_b = y        p2_select = minus   p2_start = plus
p2_up = up        p2_down = down  p2_left = left      p2_right = right

[video]
aspect = 8:7          # 8:7 authentic, 1:1 square, 4:3 stretched
scale = 3             # 3x fills the 720p frame; 2x is smaller and centred
scanlines = off
palette = fceumm
overscan = hide       # hide or show the top and bottom 8 lines
```

The current defaults are the current behaviour, so writing the file changes
nothing until something in it is edited. That matters for the first test: the
app can be proved to load and display settings without altering the picture.

## The app

Registered like the Phosphor app — `const td_app_t s_app = {"TinyNES", launch,
"NES"}; td_app_register(&s_app);` — and opened from the start menu or the
desktop while a game runs.

**Tabs are a composition, not a widget.** TinyDesk has buttons, checkboxes,
text boxes, lists, progress bars and scrollbars, and `td_widget_set_visible`
and `td_widget_set_color`. So each tab is a button plus its own widgets hidden
or shown, with the active header recoloured. Tab-key focus traversal already
works. **There is no slider**, so every numeric option steps with `<` and `>`
buttons.

```
┌─ TinyNES Control Deck ────────────────────────────────────────────┐
│  [ Input ]   Video     Saves                                      │
├───────────────────────────────────────────────────────────────────┤
│  Player    ( ● 1 )   (   2 )                                      │
│                                                                   │
│   NES button        Wii Classic Controller                        │
│   ──────────────────────────────────────────────                  │
│   A ............    B                                             │
│   B ............    Y                                             │
│   Select .......    −                                             │
│   Start ........    +                                             │
│   Up ...........    D-pad up                                      │
│   Down .........    D-pad down                                    │
│   Left .........    D-pad left                                    │
│   Right ........    D-pad right                                   │
│                                                                   │
│   [ Remap selected ]    [ Restore defaults ]                      │
│                                                                   │
│   Press a controller button, then the NES button it should be.    │
│   HOME stays reserved: it swaps between the game and TinyDesk.    │
├───────────────────────────────────────────────────────────────────┤
│  Esc close   Tab next   Enter choose   F12 game / desktop         │
└───────────────────────────────────────────────────────────────────┘
```

`Saves` follows once save states exist; the tab is present but greyed so the
shape is right. The Video tab is as approved; there is no Audio tab.

## How a setting reaches the hardware

Two destinations, one store. The BL616 parses `nes.ini` once per launch into
a small struct; each destination reads what it needs.

- **Input** goes to the AE350 player, where the mapping lives today. The
  player cannot read the card, so it asks the host and receives the mapping
  the same way it receives a save: a headerless blob through the boot ROM's
  load protocol, into a buffer whose address it prints.
  `TinyNES SETTINGS WANT <addr> <len>` then the raw struct. This reuses the
  path a save already uses, including the fix that a save must not carry the
  `TNR1` header.
- **Video** goes to `video.sv` registers: aspect, scale, scanlines, overscan.
  The palette is already a 768-entry store the core writes.

Applying at launch only is the first version: the app writes the file, and the
settings take effect on the next game start. Live application — reading the
file when the app saves and pushing it into the running core — is a second
step, and worth deferring because it needs the app to know a game is running.

## First cycle, in order

1. `nes.ini` reader and defaults on the BL616, with the `tang` command
   reporting what it parsed, so the file can be proved without a GUI.
2. The app skeleton: window, four tab headers, one page each, reading the
   parsed settings and displaying them. Proves the GUI and nothing else.
3. Remapping end to end: the Input tab edits the struct, writes `nes.ini`,
   and the player receives it and maps buttons accordingly.
4. Video options, once the app can deliver a setting.

## Open questions

- **Per game or global?** Global is one file and the design above. Per game
  would be `saves/<cartridge>.ini` with the global as fallback — better for
  button maps that differ per title, more moving parts. Not decided.
- **Where does the app live?** TinyTang, beside the Phosphor app, since it is
  a desktop app and the settings store is the BL616's.
- **Does the app need the game running?** Video options are worth watching
  while changing, input is not. The app can work either way.
