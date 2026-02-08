# VeevHUD TODO

Consolidated from Discord/Reddit feedback, internal ideas, and bug reports.

---

## SpellDB Gaps

Reported missing or broken spell support (not confirmed fixed):

*(None currently)*

---

## Bugs

- **Masque reload required on icon size / aspect ratio change** — Changing icon size or aspect ratio with Masque installed currently requires a UI reload. Investigate whether Masque's `ReSkin()` or `Group:ReSkin()` API can be called to update button skins in-place without a full reload.
- **Desperate Prayer row assignment** — Should default to Utility row, not Primary/Secondary.
- **Timer text rounding** — Buff/debuff minute display rounds *down* while WoW's native buff bar rounds *up* (e.g., addon shows "3m" when WoW shows "4m"). *(Shadowhawk)*
- **Resource-gated cooldown transition** — When an ability comes off cooldown but the player lacks the resource (e.g., rage) to cast it, the icon transition is jarring — it briefly looks ready, then snaps to the "not usable" state instead of filling smoothly. Investigate a more seamless visual path for this case.

---

## Feature Requests — High Priority

These were requested by multiple people or have strong gameplay impact.

- **Weapon Swing Timer** — Highly requested across multiple classes. Should include:
  - Basic MH/OH swing bars for all melee
  - Hunter: auto shot timer with shot-clipping indicator (show safe window for casting without delaying auto shot)
  - Enhancement Shaman: MH/OH sync bar (warn when swings are >0.5s apart for Windfury optimization)
  - Arms Warrior: slam cast timing indicator
  - Paladin: seal twist timing window
  *(Togg, Shadowhawk, Artvil, RidiculedDaily, anonymous French warrior)*
- **Built-in Cast Bar** — Replace Blizzard's default cast bar with one integrated into the HUD layout. *(Togg)*
- **Druid: Form-Conditional Abilities** — Option to show/hide abilities based on current shapeshift form (e.g., hide caster spells in Cat Form, hide Cat abilities in caster form). *(Birdehh, Shadowhawk)*
- **Druid: Mana Bar in Forms** — Show mana bar alongside energy/rage bar while shapeshifted, so Druids can monitor mana for shifting back. *(Birdehh, Shadowhawk)*

---

## Feature Requests — Medium Priority

- **Custom Buff/Debuff Display Near Health Bar** — Let users select arbitrary important buffs and debuffs to display near the health bar (extending beyond just procs), keeping all critical info in one place. *(Soveliss)*

- **Configurable Bar/Icon Position** — Allow icons to appear above the health/resource bars instead of only below. Options: above primary, between primary/secondary, between secondary/utility, below all. *(FionaSilberpfeil, Shadowhawk)*
- **Trinket Tracking** — Track trinket use/on-use cooldowns and proc buffs. Consider smart row assignment (throughput trinkets → secondary row, utility → utility row). *(Independent-Bother17)*
- **Grouped Category Icons** — Instead of separate icons for every totem/seal/blessing, show one icon per category (e.g., one Earth Totem icon, one Seal icon) that reflects whichever is currently active. Reduces icon clutter for Shamans and Paladins. *(Shadowhawk)*
- **Track Shared Debuffs from Any Caster** — Debuffs like Faerie Fire and Sunder Armor should show on your HUD even when applied by another player, since only one instance of the debuff matters. Should also handle cross-ability equivalence (e.g., Sunder Armor and Expose Armor share the same armor-reduction debuff slot). *(Artvil)*
- **Totem Duration Tracking** — Basic duration tracking shipped in 1.0.50. Still considering a more comprehensive totem model (grouped category icons, element-aware UI). *(Shadowhawk)*
- **Dual Countdown on Icons (CD + Debuff)** — For abilities where both a cooldown and a debuff matter (e.g., Mangle Cat — no CD but debuff is key), show a secondary timer in an icon corner so both can be tracked on one icon without adding a separate icon. *(Artvil)*
- **Single-Application Buff Tracking** — Track buffs that can only exist on one target at a time (e.g., Prayer of Mending) regardless of current target. Show duration/stacks even when a different unit is targeted. *(Earth Shield tracking covered by Buff Reminders.)*
- **Health Bar Improvements** — Potential enhancements:
  - Text options: max health, health deficit, whole numbers (not just "k" abbreviation)

