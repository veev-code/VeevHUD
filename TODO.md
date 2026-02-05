# VeevHUD TODO

Scratchpad for ideas, bugs, and public feature requests.

## Ideas

- [ ] Configure which procs show up
- [ ] Add PvP trinket tracking/support
- [ ] Allow custom textures for bars
- [ ] Track queued abilities (e.g., Heroic Strike)
- [ ] Use the WoW animation API for (ideally) all animations

## Bugs

- [ ] Energy ticker timing seems off (possibly due to powershifting)
- [ ] Option: keep energy ticker running even at full energy (useful for timing openers on the next tick)
- [ ] Fix the black popup

## Public Feature Requests

- [ ] Faerie Fire (Feral)
- [ ] Track queued autoattack replacement abilities (Heroic Strike, Cleave, Maul) like Blizzard buttons do, or via a color-changing weapon swing timer
- [ ] Mangle (Bear): when debuff tracking is enabled and the debuff lasts longer than the cooldown, dynamically show cooldown remaining instead of only the debuff timer
- [ ] Druid: show abilities conditionally based on form (instead of always showing everything)
- [ ] Druid: option to show mana bar while in form
- [ ] Option to show icons above the health/mana bars (not only under)
- [ ] Battle Shout reminder
- [ ] Trinket tracking (general)
- [ ] Enhancement: add a weapon sync bar (if not already present)
- [ ] Add keybind text on icons

## Debug / Packaging

- [ ] Fix duplicate file load warning: `LibSpellDB-1.0.16/LibSpellDB.toc:22` duplicate load of `LibSpellDB/Data/Data.xml` (first loaded at `LibSpellDB/lib.xml:14`)
- [ ] Fix missing embedded lib reference: `VeevHUD/Libs/embeds.xml:22` couldn't open `VeevHUD/LibSpellDB-1.0.16/lib.xml`
