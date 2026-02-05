# VeevHUD TODO

Scratchpad for ideas, bugs, and public feature requests.

> **AI Instructions**: When completing an item, DELETE it from this file rather than marking it as done. This keeps the TODO clean and focused on remaining work.

## Ideas

- Configure which procs show up
- Add PvP trinket tracking/support
- Allow custom textures for bars
- Use the WoW animation API for (ideally) all animations

## Bugs

- Mage: Icy Veins causes a black "pop" visual artifact that fills the screen (happens every cast, not just first)
- Desperate Prayer should be on util row.

## Public Feature Requests

- Track queued autoattack abilities (Heroic Strike, Cleave, Maul) — show like Blizzard buttons do, or via a color-changing weapon swing timer
- Druid: show abilities conditionally based on current form (hide unusable abilities)
- Druid: option to show mana bar while in cat/bear form
- Configurable bar position — allow icons above health/mana bars (options: above primary, between primary/secondary, between secondary/utility, below all)
- Battle Shout reminder
- Trinket buff/aura tracking (consider: utility row, own row, or intelligent assignment based on throughput?)
- Enhancement Shaman: weapon swing timer / sync bar (show MH/OH delta, warn if >0.5s apart)

## Debug / Packaging

- Fix duplicate file load warning: `LibSpellDB-1.0.16/LibSpellDB.toc:22` duplicate load of `LibSpellDB/Data/Data.xml` (first loaded at `LibSpellDB/lib.xml:14`)
- Fix missing embedded lib reference: `VeevHUD/Libs/embeds.xml:22` couldn't open `VeevHUD/LibSpellDB-1.0.16/lib.xml`
