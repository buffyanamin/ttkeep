# ttkeep

Keep True Tone's colour on external displays when the MacBook lid is closed.

## Why

True Tone also warms external displays. That includes third-party monitors that have no True Tone toggle of their own, but only while the MacBook lid is open, because the ambient light sensor is in the lid. In clamshell mode the sensor goes dark and the external displays fall back to a cooler, neutral white. ttkeep remembers what True Tone was applying and keeps it after you close the lid.

## How it works

1. **Lid open:** ttkeep reads the colour matrix that True Tone applies to each display, using
   `/usr/libexec/corebrightnessdiag status-info` (CoreBrightness). It saves each external display's white gains, keyed by display UUID.
   It only saves a reading once True Tone has been stable for a while: it ignores readings from less than 10 s after the lid opens and from the last 10 s before it closes, because True Tone is still changing then.
2. **Lid closed** (`AppleClamshellState` from IOKit): ttkeep re-creates those gains on each external display with `CGSetDisplayTransferByFormula`.
   True Tone's gains are linear-light, so they're converted to the transfer table with gamma 2.2, which matched True Tone visually in testing.
   ttkeep re-applies them every 5 s and after display changes, sleep and wake.
3. **Lid opens again:** ttkeep restores the ColorSync settings and True Tone takes over.

Saved gains are stored in `~/Library/Application Support/ttkeep/gains.json`, so they survive restarts.

## Requirements

- A MacBook with True Tone, macOS 13 or later (tested on an M1 Pro running macOS 15.8)
- True Tone **on** for the built-in display (System Settings → Displays)
- Xcode Command Line Tools (`swiftc`)

## Build & install

```sh
./build.sh            # builds build/ttkeep (CLI) and build/ttkeep.app
./build.sh install    # also copies ttkeep.app to ~/Applications and launches it
```

## Menu bar app

The icon is a monitor whose screen is tinted with the current True Tone colour.

| Icon | State |
|---|---|
| Light amber screen | Lid open, following True Tone |
| Solid amber screen with an orange sun badge | Lid closed, holding True Tone's colour |
| Grey screen with a red slash | Paused |

Menu items:

- **Keep True Tone Colour:** turns holding on or off.
- **Strength:** 50%, 75%, same as True Tone (default), 125% or 150%.
- **Preview Held Colour (10 s):** turn True Tone off first, then compare.
- **Launch at Login**
- **Display Settings…**
- **Quit:** restores the displays.

## CLI

```sh
build/ttkeep status            # lid state; per display: live True Tone gains, saved gains, applied table
build/ttkeep apply --hold 20   # visual test: apply saved gains for 20 s (turn True Tone off first)
build/ttkeep run               # headless service, same engine as the app
```

Options: `--gamma 2.2`, `--interval 5`, `--settle 10`.

Don't run `ttkeep run` and the app at the same time, because both would try to control the displays.

## Limitations

- `corebrightnessdiag`'s output format is undocumented and could change in a macOS update. If that happens, `status` will show `not active` for each display.
- While the lid is closed, the colour is frozen at what True Tone was applying just before you closed it. It doesn't follow changes in room lighting, because nothing can sense the room.
- The colour adjustment only lasts while ttkeep is running. If ttkeep quits, macOS restores normal colour.
- ttkeep works alongside Night Shift rather than replacing it, so if Night Shift is on, the two add up.

## Uninstall

Quit the app, turn off **Launch at Login** if you enabled it, then:

```sh
rm -rf ~/Applications/ttkeep.app "$HOME/Library/Application Support/ttkeep"
```

## Files

| File | Purpose |
|---|---|
| `Core.swift` | Engine: CoreBrightness snapshot, lid state, display mapping, apply/restore |
| `App.swift` | Menu bar app (AppKit) |
| `main.swift` | CLI |
| `build.sh` | Builds the CLI and the app bundle (ad-hoc signed) |
