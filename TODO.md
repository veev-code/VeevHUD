# VeevHUD TODO

Consolidated from Discord/Reddit feedback, internal ideas, and bug reports.

---

## SpellDB Gaps

Reported missing or broken spell support (not confirmed fixed):

- **Shaman:** Weapon buff durations not tracked. *(Shadowhawk)*
- **General:** Inconsistent buff tracking — some long buffs (Thorns, weapon buffs) track while others don't. *(Shadowhawk)*

---

## Bugs

- **Cast feedback black "pop" artifact** — Icy Veins (and some other spells) cause a large black box that fills part of the screen during cast feedback animation. Happens every cast, not just the first. Reported by multiple users. Workaround: disable cast feedback. *(Shadowhawk, FionaSilberpfeil, Syn2108)*
- **Masque reload required on icon size / aspect ratio change** — Changing icon size or aspect ratio with Masque installed currently requires a UI reload. Investigate whether Masque's `ReSkin()` or `Group:ReSkin()` API can be called to update button skins in-place without a full reload.
- **Desperate Prayer row assignment** — Should default to Utility row, not Primary/Secondary.
- **Timer text rounding** — Buff/debuff minute display rounds *down* while WoW's native buff bar rounds *up* (e.g., addon shows "3m" when WoW shows "4m"). *(Shadowhawk)*

---

## Feature Requests — High Priority

These were requested by multiple people or have strong gameplay impact.

- **Weapon Swing Timer** — Highly requested across multiple classes. Should include:
  - Basic MH/OH swing bars for all melee
  - Hunter: auto shot timer with shot-clipping indicator (show safe window for casting without delaying auto shot)
  - Enhancement Shaman: MH/OH sync bar (warn when swings are >0.5s apart for Windfury optimization)
  - Arms Warrior: slam cast timing indicator
  - Paladin: seal twist timing window
  - Consider: queued next-attack indicator (Heroic Strike, Cleave, Maul) — show which ability is queued, like Blizzard's default buttons do, or via a color change on the swing bar
  *(Togg, Shadowhawk, Artvil, RidiculedDaily, anonymous French warrior)*
- **Built-in Cast Bar** — Replace Blizzard's default cast bar with one integrated into the HUD layout. *(Togg)*
- **Druid: Form-Conditional Abilities** — Option to show/hide abilities based on current shapeshift form (e.g., hide caster spells in Cat Form, hide Cat abilities in caster form). *(Birdehh, Shadowhawk)*
- **Druid: Mana Bar in Forms** — Show mana bar alongside energy/rage bar while shapeshifted, so Druids can monitor mana for shifting back. *(Birdehh, Shadowhawk)*

---

## Feature Requests — Medium Priority

- **Configurable Bar/Icon Position** — Allow icons to appear above the health/resource bars instead of only below. Options: above primary, between primary/secondary, between secondary/utility, below all. See `TODO-Layout.md` for the full drag-and-drop layout spec. *(FionaSilberpfeil, Shadowhawk)*
- **Trinket Tracking** — Track trinket use/on-use cooldowns and proc buffs. Consider smart row assignment (throughput trinkets → secondary row, utility → utility row). *(Independent-Bother17)*
- **Battle Shout / Short Buff Tracking** — Battle Shout doesn't appear in spell list. Also applies to other short-duration party buffs that need reapplication reminders. *(Shadowhawk, anonymous French warrior)*
- **Configure Proc Tracker** — Let users choose which procs show/hide in the proc tracker area. Currently all detected procs display automatically. *(Shadowhawk)*
- **Missing Buff Alert / Inverse Glow** — Glow or visual indicator when an important buff is *missing* (e.g., Battle Shout fell off, self-buff expired). Opposite of the current "active proc" glow. *(Shadowhawk)*
- **Grouped Category Icons** — Instead of separate icons for every totem/seal/blessing, show one icon per category (e.g., one Earth Totem icon, one Seal icon) that reflects whichever is currently active. Reduces icon clutter for Shamans and Paladins. *(Shadowhawk)*
- **Health Bar Improvements** — The current health bar is basic. Potential enhancements:
  - Text options: max health, health deficit, whole numbers (not just "k" abbreviation)
  - Custom color picker (beyond class-colored toggle)
  - Heal predictions (incoming heal overlay)
  - Shield/absorb estimations
  - *Note: Veev considers this lower priority — users can supplement with a dedicated unit frame addon.* *(Shadowhawk)*

---

## Feature Requests — Low Priority / Ideas

