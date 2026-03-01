# RaidLootTracker | by Koosche | 
# Please let me know if you're encountering bugs. 

WotLK 3.3.5a addon for master looters running MS > OS > Tmog. Tracks rolls, handles +1 penalties, auto-fills trade windows, and logs every decision. Built for Bronzebeard Ascension.

---

## What it does

You link an item, people roll, you click Resolve. Winners get announced to the raid, their +1 count updates automatically, and when they open a trade with you the item gets dropped into the slot without you having to dig through your bags.

The system is MS > OS > Tmog with a +1 penalty on MS wins. If two people both roll MS, the one with fewer previous wins gets priority. If someone wins uncontested (only one MS roller), no +1 is applied.

---

## Installation

Drop the `RaidLootTracker` folder into your addons directory:

```
/Interface/AddOns/RaidLootTracker/
```

Reload or log in. Type `/rlt` to open the window.

---

## Usage

1. Open the window with `/rlt` or the minimap button
2. `/rlt roll` then paste an item link, or `/rlt roll [itemlink]` directly
3. Raiders type `/roll 100` MS · `/roll 99` OS · `/roll 98` Tmog
4. Hit **Resolve** when rolls are in
5. Winners announced to raid, +1s updated, trade auto-fills when they open with you

The timer counts down and stops accepting rolls at zero — but you still manually hit Resolve to finalize.

---

## Roll priority

| Command | Type | +1 penalty |
|---|---|---|
| `/roll 100` | Main Spec | yes, if contested |
| `/roll 99` | Off Spec | no |
| `/roll 98` | Transmog | no |

MS sorts by adjusted value (raw roll minus +1 count). OS and Tmog sort by raw roll. MS always beats OS, OS always beats Tmog regardless of numbers.

---

## Settings

**Roll Timer** — countdown before rolls close. Default 20s, adjust with +/- up to 300s.

**Auto-Loot** — loots the boss corpse automatically when you're ML.

**Auto-Trade** — when a winner opens trade with you, pulls the item from your bags and slots it automatically. Announces to raid on completed trades only — cancels are ignored.

**Announce Channel** — RAID, PARTY, or SAY.

---

## Commands

```
/rlt                                    toggle window
/rlt roll [item] [count]                start a roll session
/rlt resolve                            resolve current session
/rlt cancel                             cancel session or stop timer
/rlt addroll <name> <value> [ms|os]     add a roll manually
/rlt removeroll <name>                  remove a roll
/rlt showrolls                          print sorted roll order to chat
/rlt plusones                           print +1 standings
/rlt setplusone <name> <number>         set someone's +1 count
/rlt resetplusone <name>                reset one person to 0
/rlt resetall                           wipe all +1 data
/rlt log [n]                            print last N decisions (default 10)
/rlt autoloot on|off                    toggle auto-loot
/rlt channel raid|party|say             change announce channel
/rlt status                             show current config
/rlt test                               load fake data to preview the UI
/rlt help                               all commands
```

---

## Notes

- Only the ML needs the addon. Raiders just `/roll`.
- `RaidLootTrackerDB` persists +1 data and loot log across sessions.
- Minimap button is draggable.
- Built and tested on Bronzebeard Ascension (WotLK 3.3.5a).
- Test mode shows a simulation of how the addon works. You'll need to reset the tables once it's done.

---

made by Koosche
