# StoryTracker — WoW Character Chronicle Addon

Records every detail of your WoW journey for storytelling. A companion addon for
[My-Azeroth-Life](https://myazerothlife.com) — generates daily narrative blog
posts from your actual gameplay.

## What It Tracks

Every session is recorded to SavedVariables with timestamps, zones, and details:

| Category | What Gets Recorded |
|----------|-------------------|
| **Quests** | Accepted, completed, abandoned — with names and levels |
| **Zones** | Every zone, subzone, and continent change |
| **Levels** | Your dings and your party members' dings |
| **Deaths** | Where, who killed you, and with what ability |
| **Dungeons** | Entered, bosses killed, completed (via ENCOUNTER_END) |
| **Loot** | Rare, epic, and legendary items — plus mounts |
| **Reputation** | Every faction standing change |
| **Professions** | Skillups and recipes learned |
| **Gold** | Earned, spent, and session net totals |
| **Combat** | Notable elite/rare/world boss kills |
| **Social** | Guild join/leave, party/raid formation |
| **PvP** | Honorable kills, battlegrounds, duels |
| **Sessions** | Login/logout times, duration, zones |

## Installation

1. Download the latest release from [CurseForge](#) or the [Releases page](https://github.com/ninepointlabs/wow-storytracker-addon/releases)
2. Extract to `World of Warcraft/_classic_era_/Interface/AddOns/StoryTracker/`
3. The addon works immediately — no configuration needed

## How It Works

StoryTracker hooks into WoW's event system and records structured data to
`StoryTrackerDB` SavedVariables. On logout or `/reload`, the file
`WTF/Account/<account>/SavedVariables/StoryTracker.lua` is written to disk.

A companion Python script (in the [storytracker repo](https://github.com/ninepointlabs/wow-storytracker))
reads that file, detects new events since the last report, and feeds them
to an AI that composes narrative blog posts in character as a weathered
Azeroth chronicler.

Blog posts land at [myazerothlife.com](https://myazerothlife.com).

## Compatibility

Built for **WoW Forever** (Classic 1.15.6). May work on later Classic patches
— bump the `## Interface` line in `StoryTracker.toc` if needed.

## Slash Commands

- `/storytracker` — show event and session count
- `/storytracker debug` — toggle debug mode

## License

MIT © 2026 Tim

## Privacy

All data stays on your machine. The SavedVariables file never leaves your
computer. Blog posts are generated locally by your own AI agent, not by
any external service.