# HoT Predict

A WoW Forever addon that extends Blizzard's health bars with the healing your own HoTs (Rejuvenation, Renew,
Regrowth's HoT and the like) still have to do. It's drawn right after the filled part of the bar, like the
incoming-heal bar of a cast, and spills past the end of the bar when it would overheal.

Works on Blizzard's player, target, focus and party frames and on the compact party/raid frames.

## Install

- **WowUp:** Get Addons, Install from URL, paste `https://github.com/padmanek/HotPredict`.
- **By hand:** download `HotPredict-vX.Y.Z.zip` from [Releases](https://github.com/padmanek/HotPredict/releases)
  and unzip it into `World of Warcraft\_forever_\Interface\AddOns`.

## Commands

| Command | What it does |
|---|---|
| `/hotp on` / `/hotp off` | Turn it on or off |
| `/hotp alpha 0.55` | Opacity of the segment (0.1 to 1) |
| `/hotp scale 1` | Multiplies the predicted HoT amounts (applies to new casts) |
| `/hotp inset 3` | Trims the segment's height on frames whose border art covers part of the bar |
| `/hotp clip on` / `off` | Cut the segment off at the end of the bar instead of letting overheal spill past it (`/reload` to apply) |
| `/hotp test` | Shows a test HoT of 30% max health for 12 seconds on your target (or you) |
| `/hotp debug` | Prints what it is tracking and the last error |

## Limits

WoW Forever doesn't let addons read the combat log, or auras in combat. So HoT Predict follows **your own** HoT
casts: it reads the HoT's amount and duration from the spell's description and counts down what's left. Other
players' HoTs can't be tracked by any addon.

## License

MIT