- **PvP Trinket Tracking** — Track PvP trinket cooldown.
- **Custom Bar Textures** — Allow users to select bar textures (via SharedMedia).
- **WoW Animation API** — Migrate animations to use WoW's built-in Animation system for smoother/more efficient playback.
- **Separate Movable Buffs Bar** — A dedicated area for tracking buffs that can be positioned independently from the main HUD stack. *(Shadowhawk)*
- **Predicted Rage Loss** — Show the rage cost of the queued next-attack ability on the resource bar (e.g., darkened section for Heroic Strike cost). *(anonymous French warrior)*

---

## Implemented

Items from feedback that have been completed, with the version they shipped in.


| Request                                                          | Version | Notes                                          |
| ---------------------------------------------------------------- | ------- | ---------------------------------------------- |
| Migrate to AceConfig (draggable, better sliders, type-in values) | 1.0.41  | Full AceConfig-3.0 migration with AceGUI       |
| Profiles + per-spec switching                                    | 1.0.41  | AceDBOptions-3.0 + LibDualSpec-1.0             |
| Horizontal offset                                                | 1.0.41  | `anchor.x` setting in General > Position       |
| Max icons per row configurable                                   | 1.0.41  | Per-row setting in Rows config tab             |
| Summon stack count (pets)                                        | 1.0.40  | Shows living pet count                         |
| Keybind text on icons                                            | 1.0.39  | Scans action bars, shows abbreviated keys      |
| Mana tick "Next Full Tick" accuracy                              | 1.0.38  | Major 5SR prediction improvements              |
| Faerie Fire (Feral) tracking                                     | 1.0.37  | Tracked separately from caster version         |
| Mangle (Bear) cooldown priority                                  | 1.0.37  | Shows 6s CD instead of 12s debuff              |
| Summon Water Elemental                                           | 1.0.37  | Added to Mage spell list                       |
| Raptor Strike                                                    | 1.0.37  | Added to Hunter spell list                     |
| Mongoose Bite                                                    | 1.0.37  | Added to Hunter spell list                     |
| Hunter's Mark                                                    | 1.0.37  | Added to Hunter spell list                     |
| Energy ticker at full energy option                              | 1.0.36  | "Show at Full Energy" toggle, default ON       |
| Druid powershifting energy tick reset                            | 1.0.36  | Tick timer resets on Cat Form entry            |
| Duplicate racial icons (Blood Fury, etc.)                        | 1.0.36  | Fixed via spell variant deduplication          |
| Cooldown finish sparkle (bling)                                  | 1.0.34  | Per-row configurable                           |
| Smooth dim transition                                            | 1.0.34  | Gradual fade on cooldown                       |
| UI scale auto-compensation                                       | 1.0.32  | HUD size consistent across UI scale settings   |
| Range indicator                                                  | 1.0.28  | Red overlay when out of range                  |
| Row gap improvements / layout system                             | 1.0.26  | Central layout manager, increased gap maximums (bumped again in 1.0.41) |
| Font customization                                               | 1.0.25  | Global font with SharedMedia support           |
| Text format options (health/resource)                            | 1.0.25  | Current, Percent, Both, None                   |
| Mana tick indicator                                              | 1.0.22  | Two modes: Outside 5SR, Next Full Tick         |
| Resource prediction (cost timer)                                 | 1.0.22  | Extends cooldown spiral for resource regen     |
| Energy tick indicator                                            | 1.0.21  | Ticker Bar or Spark style                      |
| Combo points display                                             | 1.0.19  | Rogues + Feral Druids                          |
| Dynamic sort by time remaining                                   | 1.0.14  | Icons reorder by actionable time               |
| Icon zoom                                                        | 1.0.12  | Crop icon edges (0-60%)                        |
| Icon aspect ratio                                                | 1.0.11  | Square, 4:3, 2:1 options                       |
| Out of combat alpha                                              | 1.0.10  | Fade HUD when not in combat                    |
| Proc tracker with options                                        | 1.0.9   | Glow, backdrop, slide animation, sizing        |
| Shaman: Shamanistic Focus + Flurry proc tracking                 | 1.0.42  | Added to LibSpellDB proc data                  |
| Paladin: Seal of the Crusader at all levels                      | 1.0.42  | Added all 7 ranks to LibSpellDB                |
| Priest: Clearcasting (Holy Concentration) proc tracking           | 1.0.42  | Added to LibSpellDB proc data                  |
| Warrior: Blood Craze proc tracking                               | 1.0.42  | Added to LibSpellDB proc data                  |