---

## Feature Requests — Low Priority / Ideas

- **PvP Trinket Tracking** — Track PvP trinket cooldown.
- **WoW Animation API** — Migrate animations to use WoW's built-in Animation system for smoother/more efficient playback. *(Buff Reminders already uses native Animation API; consider migrating other modules.)*
- **Separate Movable Buffs Bar** — A dedicated area for tracking arbitrary buffs that can be positioned independently from the main HUD stack. *(Shadowhawk)* *(Maintenance buffs now covered by Buff Reminders; this request is for broader arbitrary buff tracking.)*

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
| Queued ability icon highlight                                    | 1.0.46  | Bright overlay when next-melee is queued        |
| Predicted resource cost on bar                                   | 1.0.46  | Darkened section for queued/casting cost         |
| Proc tracker: multi-rank matching                                | 1.0.46  | Detects all talent ranks, not just max          |
| Custom bar textures                                              | 1.0.45  | SharedMedia support for all bars                |
| Predicted rage/resource loss on bar                              | 1.0.46  | Expanded to all resource types                  |
| Configure Proc Tracker                                           | 1.0.47  | Enable/disable procs in Spell Configuration     |
| Cast Feedback black box visual artifact                          | 1.0.45  | Fixed large black flash on spells like Icy Veins |
| AceConfig click-through bug                                      | 1.0.43  | Clicking scroll bar no longer opens spell menu   |
| Proc icon max size increase                                      | 1.0.47  | Allows proc icons to scale much larger           |
| Health bar: heal prediction overlay                               | 1.0.48  | Shows incoming heals as lighter bar section       |
| Health bar: absorb shield overlay                                 | 1.0.48  | Shield-Fill texture for PWS, Ice Barrier, etc.    |
| Health bar: over-absorb glow                                      | 1.0.48  | Edge glow when absorbs exceed missing health      |
| Health bar overlay options (toggles)                              | 1.0.48  | Heal prediction, absorbs, over-absorb glow        |
| Resource bar predicted cost toggle                                | 1.0.48  | Option to disable predicted cost overlay          |
| Queued ability highlight toggle                                   | 1.0.48  | Option to disable queued icon highlight           |
| Config defaults audit                                             | 1.0.48  | All defaults managed by AceDB, no inline fallbacks|
| Health bar: custom color picker                                    | 1.0.41  | Beyond class-colored toggle *(Shadowhawk)*         |
| Ultrawide monitor support: expanded X/Y offset range               | 1.0.49  | Range beyond ±500 px for ultrawide resolutions     |
| Shaman: Totem duration tracking                                    | 1.0.50  | All totems show active duration countdown, 1-per-element enforced |
| Buff Reminders                                                     | 1.0.51  | Missing/expiring buff alerts with per-spell config, BuffGroup-aware, WeakAura-style animations |
| Battle Shout / Short Buff Tracking                                 | 1.0.51  | Covered by Buff Reminders (all LONG_BUFF spells)   |
| Missing Buff Alert / Inverse Glow                                  | 1.0.51  | Covered by Buff Reminders                          |
| Buff Expiry Reminders                                              | 1.0.51  | Covered by Buff Reminders with time threshold config |
| Lightning Shield Stack Tracking                                    | 1.0.51  | Covered by Buff Reminders with min stacks config   |
| Shaman: Weapon buff duration tracking                              | 1.0.51  | Buff Reminders tracks weapon enchants via GetWeaponEnchantInfo |
| Long buff tracking consistency (Thorns, weapon buffs, etc.)        | 1.0.51  | All LONG_BUFF spells now tracked by Buff Reminders |
| Earth Shield party/raid tracking                                   | 1.0.51  | Covered by Buff Reminders with party/raid target config |
