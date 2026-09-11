# DreamBreathStasisHelper (绿喷管家)

A lightweight combat helper for **Preservation Evoker** (Flameshaper hero talent) in World of Warcraft: Midnight (12.1+).

It answers one specific question in real time: **"Is it still safe to cast Dream Breath right now?"**

## What it does

The addon monitors two things that must stay in sync:

- **Dream Breath (梦境吐息 / "绿喷")** — charge count and recharge timer, including the 2-charge bonus from the Flameshaper *Legacy of the Lifebinder* talent.
- **Stasis (静滞)** — the 90-second cooldown store that captures your next three helpful spells.

Using a combat-safe local charge-prediction model, it predicts how many Dream Breath charges you will hold when Stasis comes off cooldown, then shows a clear traffic-light signal:

- 🔴 **Red — stop!** Casting now drops you below 2 charges when Stasis is ready.
- 🟡 **Yellow — careful** — one more cast pushes you to the limit.
- 🟢 **Green — safe** — cast freely.

It also tracks Stasis' full state machine (`storing → armed → cooldown → ready`) and shows an on-screen status message plus a resizable, alpha-adjustable, lockable console panel.

## Installation

1. Download the latest release (`.zip`) from the [Releases](../../releases) page.
2. Extract the zip into your WoW AddOns folder so the result is:

```
World of Warcraft/_retail_/Interface/AddOns/
└── DreamBreathStasisHelper/
    ├── DreamBreathStasisHelper.toc
    └── DreamBreathStasisHelper.lua
```

3. Restart WoW or `/reload`.

## Usage

- Type `/DBSH` to open the config panel (on/off, scale, alpha, lock/unlock UI).

## Notes

- Requires World of Warcraft: Midnight (12.1+).
- The addon uses a local charge-prediction model because Blizzard encrypts some combat data in 12.1; it does not read protected data.
- UI text is currently in Chinese (Simplified). English localization is planned.

## License

All Rights Reserved. You may download and use this addon, but redistribution or modification requires the author's permission.
