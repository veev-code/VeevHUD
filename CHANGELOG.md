# VeevHUD Changelog

## [1.0.166] - 2026-03-12

### Fixed
- **Druid Form Icon** — The stance/form indicator in the Auxiliary Row now shows the correct spell-specific icon for each druid form (e.g., Dire Bear Form, Cat Form) instead of the generic shapeshift bar texture. Warriors and Paladins are unaffected.

## [1.0.165] - 2026-03-12

### Fixed
- **Reagent-based usability** — Spells that require a reagent (e.g., Soul Shards for warlock abilities) now correctly appear desaturated/unusable when the player has none of that reagent. WoW's built-in `IsUsableSpell` does not check reagent availability in Classic, so VeevHUD now checks separately using LibSpellDB's reagent data.

## [1.0.164] - 2026-03-12

### Changed
- **Warlock: Cleaner Default HUD** — Reduced icon clutter for warlocks out of the box. Soul Fire now only shows for Destruction spec. Filler spells (Drain Soul, Drain Life, Drain Mana, Rain of Fire, Hellfire) are hidden by default. Pet summon icons (Imp, Voidwalker, Succubus, Felhunter, Felguard) are hidden. Inferno (1hr CD) is hidden. All can still be manually enabled via the Spells config. Fel Domination remains visible for Demonology.
- **Stack Count Threshold** — Aura stack counts (Sweeping Strikes, Rampage, Sunder Armor, etc.) now display at 1 stack instead of only at 2+. This makes it easier to see remaining charges on abilities like Sweeping Strikes.

### Added
- **Reagent Count on Icons** — Spells that consume a reagent (e.g., Soul Shards for warlock abilities) now show the current reagent count as a stack number in the top-right corner of the icon. Applies to Shadowburn, Soulshatter, Create Soulstone, Create Healthstone, and Soul Fire (Destruction).

### LibSpellDB Updates
- New `reagentItemID` field and `GetReagentItemID()` API for spells that consume items on cast.
- Warlock spell data updated: Soul Fire restricted to Destruction, filler tags added to 5 spells, pet summons tagged OUT_OF_COMBAT, Inferno set to manual-enable, reagent data added to 13 spells.

## [1.0.163] - 2026-03-12

### Fixed
- **Debuff tracking on neutral mobs** — Curses, DoTs, and other debuffs were not tracked on neutral (yellow) mobs like wildlife. The icon would not show the active debuff duration even though the spell was successfully applied. Now works correctly on all attackable targets. *(Thanks Deadlyy Dan for reporting)*

## [1.0.162] - 2026-03-11

### Added
- **Cooldown Pulse: Trinket Support** — On-use trinkets now flash a cooldown pulse when they come off cooldown, just like regular abilities.

## [1.0.161] - 2026-03-11

### Changed
- **Buff Reminders: Default Position** — Increased default Y offset from 24 to 30 pixels for better spacing above the HUD.

### Fixed
- **Ability Rows: Appearance Tab** — Fixed intro description appearing at the bottom of the tab instead of the top. Corrected description text that incorrectly mentioned overriding "size" (only shape can be overridden from this tab).

## [1.0.160] - 2026-03-11

### Added
- **Cooldown Pulse** — A new feature — inspired by addons like Doom_CooldownPulse — that flashes a large ability icon in the center of your screen when it comes off cooldown. Configurable icon size, opacity, position, animation style (grow/shrink/none for fade-in and fade-out), and timing. Includes per-row filtering, combat-only mode, minimum cooldown threshold, and early trigger. Shared-cooldown dedup ensures only the spell you actually cast pulses (e.g., shaman shocks). Masque-compatible. Configure in the new **Cooldown Pulse** tab.
- **Per-Aura Glow Toggle** — Individual auras in the Aura Tracker can now have their glow effect enabled or disabled independently.

### Changed
- **Options UI Polish** — Improved labels, tooltips, and organization across 11 tabs. Renamed settings for clarity (e.g., "Cast Pop" → "Cast Feedback", "Persistent Glow" → "Re-trigger Glow"). Added intro descriptions to tabs. Merged Opacity into Appearance (one fewer tab in Ability Rows).
- **Cooldown Pulse: Lockout Spell Support** — Spells gated by lockout debuffs (like Power Word: Shield / Weakened Soul) now correctly pulse when the lockout expires, even if the spell's buff effect is still active on the target.
- **Cooldown Pulse: Cross-Session Support** — Long cooldowns (10-30 min) that were cast before logging in or reloading now correctly pulse when they expire.

### Fixed
- **Cooldown Pulse: Masque Icon Size** — Fixed Masque intercepting icon size changes, causing pulse icons to ignore the size slider. Now uses scale-based sizing that Masque can't override.

## [1.0.159] - 2026-03-11

### Changed
- **AuraState Simplification** — Aura type detection now delegates to LibSpellDB's `GetAuraType()` and `IsHelpfulSpell()` APIs instead of iterating spell tags internally. Cleaner code with identical behavior.

### Fixed
- **Seal of Command Detection** — Fixed Ret Paladin swing bar Seal of Command check to use name-based buff lookup instead of spell ID, matching Anniversary Edition buff IDs correctly.

### LibSpellDB Updates
- **Explicit-only `GetAuraTarget()`** — No longer infers aura target from tags or conventions. All spells now declare their `auraTarget` explicitly, eliminating an entire class of silent misclassification bugs.
- **New APIs: `GetAuraType()`, `IsHelpfulSpell()`** — Derived from the explicit `auraTarget` field. Consumers no longer need to iterate tags to determine buff vs debuff.
- **32-rule CI validation** — Spell data integrity validated on every push with Python-based CI, catching issues like missing `auraTarget`, rank/appliesBuff mismatches, and tag inconsistencies before they ship.
- **5 spell data fixes** — Pounce, Misdirection, Stormstrike, Bloodrage, and Rampage now have correct `auraTarget` values.

## [1.0.158] - 2026-03-11

### Changed
- **Debuff Tracking: Structural Fix** — Replaced the v1.0.157 workaround with a proper fix via LibSpellDB. Enemy debuff spells now correctly report `"enemy"` as their aura target type, so `IsSelfOnly()` returns `false` for them. This eliminates the entire class of bug where debuff target resolution could be confused with self-buff targeting.

### LibSpellDB Updates
- **New AuraTarget: `"enemy"`** — `GetAuraTarget()` now returns `"enemy"` for debuff/DOT spells. Previously they defaulted to `"self"`, which made `IsSelfOnly()` return `true` — the root cause of the v1.0.154 debuff tracking regression.

## [1.0.157] - 2026-03-11

### Fixed
- **Debuff Tracking Regression** — Fixed all enemy debuff tracking (Curse of Weakness, Curse of Agony, Corruption, Siphon Life, etc.) not showing active aura timers on icons. This was a regression from v1.0.154's Arcane Blast self-debuff support, which incorrectly treated all debuffs as self-targeted. Self-debuffs like Arcane Blast stacks continue to work correctly. *(Thanks Deadlyy Dan for reporting)*

## [1.0.156] - 2026-03-10

### Changed
- **Spec Display Formatting** — "Current spec" labels throughout the UI now show "Holy Priest" instead of "PRIEST HOLY" — properly title-cased with spec name first.

## [1.0.155] - 2026-03-10

### Added
- **Ret Paladin: Seal Twist Zones** — The swing bar now shows color-coded zones for seal twisting: yellow (prep zone — cast Seal of Command before this ends), green (twist zone — cast Seal of Blood now). The entire bar turns red when a twist becomes impossible — either because a GCD will extend past the swing, or because you entered the twist zone without Seal of Command active. Requires the "Twist Window" option to be enabled (on by default).
- **Ret Paladin: Taller Default Bar** — Ret Paladin swing bar now defaults to 6px height (like Hunter) since the color zones are important to see. Holy and Prot Paladin remain at 2px. The height setting is now per-spec for specs that have a default override.

### Fixed
- **Swing Bar: Extra Attack Double-Reset** — Procs that generate bonus melee swings (Windfury Weapon, Sword Specialization, Hand of Justice) no longer incorrectly reset the swing timer. Previously only one extra attack was tracked; now all pending extra attacks are counted correctly.
- **Swing Bar: Cast-Time Swing Reset** — Casting a spell with a cast time now correctly resets the melee swing timer on cast start. This is a universal WoW mechanic that affects all melee classes.

## [1.0.154] - 2026-03-09

### Added
- **Arcane Blast Stack Tracking** — The Arcane Blast icon now shows your self-debuff stacks (1/2/3), countdown timer until they expire, and aura glow while active. Previously the icon didn't track the debuff because it was looking on the enemy target instead of on the caster. *(Boosterseat)*

### Fixed
- **Self-Debuff Aura Targeting** — Spells that apply debuffs to the caster (like Arcane Blast stacks) are now correctly tracked on the player instead of the enemy target. Previously, self-debuffs on `ROTATIONAL` spells were routed to the enemy target and never found.
- **Stack Event Buff/Debuff Detection** — Fixed stack change events (gaining/losing stacks) incorrectly assuming all self-applied auras are buffs. Self-debuffs now correctly scan `UnitDebuff` instead of `UnitBuff` when updating stack counts.

### LibSpellDB Updates
- Added `triggersAuras` mapping for Arcane Blast, linking the cast (30451) to the self-debuff (36032) with correct type, targeting, and 8s duration.

## [1.0.153] - 2026-03-09

### Fixed
- **Buff Reminders: Missing Party/Raid Tracking Option** — The "Track" dropdown (Player/Party/Raid) was hidden for many ally-targetable buffs including Priest Fortitude, Paladin Blessings, and others. These buffs now correctly show the tracking option so you can monitor your group for missing buffs.

### LibSpellDB Updates
- Fixed missing `auraTarget` on 18 ally-targetable buff spells across Priest, Paladin, Hunter, Shaman, and Warlock. Single-target buffs (Fortitude, Blessings, Water Walking, etc.) now correctly marked as ally-castable; raid-wide versions (Prayer of Fortitude, Greater Blessings, Aspect of the Pack/Wild) marked as party-wide.

## [1.0.152] - 2026-03-09

### Fixed
- **Totem Glow Ignoring Aura Tracking Toggle** — Active totems no longer show the pixel glow effect when "Aura Tracking > Enabled" is turned off in Ability Rows > Effects. The duration countdown and other visuals still display normally.

## [1.0.151] - 2026-03-09

### Fixed
- **Melee Weaving Bar Height** — Fixed the ranged (auto-shot) bar using the base 2px height instead of the per-class height when Melee Weaving is enabled. Hunters with Melee Weaving now correctly see their configured height on the ranged bar.

## [1.0.150] - 2026-03-09

### Changed
- **Hunter Swing Bar: Feign Death Accuracy** — Feign Death now correctly adds a +0.15s penalty to auto-shot speed that persists until the next successful shot. Previously the penalty was lost whenever haste changed (e.g., Trueshot Aura, Rapid Fire). Jumping out of Feign Death also properly resumes the timer with the penalty applied.
- **Hunter Swing Bar: Movement Prediction** — The bar now accurately predicts when auto-shot will fire after you stop moving. While moving, the bar pins at the cast phase boundary instead of oscillating. On stop, it computes the exact remaining time based on the client's retry cycle, eliminating the old worst-case ~0.5s overshoot.
- **Per-Class Swing Bar Height** — The swing bar height setting is now per-class on shared profiles. Hunters default to 6px while other classes keep 2px. Each class remembers its own height independently, so switching characters on the same profile won't override your preference.
- **Swing Bar Spark Scales with Height** — The spark (glowing fill-edge highlight) now resizes when the bar height changes, instead of staying at the original creation size.

### Fixed
- **Swing Bar Height Slider** — Changing the height in options now updates the bar in real-time instead of requiring the bar to disappear and reappear.

## [1.0.149] - 2026-03-09

### Added
- **Stance/Form Indicator** — Warriors, Druids, and Paladins now see a stance/form/aura indicator icon in the Auxiliary Row showing your currently active state. The icon updates instantly when you switch stances, forms, or auras. Drag it to any row via Spell Configuration.
- **Per-Row Masque Groups** — Each icon row now has its own Masque group ("Primary", "Secondary", etc.) instead of a single shared group. This lets you apply different Masque skins per row for visual distinction.

### Changed
- **Hunter Swing Bar: Improved Shot Zones** — Comprehensive accuracy improvements to the hunter auto-shot timing bar:
  - **Haste-invariant clip boundaries** — Zone boundaries now use the unhasted base weapon speed (extracted from item tooltips) instead of the hasted value, so zones stay accurate under all haste effects.
  - **Conservative red zone** — The red zone now starts at 0.52 seconds (the auto-shot animation time), which is slightly earlier than the previous Multi-Shot-only threshold. This ensures the green/yellow zones are always safe for both casting and movement.
  - **Automatic 2-zone/3-zone** — Below level 62 (before learning Steady Shot), the bar simplifies to a 2-zone model (green/red) since the yellow "Steady Shot clips" zone is irrelevant. Once Steady Shot is learned, the full 3-zone model appears automatically.
  - **Zones only while auto-shooting** — Shot zone overlays and colors are now hidden when auto-shot is not active (e.g., while purely meleeing), preventing orphaned red zone backgrounds on the melee bar.
- **Swing Bar: Parry Haste Fix** — Fixed a bug where parry haste could incorrectly *increase* the swing timer when it was already below the 20% floor. Affects all melee classes.
- **Hunter Swing Bar: Melee Weaving Fix** — Fixed both bars showing melee data when Melee Weaving was enabled while auto-shot was stopped.
- **Swing Bar Options Reorganized** — Zone-related options (Shot Zones toggle, zone colors, Twist Window, Zone Opacity) are now grouped together in Class Options. Zone colors and opacity are greyed out (disabled) instead of hidden when their feature is off. Bar Color is no longer incorrectly disabled when Shot Zones are enabled (it still applies to the melee bar).

### LibSpellDB Updates
- **Warrior: Stances** — Added Battle Stance, Defensive Stance, and Berserker Stance with `STANCE` tag (used by the new Stance Indicator).
- **Druid: Moonkin Form** — Removed incorrect `DPS` tag (retains `SHAPESHIFT`).

## [1.0.148] - 2026-03-09

### Added
- **Auxiliary Row** — New 4th icon row that sits above the Health Bar by default. Use it to separate spells you want visually distinct from your main rows. Drag spells into it via Spell Configuration (`/vh spells`). Has its own icon size setting (default 36px). Collapses automatically when empty — no change for players who don't use it. *(Splicer006)*
- **Totem Element Slots** — Shaman totem tracking has been upgraded from a standalone bar into 4 individual element slots (Fire, Earth, Water, Air) that live inside icon rows. You can now reorder totem slots and drag them between any row using Spell Configuration. By default they appear in the Auxiliary Row. Active totems show duration countdowns; expired totems appear dimmed. *(Splicer006)*
- **Per-Row Aspect Ratio** — Each icon row can now override the global aspect ratio. Set individual rows to Square, Compact, or any other shape independently — useful for keeping main rotation icons compact while totems or utility stay square. Find it under Ability Rows > [Row Name] > Size.
- **Scaled Pixel Glow** — Aura active glow (the animated pixel border) now scales proportionally with icon size. Previously the glow lines were the same length on all icons, looking oversized on smaller rows.

### Changed
- **Spell Configuration row order** — Rows now display in visual order (Auxiliary → Primary → Secondary → Utility → Available), matching the default HUD layout top-to-bottom.
- **Ability Rows tab order** — Row settings tabs follow the same visual order.
- **Migration popup** — Existing users see a one-time popup explaining the new Auxiliary Row, with a note about Shaman totem changes.

### Fixed
- **Stale migration data** — Cleaned up legacy `migrationsShown` tracking data left over from the old popup system.
- **Migration per-profile tracking** — Each character's profile now migrates independently, fixing an issue where the first character to log in after an update could prevent other characters from receiving data migrations.

## [1.0.147] - 2026-03-06

### Fixed
- **Pet Health Bar** — Fixed bar appearing when a pet is summoned even after disabling the feature in settings.

## [1.0.146] - 2026-03-06

### Added
- **Pet Health Bar** — New bar displaying your pet's health, positioned between the player health bar and resource bar. Auto-hides when you have no active pet and collapses the layout accordingly (like the swing bar). Includes heal prediction overlay, smooth animation, gradient, and configurable size/color/text. Default: thin 4px green bar with no text, enabled for all classes.

### Fixed
- **Temporary pet aura not clearing on death** — Shadowfiend (and similar temporary pet summons) now correctly clears its "buff active" glow when the pet dies early. Anniversary Edition doesn't fire CLEU death events for guardian pets, so the addon now uses the `UNIT_PET` game event as a reliable fallback.

### LibSpellDB Updates
- Added Spirit of Redemption (Priest Holy) proc entry.

## [1.0.145] - 2026-03-06

### Added
- **Settings Panel Entry** — VeevHUD now appears in the native addon options (ESC > Options > AddOns) with a button to open the full settings window.

### Fixed
- Fixed stale config text referencing old tab names in Aspect Ratio and Aura Tracker descriptions.

## [1.0.144] - 2026-03-06

### Added
- **Timed Effect Countdown** — Spells that create a timed effect with no trackable buff now show an aura-style countdown (glow, spiral, timer text) after casting. This covers Flamestrike (8s ground fire), Distract (10s distraction), Consecration (8s ground AoE), and Flare (20s stealth reveal). *(Shadowhawk)*

### LibSpellDB Updates
- New `TIMED_EFFECT` tag and `IsTimedEffect()` API for marking cast-and-forget spells with fixed durations but no unit aura. 4 spells tagged across 4 classes.

## [1.0.143] - 2026-03-04

### Added
- **Shared Debuff Tracking** — Maintenance debuffs like Thunder Clap, Sunder Armor, Faerie Fire, and Hunter's Mark now show as active on your HUD even when applied by another player of the same class. This covers 17 shared debuffs across all classes including utility curses (Curse of Elements, Curse of Shadow, etc.), Demoralizing Shout/Roar, Mangle, Expose Armor, and Stormstrike. Per-warlock damage curses (Curse of Agony, Curse of Doom) are correctly excluded. *(Artvil)*

### LibSpellDB Updates
- New `sharedAura` field and `IsSharedAura()` API for marking debuffs shared across all players. 17 spells tagged across 6 classes.

## [1.0.142] - 2026-03-04

### Improved
- **Buff Reminders: Min Stacks slider** — The slider max is now based on the actual charge count from spell data instead of a hardcoded 25. For grouped spells (e.g., Shaman Shields), the max reflects the highest charge count across the group (Earth Shield = 6).

### LibSpellDB Updates
- Added `charges` field to Earth Shield (6) and Shadowguard (3).

## [1.0.141] - 2026-03-04

### Improved
- **Spell data centralized to LibSpellDB** — Druid form detection, Innervate resource bar highlight, charge spell detection (Inner Fire, shields), and Buff Reminders preview icons now pull from LibSpellDB instead of hardcoded spell IDs.
- **Buff Reminders: no icon zoom** — Buff reminder icons now always display at full size without icon zoom cropping, visually distinguishing them from ability row icons.

### LibSpellDB Updates
- New `formType` field on shapeshift spells and `GetFormType()` / `HasCharges()` API methods.
- Added Aquatic Form (1066) to Druid data.
- Added `charges` field to Inner Fire (20), Lightning Shield (3), Water Shield (3).

## [1.0.140] - 2026-03-04

### Fixed
- **Paladin error spam on login** — Fixed a `bad argument #1 to 'ipairs'` error that fired every update tick for Paladin characters, caused by Divine Intervention's spell data. This error blocked normal icon updates and prevented drag-to-reorder from working. *(Thanks Kalle Fornien for reporting)*

### LibSpellDB Updates
- Fixed Divine Intervention `appliesBuff` field using wrong format (bare number instead of table).

## [1.0.139] - 2026-03-04

### Improved
- **Swing Bar data loaded from LibSpellDB** — Swing reset spells (Heroic Strike, Cleave, Slam, Raptor Strike, Maul) are now queried from LibSpellDB at init instead of being hardcoded. New swing reset abilities added to LibSpellDB will be picked up automatically.

### LibSpellDB Updates
- New `SWING_RESET` tag for melee abilities that reset the swing timer.

## [1.0.138] - 2026-03-04

### Improved
- **External Buffs tab built dynamically from LibSpellDB** — The Aura Tracker's External Buffs settings tab now automatically discovers all external buffs from LibSpellDB instead of using a hardcoded list. New external buffs added to LibSpellDB will appear in settings without requiring a VeevHUD update.
- **Consolidated migration system** — Replaced 5 separate migration files with a single versioned system. No user-facing changes, but future update notifications are now easier to add and maintain.

### LibSpellDB Updates
- **Divine Intervention** — Now trackable as an external buff in the Aura Tracker. Shows when a Paladin casts it on you with full duration tracking (3 min).

## [1.0.137] - 2026-03-04

### Added
- **Totem Bar: Masque support** — Shaman Totem Bar icons now support Masque skinning. Appears as "Totem Bar" in Masque's VeevHUD group settings, alongside Cooldowns, Aura Tracker, and Buff Reminders.

### Fixed
- **Icon zoom not applying to all modules** — Icon zoom now applies consistently to Buff Reminders and Totem Bar icons. Previously only Cooldown Icons and Aura Tracker respected the zoom setting.

## [1.0.136] - 2026-03-04

### Fixed
- **Masque skin settings not persisting** — Selecting a Masque skin (e.g., Zoomed, Blizzard Modern) for VeevHUD icons would appear to reset to default after `/reload` or relog. VeevHUD was overwriting Masque's icon texcoords with its own zoom settings on every load. Now uses WeakAuras-style compositing — reads Masque's applied texcoords first, then applies VeevHUD's icon zoom on top, so both the skin appearance and the zoom setting coexist correctly. Also properly handles the case where a Masque group is disabled in Masque's settings. *(Thanks Kalle Fornien for reporting)*

## [1.0.135] - 2026-03-04

### Fixed
- **Combo-point finisher buff timers showing wrong duration** — When refreshing Slice and Dice (or other combo-point finishers like Rupture, Expose Armor) while the buff was still active, VeevHUD would display the duration from the previous cast instead of the new one. For example, casting SnD at 4 combo points (18s) then recasting at 2 combo points would still show 18s remaining instead of 12s. *(Thanks amhoe for reporting)*

## [1.0.134] - 2026-03-04

### Improved
- **Library packaging** — Migrated all embedded libraries (Ace3, LibSharedMedia, LibCustomGlow, etc.) to `.pkgmeta` externals, following the standard WoW addon community convention used by WeakAuras, DBM, and BigWigs. No user-facing changes — libraries are fetched automatically during packaging.

### LibSpellDB Updates
- Fixed a "Duplicate File Load Detected" warning that appeared in BugSack when LibSpellDB was loaded as a standalone addon.

## [1.0.133] - 2026-03-03

### Fixed
- **Aura Tracker icons overlapping bars after rebuild** — When the Aura Tracker rebuilt its frames (e.g., after a weapon swap), icons could appear at the center of the HUD overlapping bars instead of at their correct position. A `/reload` was previously required to fix the layout.
- **Aura Tracker text not scaling with icon size** — Changing the Aura Tracker icon size in settings would resize icons but leave the duration and stack count text at the original size.

### Improved
- **Aura Tracker text proportions** — Duration and stack count text on Aura Tracker icons is now smaller and better proportioned, matching the text sizing used by cooldown icons. Previously the text was large enough to obscure the icon art at default sizes.

## [1.0.132] - 2026-03-03

### Fixed
- **Lockout timer text flickering during GCD** — Spells with target lockout debuffs (Power Word: Shield / Weakened Soul, Paladin Forbearance spells) would lose their cooldown text every time a GCD triggered from casting another spell. The text would rapidly appear and disappear, making the remaining lockout time unreadable.

## [1.0.131] - 2026-03-02

### Fixed
- **Trinket icon ignoring custom sort order** — Trinkets assigned to a row via Spell Configuration always appeared at the end of the row regardless of their configured position. They now respect the user-set order like regular spells.

## [1.0.130] - 2026-03-02

### Fixed
- **Power Word: Shield showing false lockout on allies** — After self-shielding, targeting a different ally would incorrectly display your own Weakened Soul timer on the PW:S icon, making it appear you couldn't shield that ally. The lockout check now only examines the unit the spell would actually land on.

## [1.0.129] - 2026-03-02

### Fixed
- **Power Word: Shield lockout timer disappearing** — The Weakened Soul cooldown text on the PW:S icon would vanish when targeting a different unit than the one you shielded. The lockout timer now correctly falls back to checking yourself, matching WoW's auto-self-cast behavior for friendly spells.
- **Reactive abilities missing from Spell Configuration** — Abilities with a reactive window (e.g., Victory Rush) were filtered out of the Available pool in the Spells config, making them impossible to enable. They now appear correctly.

### Improved
- **Icon frame state cleanup** — Resource display state (cost fill, bar, prediction) is now cleared when icons are reassigned, preventing potential stale visual artifacts after spec changes or trinket swaps.

## [1.0.128] - 2026-03-02

### Fixed
- **Blood Fury (and other abilities) showing wrong state after trinket changes** — When a trinket swap or spell config change caused icon positions to shift, abilities could inherit stale trinket data and display the wrong cooldown or ICD timer. Added centralized frame state cleanup to prevent this class of bug. *(Thanks Seifer for reporting)*
- **Dynamic sort snap-back on cast** — When casting an ability that triggered dynamic sort reordering, the icon would briefly slide to its new position then snap back. Cast feedback and sort animations now compose correctly.
- **Queued ability highlight not appearing** — The queued spell highlight (e.g., queueing Renew while casting) was not showing on any abilities due to an internal bug.
- **Trinket ICD display cutoff** — Very short internal cooldowns on proc trinkets could be hidden instead of showing a countdown.

### Changed
- Improved addon performance — Icons skip update processing when idle with no active cooldowns or buffs. Layout system skips redundant repositioning when element heights haven't changed.
- Improved addon stability — An error in one icon no longer prevents all other icons from updating.

## [1.0.127] - 2026-03-01

### Added
- **Trinket Tracking** — Equipped trinkets with on-use or proc effects automatically appear as icons in your ability rows. On-use trinkets show the active buff with duration, then a cooldown spiral. Proc trinkets glow when active with duration text, then show the internal cooldown until they can proc again. Includes stack count display for stacking effects (e.g., Pendant of the Violet Eye), pop animation on activation and proc triggers, and ready glow when coming off cooldown. Trinkets default to the Secondary row and can be moved or disabled in the Spells config. *(Independent-Bother17)*

### LibSpellDB Updates
- New trinket database with 35 TBC proc trinkets (Karazhan through Sunwell).
- Trinket query API: `GetTrinketInfo(itemID)` returns proc buff ID, ICD, and other metadata.
- New `TRINKET` category tag for trinket row assignment.

## [1.0.126] - 2026-03-01

### Fixed
- **Energy ticker spark crash** — Fixed an error ("attempt to perform arithmetic on local 'tickerHeight'") when creating the energy ticker bar spark, caused by a reference to an undefined variable. *(Thanks Pekar for reporting)*

## [1.0.125] - 2026-03-01

### Fixed
- **Missing spells due to Anniversary Edition spell IDs** — Some spells (confirmed: Rogue's Kick) were invisible because Anniversary Edition uses different internal spell IDs than TBC Classic for certain ranks. Added a name-based detection fallback that automatically finds spells in the player's spellbook even when the database IDs don't match the client. This fix applies broadly to all classes — any spell affected by ID differences will now be detected correctly. *(Thanks amhoe for reporting)*

### LibSpellDB Updates
- Rogue Kick: Added Anniversary Edition spell ID (38768) for rank 5.

## [1.0.124] - 2026-03-01

### Fixed
- **Resource bar error with smooth bars enabled** — Fixed a crash ("attempt to perform arithmetic on local 'currentValue'") that could occur when the smooth bar animation tried to update before the resource bar received its first value. *(Thanks Pekar for reporting)*

## [1.0.123] - 2026-02-28

### Fixed
- **Combo point border inconsistency** — The first combo point bar had a full outline (all 4 edges), but bars 2–5 were missing their top border line. All combo point bars now display a consistent border. *(Thanks Shadowhawk for reporting)*

## [1.0.122] - 2026-02-28

### Fixed
- **Power Word: Shield not detecting removal on allies** — When PWS was consumed by damage on another player (e.g., the tank), the icon continued showing "buff active" for the full 30-second duration instead of clearing immediately. Caused by a silent refresh detection feature creating duplicate tracking entries under mismatched spell IDs, which SPELL_AURA_REMOVED could never clear.
- **Prayer of Mending duration not tracking correctly** — PoM's buff spell ID (41635) differs from its cast spell ID (33076), causing all aura events to be silently dropped. The icon would show stale remaining time instead of resetting to 30 seconds on refresh. PoM also now follows target context (shows active state when targeting the ally who has it) rather than displaying globally regardless of target.

### LibSpellDB Updates
- Prayer of Mending: Added `appliesBuff = {41635}` to map the buff spell ID, removed `singleTarget` for target-context display.
- Lightwell: Added missing `C.HEAL` tag.

## [1.0.121] - 2026-02-28

### Fixed
- **Mangle debuff lost on Bear→Cat form switch** — When Bear Mangle applied a debuff and the player switched to Cat form, Cat Mangle could not track or refresh the existing debuff because the two forms use different spell IDs for the same effect. The addon now recognizes that both forms' Mangle applies the same debuff and tracks it correctly across form switches. *(Thanks Shadowhawk for reporting)*

### LibSpellDB Updates
- Added `sharedAuraSpells` linking Mangle (Cat) and Mangle (Bear) rank IDs, allowing consumers to detect the shared debuff regardless of which form applied it.

## [1.0.120] - 2026-02-28

### Fixed
- **Debuff timers not showing on neutral (yellow) mobs** — Debuff timers (Mangle, Faerie Fire, Moonfire, etc.) were not displayed when fighting neutral mobs because they were not recognized as valid debuff targets. *(Thanks Soveliss, Shadowhawk for reporting)*
- **Debuff timer not refreshing on reapplication** — When reapplying a debuff (e.g., Cat Mangle) to the same target, the timer would not reset. WoW Anniversary Edition does not always fire aura refresh events in the combat log, so the addon now detects refreshes by re-scanning the target after each cast. *(Thanks Soveliss, Shadowhawk for reporting)*
- **Stale debuff data after Druid form switch** — Switching between Bear and Cat form could leave orphaned debuff tracking data from the previous form. Debuff tracking is now cleaned up when form-specific spells change.

### LibSpellDB Updates
- Added missing 12-second debuff duration to Mangle (Cat) and Mangle (Bear) spell data.

## [1.0.118] - 2026-02-28

### Fixed
- **Procs appearing in Spell Configuration** — Proc spells (Inspiration, Clearcasting, Flurry, etc.) were incorrectly showing up in the Spell Configuration "Available" list. Procs belong exclusively in the Aura Tracker and are now filtered from the spell list across all classes.

## [1.0.117] - 2026-02-27

### Changed
- **Custom Auras: Recently Seen Buffs** — Increased display limit from 10 to 20 entries.

## [1.0.116] - 2026-02-27

### Fixed
- **Hunter: Buff reminder with Aspect of the Wild** — Aspect of the Wild was missing from the spell database, causing a false "missing aspect" buff reminder when it was active. *(Thanks Seifer for reporting)*

### LibSpellDB Updates
- Added Aspect of the Wild (all 3 ranks) to Hunter spell data and the `HUNTER_ASPECTS` BuffGroup.

## [1.0.115] - 2026-02-27

### Fixed
- Reduced unnecessary memory allocations in the buff tracking cache.

## [1.0.114] - 2026-02-27

### Changed
- **Aura Tracker: Activation Pop** — Default scale reduced from 125% to 120% to match the proportional pixel growth of ability row cast pop.
- **Settings: Tab Order** — Layout tab now appears above Support tab.

## [1.0.113] - 2026-02-27

### Added
- **Aura Tracker: Sort Order** — Choose how active aura icons are arranged: Activation Order (newest on right), Fixed (consistent registration order), or Least Remaining (closest to expiring on left). Configurable in Aura Tracker > Animation.
- **Aura Tracker: Activation Pop** — Configurable scale punch when an aura activates or refreshes. Adjust the intensity or set to 100% to disable. Found in Aura Tracker > Animation.
- **Text Color** — The color used for cooldown countdowns, duration timers, and stack counts is now configurable via a color picker in General > Appearance. Applies across all HUD elements.
- **Custom Auras: Recently Seen Buffs** — The Custom Auras tab now shows a list of buffs you've recently received, with one-click "Add" buttons. Automatically excludes buffs already tracked by class procs or external buffs. Updates in real-time as new buffs appear.
- **Primary/Secondary Row: Max Icons** — Default maximum icons increased from 20 to 24, matching the Utility row.

### Changed
- **Aura Tracker: Settings Reorganized** — The Effects section has been split into Glow (edge glow, backdrop intensity/size) and Animation (show duration, slide animation, activation pop, sort order) for a cleaner layout.

### Fixed
- **Icon Zoom not affecting Aura Tracker/Totem Bar** — The global Icon Zoom setting now correctly applies to Aura Tracker and Totem Bar icons in addition to ability row icons.

## [1.0.112] - 2026-02-27

### Fixed
- **Aura Tracker: Icons not repositioning after proc refresh** — When a proc dropped and re-triggered (e.g., Flurry), icons could overlap and get stuck at incorrect positions. The slide animator now correctly repositions frames after a punch animation finishes.
- **Aura Tracker: Stutter when new proc appears** — When a proc re-appeared among existing icons, the other icons had a visible delay before sliding to make room. New icon appearances now snap all icons to their correct positions instantly, with the punch animation providing the visual flair.

## [1.0.111] - 2026-02-27

### Added
- **Aura Tracker** — The Proc Tracker has been upgraded to the Aura Tracker with three data sources: class procs, external buffs, and custom auras. All existing proc settings are automatically migrated.
- **External Buff Tracking** — Tracks important buffs from other players: Bloodlust/Heroism, Power Infusion, Innervate, Pain Suppression, Blessing of Protection/Sacrifice/Freedom, Fear Ward, Earth Shield, Misdirection, and Drums. Each can be individually toggled in the new External Buffs settings tab. *(Soveliss)*
- **Custom Auras** — Add your own auras by spell ID or name. Supports cross-class spells (e.g., a Priest tracking Rejuvenation), NPC buffs, and encounter-specific effects. Icons appear when the buff is active on you.
- **Aura Source Filter** — Per-aura "Own Only / Not Own / Any" filter controls whose buffs you track. External buffs default to "Not Own" (so a Priest won't see their own Pain Suppression as an external), custom auras default to "Any". Configurable per aura in settings.
- **Stormstrike: Cooldown Priority** — Stormstrike now shows cooldown state first instead of debuff uptime, matching its use as a rotational ability. *(bewz)*

### Fixed
- **Other players' buffs showing on ability icons** — Another player casting the same buff on you (e.g., another Priest's Renew) would incorrectly show your ability icon as active. Ability icons now only track your own casts.
- **Aura Tracker pop animation barely visible** — The scale punch animation was too fast (200ms) and was being killed every 50ms by the icon repositioning logic. Animation timing increased to 320ms, and the slide animator now properly defers to active punch animations instead of fighting them.
- **Aura Tracker icons overlapping and getting stuck** — The slide animator and punch animator were both calling SetPoint on the same frame, causing position conflicts. They now coordinate: the slide animator tracks position internally while a punch is active and applies it when the punch finishes.

### LibSpellDB Updates
- New `IMPORTANT_EXTERNAL` and `MINOR_EXTERNAL` tags for two-tier external buff classification.
- New drums data file (`Data/Externals.lua`) with 6 leatherworking drum variants.
- 30+ new proc definitions: Warrior (Second Wind, Blood Frenzy), Rogue (Remorseless, Find Weakness, Mace Stun, Blade Twisting), Mage (Ignite, Winter's Chill, Blazing Speed, Fire Vulnerability), Warlock (Shadow Vulnerability, Shadow Embrace, Nether Protection), Priest (Shadow Weaving, Blessed Recovery, Focused Casting, Blackout), Shaman (Elemental Devastation, Focused Casting), Druid (Natural Perfection, Starfire Stun), Paladin (Light's Grace, Redoubt, Reckoning), Hunter (Expose Weakness, Master Tactician, Rapid Killing, and more).
- Removed Arcane Power, Icy Veins, Presence of Mind, Blade Flurry, and Adrenaline Rush from proc data (active abilities, not procs).
- Stormstrike: `cooldownPriority = true`.

## [1.0.110] - 2026-02-25

### Fixed
- **Fury Warrior: Swing Bar Sync Colors Inverted** — Fury Warriors want their weapons *desynced* for the Heroic Strike queue mechanic (queuing HS removes the off-hand's dual-wield miss penalty, but only when the off-hand swings separately from the main-hand). Bars now correctly turn green when desynced and red when synced — the opposite of Enhancement Shamans, who want sync for Flurry charge efficiency.
- **Fury Warrior: Sync Colors Now Always Visible** — Sync colors previously required a Windfury Totem buff to appear. The HS queue mechanic applies regardless of Windfury, so sync colors now show whenever dual-wielding as Fury.

## [1.0.109] - 2026-02-24

### Added
- **Buff Reminders: Slide Animation** — When buff reminder icons appear or disappear, remaining icons now smoothly slide to re-center instead of snapping instantly. This matches the Proc Tracker's existing slide behavior. Can be toggled off in Buff Reminders > Behavior > Slide Animation.

## [1.0.108] - 2026-02-24

### Fixed
- **Off-tree talent toggle stuck** — Trained talents from other specs (e.g., Fel Domination for Affliction warlocks) could not be unchecked in Spell Configuration. Toggling them off would immediately re-enable them on the next UI refresh. *(Thanks Deadlyy Dan for reporting)*
- **Exclusive group icon on wrong HUD row** — Exclusive spell groups (e.g., Curses) could appear on the wrong HUD row when any member had a saved row override. For example, curses configured on the Primary row might display on the Utility row instead.
- **Drag-to-Available not working for spell groups** — Dragging an exclusive spell group (e.g., Curses) to the Available section would disable the group but leave its icon stuck on the previous row instead of removing it.
- **Group drag only moving representative** — Dragging an exclusive spell group between rows only applied the row change to the representative spell. Other group members stayed on their original row, causing inconsistent behavior when the representative changed.

### LibSpellDB Updates
- Added Warlock Soulshatter (threat reduction, 3min CD) to the spell database. *(Deadlyy Dan)*

## [1.0.107] - 2026-02-24

### Added
- **Exclusive Spell Group Consolidation** — Mutually exclusive spells that share a single ability tracker (e.g., warlock curses, paladin seals) are now consolidated into one icon on the HUD. When you cast a different spell from the group, the icon swaps automatically. When you switch targets, the icon updates to show whichever group member is active on the current target.
- **Spell Config: Group Entries** — Exclusive spell groups appear as a single entry in Spell Configuration instead of individual spells. Hovering shows all member spells; toggling or dragging applies to the entire group. For example, 8 warlock curses now show as one "Curses" entry.
- **AuraTarget-Aware Grouping** — Exclusive group consolidation respects spell targeting. Spells that target different units (e.g., Earth Shield on ally vs Water/Lightning Shield on self) remain as separate entries since both can be active simultaneously.

### LibSpellDB Updates
- New exclusive BuffGroups: `WARLOCK_CURSES` (8 curses) and `PALADIN_SEALS` (8 seals).
- Fixed missing `PALADIN_SEALS` group definition — seal spells referenced the group but it was never defined.

## [1.0.106] - 2026-02-24

### Fixed
- **Warlock: Siphon Life not tracking** — Siphon Life's debuff duration was not displaying on the icon because the spell database was missing Rank 6 (the level 70 rank). When a level 70 warlock casts Siphon Life, the combat log fires with the Rank 6 spell ID which the aura tracker couldn't recognize. *(Thanks Seifer for reporting)*
- **Warlock: Curse of the Elements not tracking** — Curse of the Elements was using the wrong spell ID for Rank 4 (it had Curse of Shadow's ID instead), so max-rank Curse of the Elements was never matched by the aura tracker. *(Thanks Seifer for reporting)*

### LibSpellDB Updates
- Fixed missing TBC ranks for 8 Warlock spells: Siphon Life, Searing Pain, Soul Fire, Shadowburn, Drain Mana, Curse of Weakness, Devour Magic, and Curse of Shadow.
- Fixed spell ID swap between Fear, Curse of the Elements, and Curse of Shadow.
- Fixed missing Priest Greater Heal Rank 7.

## [1.0.105] - 2026-02-22

### Added
- **Off-Tree Talents Auto-Display** — Trained off-tree talents (e.g., Death Wish or Sweeping Strikes for Arms warriors) now automatically appear on the HUD. Any talent you've invested points in will show regardless of which spec LibSpellDB detects, and disappear if you respec away.
- **Overpower: Dodge-Reactive Glow** — When your target dodges an attack, Overpower's icon glows even if you're not in Battle Stance — signaling "swap stance and use this!" The glow is target-specific: if you Whirlwind and an off-target dodges, tabbing to them within the 5-second window shows the glow. Requires Overpower to be off cooldown and affordable.
- **Proc Tracker: Mace Stun Effect** — Mace Specialization talent stun proc (3s) now tracked on the proc tracker with the talent icon. Enabled by default for warriors with the talent.
- **Proc Tracker: Deep Thunder / Stormherald Stun** — Weapon stun proc (4s) tracked with the equipped weapon's icon. Only appears when one of these weapons is equipped; swapping weapons updates the tracker automatically.
- **Proc Tracker: Improved Hamstring** — Improved Hamstring talent root proc (5s) now tracked on the proc tracker. Enabled by default for warriors with the talent.
- **Spiral Darkness Sliders** — New settings to control how dark the spiral overlay appears on icons. "Cooldown Spiral Darkness" (Effects tab) adjusts cooldown spirals; "Aura Spiral Darkness" (Aura Tracking section) adjusts buff/aura duration spirals. Both default to 100%. Set to 0% to hide spirals entirely while keeping countdown text.

### LibSpellDB Updates
- New APIs: `GetSpellIcon()`, `GetDodgeReactive()`, `GetRequiredItemIDs()`.
- New spell data fields: `dodgeReactive`, `requiredItemIDs`, `icon` override.
- `GetProcs()` now includes SHARED (cross-class) procs like weapon stun effects.
- Added Overpower dodge-reactive window, Mace Stun Effect, Improved Hamstring, and Deep Thunder/Stormherald stun proc data.
- Warrior off-tree talents (Piercing Howl, Death Wish, Sweeping Strikes) now include Arms in their specs arrays.

## [1.0.104] - 2026-02-20

### Added
- **Proc Tracker: Spells Tab** — Per-proc enable/disable toggles have moved from the standalone Spell Configuration window into a new Spells sub-tab inside the Proc Tracker tab. Settings are per-spec with a spec indicator, matching the Buff Reminders pattern.
- **Proc Tracker: Low-Priority Defaults** — Minor passive procs (Warrior's Deep Wounds and Blood Craze) are now disabled by default. You can still enable them in the Proc Tracker Spells tab.

### Changed
- **Swing Bar: Windfury Sync Colors** — Warriors now only see dual-wield sync coloring (red/green) when actually buffed by Windfury Totem. Previously sync colors always showed for dual-wielding warriors.
- **Options: Spell Config Tab** — The "Spells" tab (launcher for the drag-and-drop spell configuration window) has been renamed to "Spell Config" and moved next to "Ability Rows" for easier discoverability.

### LibSpellDB Updates
- New `lowPriority` field on proc data, marking minor passive procs that consumers can default-disable.

## [1.0.103] - 2026-02-20

### Added
- **Healthstone Tracking** — Create Healthstone now appears in the Utility row. Shows a subtle glow when a Healthstone is in your bags (ready to use), and a cooldown spiral when consumed (2-minute cooldown). Works without the item on your action bar. *(Deadlyy Dan)*
- **Item Consumption Detection** — Spells that create usable items (Healthstone, Soulstone) now automatically detect when the item is consumed and start the cooldown countdown, even if the item isn't on your action bar.

### Fixed
- **Resource prediction overlapping item indicators** — When a created item is in your bags (showing the "ready" glow), the predicted mana cost spiral no longer overlaps. The item-in-bags indicator takes priority.

### LibSpellDB Updates
- Added Create Healthstone with all 18 item IDs (standard + improved talent rank 1 and 2).
- New `itemCooldown` field for consumption-based cooldown detection (Healthstone 120s, Soulstone 1800s).

## [1.0.102] - 2026-02-19

### Added
- **Buff Reminders: Per-Spec Settings** — Buff reminder overrides (enabled/disabled, thresholds, combat state, etc.) are now stored per spec. Disabling Battle Shout for Protection no longer affects Fury. Existing overrides are silently migrated to your current spec on first load.
- **Buff Reminders: Spec-Aware Defaults** — Spells that aren't relevant to your current spec are now disabled by default (e.g., Righteous Fury for Holy/Ret paladins). Defaults are computed using LibSpellDB's spec and race relevance checks.
- **Buff Reminders: Show Only Known Spells** — New toggle in the Spells tab filters the list to only spells you currently know (enabled by default). Uncheck to see all class buff spells, including unlearned ones. Race-restricted spells from other races are always hidden.
- **Buff Reminders: Spec Indicator** — The Spells tab now shows your current spec in grey text at the top, matching the Spell Configuration window.
- **Warlock: Soul Link Buff Reminder** — SL/SL warlocks now get a buff reminder for Soul Link. Requires an alive pet (reminder suppressed when pet is dead or dismissed).
- **Warlock: Demonic Sacrifice Smart Defaults** — If you know Soul Link or Summon Felguard, the Demonic Sacrifice buff reminder defaults to disabled (since you keep your pet alive). DS/Ruin warlocks still get the reminder.
- **Soulstone: Action Bar Cooldown Fallback** — When the Soulstone item is consumed, VeevHUD now reads the cooldown from the action bar (the same mechanism Blizzard's native bars use). This works even after `/reload` and without the item in bags. For players without the item on their action bar, the cooldown is derived from the buff timing.

### Changed
- **Options: Flattened Tab Layout** — Proc Tracker, Totem Bar, and Buff Reminders are now top-level tabs instead of nested under a "Modules" category, making them easier to discover.

### Fixed
- **Scale Punch Animation Drift** — Fixed icon "jump to the left then back" during scale punch animations (most noticeable on pet summon icons). The animation now saves base anchor offsets at punch start and restores them correctly, preventing positional drift when layout repositions frames during the animation.
- **Pet Summon Predicted Cost Stuck** — Pet summon spells (Summon Imp, etc.) no longer permanently show predicted resource cost on the resource bar. `IsCurrentSpell()` returns true permanently for the active pet's summon spell; these are now correctly excluded from cost prediction.
- **Warlock: Nightfall/Shadow Trance Duplicate** — Fixed both Nightfall (the passive talent) and Shadow Trance (the proc buff) appearing in the proc tracker. Only Shadow Trance now appears.

### LibSpellDB Updates
- Added `REQUIRES_PET` tag, `IsRaceRelevant()` API, `excludeIfKnown` BuffGroup field.
- Added Soul Link, Summon Felguard, and Life Tap to warlock spell data.
- Removed Nightfall passive talent from database (Shadow Trance in Procs.lua is the correct proc entry).
- Removed spec restriction from Demonic Sacrifice buffs; removed `SITUATIONAL` from Righteous Fury.

## [1.0.101] - 2026-02-19

### Fixed

- **Soulstone not appearing in HUD or Spell Config** — Soulstone tracking (added in v1.0.96) was completely non-functional because the spell database used buff IDs ("Soulstone Resurrection") instead of the actual spellbook IDs ("Create Soulstone"). The spell now appears in the Utility row, shows the Soulstone Resurrection buff duration when active on an ally (with glow and countdown), and falls back to the item cooldown when the buff is not active. *(Thanks ChaosEternal, Deadlyy Dan for reporting)*
- **Aura tracking for spells with `appliesBuff`** — AuraTracker now recognizes buff IDs from the `appliesBuff` field, enabling CLEU-based tracking for spells where the applied buff differs from the cast spell (e.g., Soulstone). The direct buff scan fallback (`GetRelevantBuff`) also checks `appliesBuff` IDs.

### Changed

- **Enhanced `/vh check` diagnostics** — The `/vh check <id>` command now shows per-rank `IsSpellKnown` results, item cooldown states (bag count, remaining CD), and applied buff IDs. This makes it easier for users to share diagnostic output when reporting tracking issues.

### LibSpellDB Updates

- Fixed Soulstone spell ID mismatch — canonical ID changed from 20707 (buff) to 693 (cast spell), ranks updated to actual spellbook IDs, added `appliesBuff` for buff tracking.

## [1.0.100] - 2026-02-18

### Fixed

- **Swing Bar width slider not applying** — Changing the Swing Bar width in options had no visible effect until a `/reload`. The individual bars inside the container were not being resized, only the container itself. Width changes now apply instantly like all other bars. *(Thanks muu for reporting)*

### Changed

- **Swing Bar default height reduced** — The default single-weapon bar height is now 2px (down from 4px), matching the dual-wield and wand bar heights for a more consistent look. Only affects new profiles.
- **Bar width slider ranges unified** — All bar width sliders (resource, health, combo points, swing) now share the same range of 50–600px. Previously the swing bar maxed at 400 and the other bars had a minimum of 100.

## [1.0.99] - 2026-02-18

### Fixed

- **Buff Reminders: Exclusive group priority ignored** — Fixed exclusive buff groups (e.g., Warrior Shouts) ignoring the user's priority setting, always showing the first spell in the group instead of the preferred one.
- **Buff Reminders: Other players' buffs suppressing reminder** — For exclusive buff groups, another player providing one of the group's buffs (e.g., another warrior's Battle Shout) no longer suppresses your reminder. The addon now checks only for buffs you cast yourself. When your priority spell is already covered by someone else, the icon suggests the uncovered spell from the group instead.
- **Ally-targeted buff aura classification** — Fixed a bug where ally-targeted buffs (like heals cast on party members) were not properly classified for aura scanning, potentially causing them to be looked up as debuffs instead of buffs.

## [1.0.98] - 2026-02-17

### Fixed

- **Druid form detection with missing forms** — Cat Form spells, combo points, and the druid mana bar were not showing for druids who hadn't trained all shapeshift forms (e.g., skipping Aquatic Form). The addon was using hardcoded stance bar positions to identify forms, but the bar shifts when forms are unlearned — so Cat Form at position 2 was misidentified as Aquatic Form and ignored. Form detection now uses spell IDs from `GetShapeshiftFormInfo()`, which works regardless of which forms are trained or their bar position. *(Thanks Arkoudokinigos for reporting)*

## [1.0.97] - 2026-02-17

### Added

- **Detailed Time Threshold** — New option (Icons > Cooldown Text) to control when cooldown text switches from precise `m:ss` format to compact `Xm` format. Configurable from 1–10 minutes; default is 2 minutes.

### Fixed

- **Innervate highlight on feral druid mana bar** — The Innervate highlight color now correctly applies to the secondary druid mana bar (shown in Cat/Bear Form) instead of incorrectly coloring the rage or energy bar.

## [1.0.96] - 2026-02-15

### Added

- **Soulstone Tracking** — Soulstone now shows the active buff duration when applied to an ally (with glow and countdown), and falls back to showing the item cooldown when the buff is not active. Previously the icon could not track either because the cooldown lives on the created item, not the spell itself.

### Fixed

- **Ally buff checking for non-rotational spells** — Spells with `auraTarget = "ally"` (like Soulstone, external defensives) now correctly check the targeted ally for their buff status. Previously, only rotational spells could check allies, causing non-rotational ally-targeted buffs to only scan the player.

### LibSpellDB Updates

- New `GetItemCooldown()` API for spells that track cooldowns via created items.
- Soulstone Resurrection: corrected spell data — creation spell has no cooldown (item does), added ally targeting, buff duration, and item cooldown IDs.

## [1.0.95] - 2026-02-15

### LibSpellDB Updates

- **Siphon Life / Devouring Plague debuff tracking fix** — These DoTs were not showing their active debuff duration on the icon despite being applied to the target. The spells were incorrectly tagged as ally-targeted heals (due to their self-healing side-effect), causing the aura tracker to look for a buff on allies instead of a debuff on the enemy.

## [1.0.94] - 2026-02-15

### Added

- **Earth Shield on Primary Row** — Earth Shield now appears on the Primary row for Restoration Shamans by default. Previously it was only tracked by Buff Reminders due to its long duration, but as a core rotation maintenance spell with consumable charges, it belongs on the HUD alongside other rotational abilities. Still eligible for Buff Reminders as well.

### Fixed

- **Charge-based aura stack display** — Spells with charges (Earth Shield, Water Shield, Lightning Shield) now correctly show their initial charge count on the icon. Previously, the first charge count could be missed because the WoW API doesn't report charges at the exact moment the buff is applied.

### LibSpellDB Updates

- Tagged 8 non-combat utility spells as `OUT_OF_COMBAT` (Travel Form, Ghost Wolf, Astral Recall, Dismiss Pet, Beast Lore, Ritual of Doom, Ritual of Summoning, Eye of Kilrogg) — these no longer appear on the HUD.

## [1.0.93] - 2026-02-15

### Changed

- **Buff Reminders: Default opacity increased** — New installs now default to 30% opacity (up from 15%) for better visibility. Existing users are unaffected — this only changes the default for new profiles.

## [1.0.92] - 2026-02-15

### Fixed

- **Mana cost prediction accuracy** — Predictions could overshoot by ~2 seconds when the mana needed was close to a tick boundary, and the prediction spiral would visibly have time remaining when the spell was already affordable. Removed overly conservative safety margins that were adding an extra tick to the calculation. Predictions are now accurate to within ~0.15 seconds.
- **Mana cost prediction resetting mid-countdown** — The prediction spiral restarted every time a mana tick arrived (~2 seconds), causing the countdown to visibly jump backward repeatedly. Predictions now only restart when mana decreases (player casts a spell). Incoming ticks are already accounted for in the original prediction.
- **External mana gains corrupting tick tracking** — Insightful Earthstorm Diamond procs, mana potions, Dark Runes, and other SPELL_ENERGIZE-based mana gains were being misidentified as natural mana ticks, corrupting the tick timer and triggering false tick detections. These are now filtered out via combat log tracking.

## [1.0.91] - 2026-02-15

### Fixed

- **Profile switch not refreshing icons** — When both profiles had the resource bar disabled and a `/reload` had occurred, switching profiles would fail to update spell icons (enable/disable, aspect ratio, row assignments). The resource bar's energy ticker tried to create UI elements on a nil frame, silently aborting the refresh. Also fixed the profile safety wrapper firing the refresh loop twice, and made module refresh order deterministic to prevent race conditions. *(Thanks Shadowhawk for reporting)*

## [1.0.90] - 2026-02-15

### Added

- **Resource Bar: Innervate Highlight** — The mana bar changes color when the Innervate buff is active, giving you immediate visual feedback that your mana regeneration is boosted. Defaults to a cyan/teal color. Configurable (toggle + color picker) under Bars > Resource Bar > Innervate Highlight.

## [1.0.89] - 2026-02-15

### Changed

- **Buff Reminders: Smaller defaults** — Default icon size reduced from 128 to 64, spacing increased from 8 to 12, and opacity lowered from 25% to 15% for a subtler out-of-box experience.
- **Buff Reminders: Expanded slider ranges** — Icon Spacing now allows negative values (down to -10) for overlapping icons, and goes up to 64. Icon Opacity minimum lowered from 10% to 5%.

## [1.0.88] - 2026-02-14

### Added

- **Buff Reminders: Demonic Sacrifice** — Demonology Warlocks with the Demonic Sacrifice talent now get a Buff Reminder when no sacrifice buff is active (Burning Wish, Fel Stamina, Touch of Shadow, or Fel Energy). Defaults to out-of-combat reminders since you can't resummon and sacrifice mid-fight. Also supports buff-active detection on the HUD if you manually enable Demonic Sacrifice in Spell Configuration. *(Wildfire)*

### LibSpellDB Updates

- Added Warlock Demonic Sacrifice casting spell (18788) with `triggersAuras` for all 5 buff outcomes
- Added 5 Demonic Sacrifice buff entries (Burning Wish, Fel Stamina, Touch of Shadow, Fel Energy) as `LONG_BUFF` with exclusive BuffGroup
- New BuffGroup field `talentGate` — allows buff groups where the spells are passive auras (not castable) to gate on a talent spell instead

## [1.0.87] - 2026-02-13

### Added

- **Buff Reminders: Per-Hand Weapon Enchant Toggles** — Rogues can now independently disable Main Hand or Off Hand poison reminders. Useful when grouped with a Shaman providing Windfury Totem — disable the MH reminder to avoid false alerts. Toggles appear under the Rogue Poisons section in Modules > Buff Reminders > Spells.

### Fixed

- **Disabling a row no longer spills spells into other rows** — In v1.0.85, disabling a row (e.g., Secondary) caused its spells to cascade into the nearest enabled row. This produced confusing behavior where disabling rows made MORE icons appear. Disabling a row now simply hides its spells. *(Thanks Lachtan for reporting)*
- **Spell Config shows correct row when a row is disabled** — Previously, disabling a row caused the Spell Config panel to show those spells under the wrong row. Spells now always appear under their natural row in the config, regardless of whether the row is enabled on the HUD.

### Changed

- Removed the Priority dropdown from weapon enchant spell config (Rogue Poisons, Shaman Weapon Imbues) since weapon enchant reminders show your weapon icon, not the spell icon.

## [1.0.86] - 2026-02-13

### Fixed

- **Totem Bar: totems killed by mobs now disappear immediately** — When a totem was killed by a mob, the Totem Bar continued showing it as active with a ticking timer. The bar now detects totem destruction via the game's native totem state events and clears the slot instantly. *(Thanks bewz for reporting)*
- **Profile Reset now refreshes the HUD** — Using Reset Profile in the Profiles tab correctly reset settings values, but the HUD visuals didn't update until a `/reload`. The HUD now fully refreshes on profile reset, copy, and switch.
- **Expanded position offset range** — The horizontal and vertical offset sliders (General and Buff Reminders) now scale to your full screen dimensions, so you can position the HUD or buff reminder icons anywhere on screen regardless of resolution or UI scale.

## [1.0.85] - 2026-02-13

### Changed

- **Config Panel Overhaul** — The settings panel has been reorganized for clarity:
  - **Ability Rows** tab (formerly "Icons") — Now includes per-row settings (Primary, Secondary, Utility) that were previously in a separate "Rows" tab. Sub-tabs reorganized into Appearance, Opacity, Cooldowns, Resources, Effects, and Other.
  - **Modules** tab (new) — Groups Proc Tracker, Totem Bar, and Buff Reminders in one place.
  - **Bars** tab — Health Bar promoted to first position. Energy Ticker, Mana Ticker, and Druid Mana Bar are now inline sections within Resource Bar instead of separate sub-tabs.
  - **Layout** tab — Element ordering and gap controls (previously embedded in General).
  - Icon Zoom moved to General > Appearance since it affects all icon-based modules.
- **Setting names simplified** — Alpha → Opacity, Cooldown Bling → Cooldown Sparkle, Cast Feedback → Cast Pop, Re-trigger → Repeat Glow, Anticipation → Early Trigger, Sort Animation → Smooth Sorting, Desaturate Without Resources → Grey Out When Not Usable. Tooltips rewritten in plain language throughout.
- **Row dropdown labels updated** — "None" → "Off", "Primary" → "Primary Row", "All" → "All Rows", etc.
- **Show GCD default** changed to Primary + Secondary rows (was Primary only).
- **Default vertical offset** changed to -100 (was -84).

### Fixed

- **Disabling a row no longer hides its spells** — Previously, disabling the Secondary row would remove its spells entirely. Now, spells from a disabled row cascade to the first enabled row that has room.
- **Missing top border when Health Bar is hidden** — Bars below the health bar (Resource Bar, Combo Points, Swing Bar) now correctly show their own top border when the bar above them is hidden.
- **Proc Tracker: Active Glow toggle takes effect immediately** — Toggling off "Active Glow" in Proc Tracker settings now hides the glow on currently active procs, instead of only applying to newly triggered procs.
- **Absorb Shields removed** — The Absorb Shield and Over-Absorb Glow options have been removed from the Health Bar. The Classic API does not support absorb tracking, so these features were non-functional.
- **Swing Bar caster tooltip** — Now correctly mentions both melee and wanding (was "wanding only").

## [1.0.84] - 2026-02-12

### Fixed

- **Searing Totem duration still showing 60s for all ranks on Totem Bar** — The v1.0.81 fix for rank-specific durations was applied to AuraTracker but the Totem Bar had its own cached duration that bypassed the fix. All ranks now correctly display their actual duration (Rank 1 = 30s through Rank 7 = 60s). *(Thanks bewz for reporting)*

### Changed

- **Improved layout spacing when Totem Bar is hidden** — On non-Shaman classes (or when the Totem Bar is disabled), the gap between Proc Tracker and Health Bar now uses the larger of the two adjacent gaps instead of collapsing to a tiny 2px gap.

## [1.0.83] - 2026-02-12

### Added

- **Per-Module Aspect Ratio** — Proc Tracker and Totem Bar now have their own independent Aspect Ratio settings, separate from the spell icon rows. Set spell rows to Ultra Compact while keeping proc icons and totem icons square (or any other combination). New dropdowns appear under Modules > Proc Tracker > Layout and Modules > Totem Bar > Layout. *(Shadowhawk)*

## [1.0.82] - 2026-02-12

### Fixed

- **Buff Reminder icons drawing on top of game windows** — Buff reminder icons were rendered above native UI panels like the quest log, character sheet, and world map. They now correctly appear behind these windows while still staying above other VeevHUD elements. *(Thanks Shadowhawk for reporting)*

## [1.0.81] - 2026-02-12

### Fixed

- **Totem timer stuck after totem dies** — When a totem was destroyed (e.g., Grounding Totem absorbing a spell, or a totem being killed by damage), the totem bar continued showing its duration ticking down instead of clearing. Now uses the game's native totem state events for reliable destruction detection. *(Thanks bewz for reporting)*
- **Searing Totem showing wrong duration** — Lower ranks of Searing Totem all showed 60s duration. Now uses rank-specific durations: Rank 1 = 30s, Rank 2 = 35s, up to Rank 7 = 60s. *(Thanks bewz for reporting)*

### LibSpellDB Updates

- Added **Magma Totem** (5 ranks, fire element) — now appears on the totem bar. *(Thanks bewz for reporting)*
- Added per-rank duration support for Searing Totem.
- New `GetSpellDuration()` API for rank-specific duration lookups.

## [1.0.80] - 2026-02-12

### Added

- **Proc Tracker: Ally-targeted procs** — Procs that buff allies (Inspiration, Ancestral Fortitude, Healing Way) now show on the Proc Tracker. The icon lights up when the buff is active on your friendly target, your target's target (if target-of-target support is enabled), or yourself as fallback. Procs with `onAlly` in LibSpellDB are automatically detected.

### Changed

- **Swing Timer: Melee on all classes** — All classes now have access to the melee swing timer (previously limited to melee/hunter). For Mage, Priest, and Warlock, melee and wand bars are mutually exclusive — only the most recently used attack type is shown. The bar auto-hides when not swinging.

### Fixed

- **Proc-tagged spells no longer appear on CooldownIcons rows** — Spells like Inspiration that are tagged as procs in LibSpellDB now correctly appear only in the Proc Tracker, not on the secondary/utility rows.

### LibSpellDB Updates

- Added 4 new proc definitions: Inspiration (Priest), Ancestral Fortitude (Shaman), Healing Way (Shaman), Ferocious Inspiration (Hunter).

## [1.0.79] - 2026-02-12

### Changed

- **Swing Timer: Druid support** — Druids now have access to the swing timer (previously disabled entirely). Tracks melee swings in Cat and Bear Form, adapts to form-change speed differences, and auto-hides when not actively swinging. Configurable under Options > Bars > Swing Bar.

## [1.0.78] - 2026-02-12

### LibSpellDB Updates

- **Warrior: Intercept disappearing at higher ranks** — Intercept was missing Rank 4 and Rank 5 from the spell database. Learning either rank caused Intercept to vanish from the HUD entirely. *(Thanks Caworder for reporting)*

## [1.0.77] - 2026-02-12

### Added

- **Swing Timer** — A new auto-attack swing timer bar that adapts to your class and spec:
  - **Hunter** — Color-coded clip zones show when it's safe to weave shots versus when you'd clip your next Auto Shot. 2-color and 3-color modes available. Background zone previews let you anticipate upcoming transitions. Optional melee weaving mode shows both ranged and melee bars simultaneously for advanced hunters.
  - **Enhancement Shaman / Fury Warrior** — Dual-wield bars colored by swing synchronization for Flurry and Windfury optimization. Green when synced, red when drifted apart.
  - **Retribution Paladin** — Highlights the twist window at the end of each swing for seal twisting timing.
  - **All melee classes** — Basic MH/OH swing bars with automatic dual-wield detection.
  - **Wand users** — Wand auto-attack timer that auto-hides when you stop.
  - Configurable under Options > Bars > Swing Bar with layout, color, text, and per-class options. *(Togg, Shadowhawk, Artvil, RidiculedDaily, anonymous French warrior)*

### Changed

- **Buff Reminders: Separate weapon enchant icons** — Dual-wielding classes (Shaman, Rogue, etc.) now see separate reminder icons for main-hand and off-hand when weapon enchants are missing or expiring. Each icon shows the actual weapon instead of the spell icon, so you can tell at a glance which hand needs enchanting.
- **Totem Bar** — Duration text scaled down to better match cooldown icon proportions.
- **Bar borders** — Adjacent bars (health, resource, combo points, swing timer) no longer have doubled-up borders where they meet.

## [1.0.76] - 2026-02-11

### LibSpellDB Updates

- **Totem Bar: Fixed Mana Tide, Windfury, and Flametongue Totems always appearing dimmed** — These totems were incorrectly configured for buff-based range detection, but none of them apply a standard player buff (Mana Tide pulses mana, Windfury/Flametongue apply weapon enchants). They now show at full brightness when active with a duration countdown. *(Thanks Ven for reporting)*
- **Totem Bar: Added Fire Resistance Totem and Nature Resistance Totem** — Both were missing from the spell database. Fire Resistance Totem (Water element) and Nature Resistance Totem (Air element) now appear on the Totem Bar with buff-based range detection. *(Thanks Ven for reporting)*

## [1.0.75] - 2026-02-11

### Fixed

- **Desperate Prayer row assignment** — Now correctly defaults to the Utility row (personal defensive) instead of the Secondary row. Self-only emergency heals are categorized as defensives, not healing throughput.

### LibSpellDB Updates

- **Priest: Improved default spell config** — Binding Heal and Circle of Healing no longer appear on the HUD (spammable fillers with no cooldown). Inner Focus now shows for Holy priests. Shadowfiend now shows for all priest specs (trainable at 66, not Shadow-only). Holy Fire removed from default display (niche in TBC).
- **Mage: Ice Block** — Fixed duplicate entry that incorrectly showed Ice Block for Arcane and Fire specs (Frost talent in TBC)
- **Hunter: Steady Shot** — No longer appears on the HUD (spammable filler with no cooldown, like Lightning Bolt and Shadow Bolt)

## [1.0.74] - 2026-02-10

### Changed

- **Performance: Reduced CPU usage** — Broad optimization pass across the addon's hot paths (icon updates, aura tracking, event handling):
  - Eliminated redundant WoW API calls per update cycle by caching target state and time values once per frame
  - Combined duplicate aura queries (active check + remaining time) into a single pass
  - Replaced the central 100 Hz polling ticker with individual timers at each module's actual update rate
  - Removed per-event table allocations in combat log processing (reuses a single table)
  - Localized frequently-called WoW API functions across all hot-path modules

### LibSpellDB Updates

- `IsRotational()`, `GetAuraTarget()`, and `GetSortedSpells()` all received algorithmic performance improvements (O(n) → O(1) lookups, pre-computed sort keys)

## [1.0.73] - 2026-02-10

### LibSpellDB Updates

- **Paladin: Missing seals** — Added Seal of Wisdom, Seal of Light, Seal of Justice, and Seal of Vengeance to the spell database. These now appear on Paladin cooldown icon rows. Seal of Blood also now appears for Protection Paladins (previously Retribution only).

## [1.0.72] - 2026-02-10

### Added

- **Shaman: Totem Bar** — A dedicated 4-slot element display (Fire, Earth, Water, Air) that replaces the old approach of mixing totems into normal cooldown icon rows. Each slot shows the currently active totem for that element with a duration countdown spiral and timer text. When a totem expires, the slot shows a dimmed icon of the last totem you placed for that element. Slots stay hidden until you cast your first totem of that element. Zero-cooldown totems (Windfury, Searing, Stoneskin, etc.) are removed from the normal icon rows and only appear in the Totem Bar. Cooldown totems (Earthbind, Grounding, Mana Tide, etc.) appear in both the Totem Bar and their normal cooldown row. Totemic Call correctly clears all active totem states. Configurable under Options > Bars > Totem Bar with icon size and spacing controls. *(Shadowhawk)*
- **Shaman: Totem Range Detection** — When you move out of range of a totem that buffs your party (Windfury, Strength of Earth, Grace of Air, etc.), its Totem Bar slot dims to 30% opacity while the countdown timer keeps running — so you can tell at a glance that you've walked too far. Totems that don't apply a party buff (Searing, Earthbind, etc.) always show as in-range since there's nothing meaningful to check.

### LibSpellDB Updates

- New `appliesBuff` field on 12 Shaman totems mapping summon spell to party buff spell IDs (used for range detection)
- Added Wrath of Air Totem (spell 3738)
- Mage: Scorch now maps to its Fire Vulnerability debuff via `triggersAuras`, enabling target debuff tracking

## [1.0.71] - 2026-02-10

### Fixed

- **Proc Tracker: Stack count position** — Fixed v1.0.69 regression where Masque moved proc stack counts (e.g., Flurry stacks) from the top-right corner to the bottom-right. Stack text is now positioned independently of Masque skinning.

## [1.0.70] - 2026-02-09

### Added

- **Single-Target Aura Tracking** — Spells that can only be active on one target at a time now track their aura regardless of your current target, just like hard CC already does. Affected spells: Prayer of Mending (shows remaining charges even when targeting the boss), Earth Shield (shows charges on the tank while healing others), and Slow (shows duration when you switch targets).

### LibSpellDB Updates

- New `singleTarget` field and `IsSingleTarget()` API for spells limited to one active target at a time
- 12 spells tagged: Polymorph, Sap, Fear, Banish, Enslave Demon, Hibernate, Mind Control, Shackle Undead, Turn Undead, Prayer of Mending, Earth Shield, Slow

## [1.0.69] - 2026-02-09

### Added

- **Masque: Proc Tracker support** — Proc icons now appear as a separate "Procs" group in Masque, skinnable independently from cooldown icons.
- **Masque: Buff Reminders support** — Buff reminder icons now appear as a "Buff Reminders" group in Masque.
- **Aspect Ratio: Two new options** — "Slightly Compact" and "Very Compact" fill the gaps between Square, Compact (4:3), and Ultra Compact (2:1).

### Fixed

- **Masque: No reload required** — Changing icon size or aspect ratio with Masque installed no longer requires a UI reload. The reload popup has been removed.

## [1.0.68] - 2026-02-09

### Fixed

- **GCD-only predictions on non-predictable resources** — Fixed v1.0.67 regression where spells on GCD would show spurious prediction timers even when the resource type (e.g., rage) has no prediction model. GCD now only extends predictions when a real resource prediction is active.

## [1.0.67] - 2026-02-09

### Fixed

- **Druid: Energy prediction accuracy** — Fixed two bugs that caused energy predictions to show wildly wrong values (e.g., 6s for Shred) after shifting into Cat Form. The tick timer is now correctly tracked as continuous across form changes, and Furor energy gains properly restart predictions instead of being ignored.
- **Resource predictions now factor in GCD** — Predictions previously ended before the spell was actually usable if the GCD was still running. The countdown now accounts for GCD as a constraint, preventing predictions from finishing ~0.2s early.
- **Prediction countdown text continues through GCD** — When a resource prediction countdown is active and the resource arrives while the GCD is still ticking, the countdown text now seamlessly continues to zero instead of disappearing.

### Improved

- **New user experience** — First-time users who dismiss the welcome popup no longer see migration notices for features that already existed when they installed.

## [1.0.66] - 2026-02-09

### Added

- **Druid: Per-Spell Form Visibility** — Feral druids can now override which form each spell appears in. A clickable form label (Cat / Bear / Any) appears next to each spell in the Spell Configuration panel. Gold text indicates a custom override; grey text shows the tag-based default. Disabled spells cannot be cycled until re-enabled. *(Soveliss)*
- **Druid: Spell Config Info Text** — Feral druids see an explanation at the top of the Spell Configuration panel describing how form filtering works and how to override it per spell.

### Changed

- **Buff Reminders: Reverted ghost frame fix** — Removed the v1.0.65 defensive frame-reuse code for /reload, which addressed a bug that could not be reproduced. Simpler code path restored.

## [1.0.65] - 2026-02-09

### LibSpellDB Updates
- **Priest racial abilities** — 8 race-restricted priest spells now tracked: Starshards, Elune's Grace (Night Elf), Feedback (Human), Symbol of Hope (Draenei), Touch of Weakness (Undead/Blood Elf), Hex of Weakness, Shadowguard (Troll), Consume Magic (Blood Elf). Chastise, Desperate Prayer, and Devouring Plague now correctly restricted to their respective races.

## [1.0.64] - 2026-02-09

### LibSpellDB Updates
- **Druid: Rake DoT tracking** — Rake now prioritizes showing the active DoT duration on its icon, so you can track when it needs refreshing. Previously the icon showed energy prediction even while the DoT was active.

## [1.0.63] - 2026-02-09

### Fixed

- **Buff Reminders: Settings not persisting** — Icon Opacity and Icon Size were resetting on every reload due to a migration function that ran unconditionally. Removed the stale migration and fixed inline fallbacks to properly use AceDB defaults.

## [1.0.62] - 2026-02-09

### Added

- **Buff Reminders: Respect Resource Cost** — New toggle under Buff Reminders > Behavior. When enabled (default), buff reminders only appear when you have enough resources to cast the spell — for example, Battle Shout only reminds when you have enough rage. Uncheck to always show reminders for missing buffs regardless of your current resource level. *(Shadowhawk)*

## [1.0.61] - 2026-02-09

### Added

- **Druid Mana Bar: Form Cost Marker** — Optional vertical line that appears on the mana bar when your mana drops below the cost of re-entering your current shapeshift form. Shows at a glance whether you can safely shift out and back. Disabled by default (enable in Resource Bar > Mana Bar (Druid)).
- **Druid Mana Bar: Mana Ticker Toggle** — New option to show or hide the mana tick spark on the secondary mana bar. Disabled by default for a cleaner look.

### Changed

- **Druid Mana Bar: Spark off by default** — The fill position spark is now disabled by default on the secondary mana bar. The thin bar is readable without it, and it reduces visual clutter when combined with the mana ticker or form cost marker. Can still be enabled in options.

## [1.0.60] - 2026-02-08

### Added

- **Druid: Mana Bar in Cat/Bear Form** — A secondary mana bar now appears below the resource bar when shapeshifted into Cat or Bear Form, so you can monitor mana for shifting and casting without leaving form. Includes configurable height, color picker, spark toggle, and text format. The mana ticker also moves to the secondary bar while in form. Enabled by default for all Druid specs. *(Birdehh, Shadowhawk)*

## [1.0.59] - 2026-02-08

### Added

- **Druid: Form-Conditional Abilities** — Feral druid abilities now dynamically filter based on your current shapeshift form. Cat abilities (Mangle, Shred, Rake, etc.) show in Cat Form; bear abilities (Mangle, Lacerate, Swipe, etc.) show in Bear Form. Shared abilities (Faerie Fire, Barkskin, etc.) always show. When in caster, travel, or aquatic form, your last cat/bear form's abilities remain visible. Defaults to cat on login. Only active for feral spec — balance and resto druids are unaffected. *(Birdehh, Shadowhawk)*

### LibSpellDB Updates
- New `CAT_FORM` and `BEAR_FORM` category tags for classifying feral druid spells by required form
- 19 feral druid spells tagged: 9 cat-form, 10 bear-form
- TBC_Rotations.md comprehensively rewritten against Wowhead/Icy Veins TBC Classic guides

## [1.0.58] - 2026-02-08

### Fixed

- **Spell Configuration: Empty rows disappearing** — Removing all spells from a row (e.g., Secondary) no longer causes the row to vanish from the Spell Configuration window. Empty rows now remain visible and can still receive spells via drag-and-drop.
- **Buff Reminders: Duration/stacks text** — Duration and stack count text on reminder icons now only appears when the specific threshold is violated (e.g., time remaining below threshold), rather than showing whenever the setting was configured.

## [1.0.57] - 2026-02-08

### Added

- **Buff Reminders: Pulse Animation Toggle** — New option under Buff Reminders > Behavior to disable the breathing pulse effect. Icons still appear and disappear with animation but remain static while visible.
- **Buff Reminders: Show While Resting/Mounted** — New options to keep buff reminders visible in inns/cities and while mounted. Both default to off (existing behavior).
- **Buff Reminders: Duration & Stack Text** — When a spell's time threshold or min stacks setting is greater than zero, the remaining duration or current stack count is now shown directly on the reminder icon, matching the style of the main HUD cooldown icons.
- **Buff Reminders: Time Threshold Max** — Increased the maximum configurable time threshold from 5 minutes to 10 minutes.

### LibSpellDB Updates
- Added `name` and `description` fields to all 451 spell entries (sourced from Wowhead TBC tooltips)
- Comprehensive cooldown/duration audit against Wowhead TBC database — 30+ corrections across all classes
- Druid: Omen of Clarity now marked as `dispelType = "Magic"` (purgeable), so Buff Reminders defaults to combat-aware visibility
- Added audit tooling (`Tools/wowhead_audit.py`) for ongoing spell data maintenance

## [1.0.56] - 2026-02-08

### Added

- **Totemic Call Support** — Casting Totemic Call now instantly clears all active totem duration timers on the HUD, instead of waiting for each totem to expire individually. *(Shadowhawk)*

### Fixed

- **Keybind display for ranked spells** — When multiple ranks of a spell are on your action bar, the keybind shown on icons now correctly prefers the exact rank match. Previously, a lower-rank keybind could display instead of the max-rank one.
- **Cooldown text: m:ss format for 1–5 minute durations** — Durations between 1 and 5 minutes now show as `m:ss` (e.g., `2:30`) instead of rounding to whole minutes, giving more precise feedback on long cooldowns.

### LibSpellDB Updates
- Added Totemic Call (36936) with `clearsTotems` field for totem-recall detection
- Fixed Searing Totem duration: 55s → 60s
- Fixed Healing Stream Totem duration: 60s → 120s
- Fixed Mana Spring Totem duration: 60s → 120s

## [1.0.55] - 2026-02-08

### Fixed

- **Buff Reminders not responding to Global Scale** — Changing the Global Scale slider now correctly resizes Buff Reminder icons. Previously, only the main HUD elements (icon rows, bars) were affected.

## [1.0.54] - 2026-02-08

### Added

- **Victory Rush Timer** — When Victory Rush becomes usable after a killing blow, the icon now shows a 20-second countdown with an aura-style glow and spiral, filling the gap left by the game's invisible usability window. The timer refreshes on subsequent qualifying kills and clears immediately when the ability is cast or the window expires. Non-qualifying kills (grey mobs) are correctly ignored when starting the timer.

### LibSpellDB Updates
- New `reactiveWindow` and `reactiveWindowEvent` spell data fields for modeling abilities with time-limited usability windows
- New `GetReactiveWindow(spellID)` API for querying window duration
- Victory Rush: added reactive window metadata (20s after PARTY_KILL)

## [1.0.53] - 2026-02-08

### Added

- **Configurable Element Order** — New "Layout" tab in settings lets you reorder all HUD elements: Proc Tracker, Health Bar, Resource Bar, Combo Points, Primary Row, Secondary Row, and Utility Row. Move elements up or down to put bars below icons, rearrange icon rows, or any custom stacking order. Per-element gap sliders control the spacing between each pair of adjacent elements. *(FionaSilberpfeil, Shadowhawk)*
- **Settings migration** — Existing users' custom gap values (icon row gap, combo point offset, section gap, etc.) are automatically migrated to the new unified layout system. No manual reconfiguration needed.

## [1.0.52] - 2026-02-08

### Added

- **Druid: Claw and Rake** — Now available as selectable abilities on the Feral Druid HUD. Rake shows energy prediction first, then displays the active debuff when you have enough energy to reapply. *(Soveliss)*

### Changed

- **Improved aura display for cooldown-priority abilities** — Spells like Mortal Strike, Bloodthirst, Rake, Hemorrhage, and Mangle now show their active buff or debuff once the cooldown finishes, instead of hiding the aura entirely. Stack counts (e.g., Bloodthirst heal charges) always display.
- **Buff Reminders: default tracking scope** — All buff reminders now default to tracking yourself only. Party and Raid tracking are available as opt-in options for group-oriented buffs like Fortitude and Mark of the Wild.

### LibSpellDB Updates
- Added Claw (6 ranks) and Rake (5 ranks) for Feral Druid
- Renamed `ignoreAura` to `cooldownPriority` — aura display is now suppressed only while on cooldown, rather than hidden entirely

## [1.0.51] - 2026-02-08

### Added

- **Buff Reminders** — A new feature that shows large, semi-transparent reminder icons when you're missing an important long-duration buff. Works out of the box for every class with sensible defaults — just install and go. Covers all maintenance buffs: Battle Shout, Inner Fire, Mark of the Wild, Fortitude, weapon enchants, and many more. *(Shadowhawk, anonymous French warrior)*
  - **Buff group awareness** — Understands equivalent buffs (Fortitude / Prayer of Fortitude share one reminder), exclusive buffs (Battle Shout / Commanding Shout — configure which to prioritize), and weapon enchants (rogue poisons check both MH and OH; shaman imbues check based on weapon setup)
  - **Smart pre-requisites** — Reminders only appear when the spell is known, you have the resources to cast it, and you're not resting, mounted, or on a taxi
  - **Per-spell configuration** — Enable/disable individually, set time-remaining and stack thresholds (Inner Fire, Water Shield, Lightning Shield), choose combat state (in combat / out of combat / any), and track against yourself, party, or raid
  - **Intelligent defaults** — Purgeable long-duration buffs (Fortitude, MOTW) default to out-of-combat only; short/non-purgeable buffs (Battle Shout, Demon Armor) default to any. Situational buffs (Water Walking, Detect Invisibility, Righteous Fury) are disabled by default
  - **Permanent aura handling** — Auras and aspects (Trueshot Aura, Devotion Aura, Aspect of the Hawk) are treated as toggles with no time threshold or party tracking, since allies are either in range or not
  - **WeakAura-style animations** — Shrink-in, pulse, and grow-out effects using WoW's native Animation API. Smooth flicker-free pulse via ordered REPEAT animations
  - **Live preview** — A "Show Preview" button in settings displays a sample reminder icon so you can see your size/opacity/position changes in real-time
  - **Configurable appearance** — Icon size (up to 400px), opacity, spacing, and position offset relative to the HUD
  - **Migration notice** — Existing users see a one-time popup explaining the new feature and how to configure or disable it
- **Buff Reminder options tab** — New "Buff Reminders" tab in `/vh` settings with a Settings sub-tab (master toggle, appearance, position, preview) and a Spells sub-tab (per-spell enable/disable, thresholds, combat state, tracking scope, and group priority). Spells are sorted with important buffs first, situational buffs last.

### Fixed

- **Options initialization order** — Fixed a race condition where the options panel could build its UI before other modules (like Buff Reminders) were initialized, causing incorrect default values to appear. Options table construction is now deferred until the panel is first opened.

### LibSpellDB Updates
- New `BuffGroups` system for modeling relationships between related buffs (equivalent and exclusive groups), with weapon enchant support for poisons and imbues
- Comprehensive long-duration buff data added for all 9 classes with `LONG_BUFF` tags, `dispelType` fields, and group membership
- New `SITUATIONAL` tag for niche utility spells (Water Walking, Detect Invisibility, etc.)
- New APIs: `GetDispelType()`, `GetBuffGroup()`, `GetBuffGroupSpells()`, `IsInBuffGroup()`, `GetBuffGroupRelationship()`

## [1.0.50] - 2026-02-07

### Added

- **Shaman: Totem Duration Tracking** — All shaman totems now show an active duration countdown when placed, just like Shadowfiend and Water Elemental. The icon displays a cooldown spiral and remaining time text so you can see exactly how long your totem has left. Correctly enforces one totem per element — placing a new Earth totem automatically clears the old Earth totem's timer. This is a first step toward better totem support in VeevHUD; a more comprehensive totem model (grouped icons, element-aware UI) is still being explored. *(Soveliss, Shadowhawk)*

### LibSpellDB Updates
- All 22 shaman totems now tagged with `TOTEM` category and element tags (`TOTEM_EARTH`, `TOTEM_FIRE`, `TOTEM_WATER`, `TOTEM_AIR`) with duration data
- New `CONSUMES_ALL_RESOURCE` tag replaces the `consumesAllResource` field (Execute)

## [1.0.49] - 2026-02-07

### Changed

- **Ultrawide monitor support** — The Horizontal and Vertical Offset sliders now scale to your screen resolution instead of being capped at ±500 pixels. On a 5120×1440 ultrawide, the horizontal slider goes up to ±2600 — enough to place the HUD anywhere on screen. *(Thanks ChaosEternal for the feedback!)*

## [1.0.48] - 2026-02-07

### Added

- **Health Bar: Heal Prediction** — The health bar now shows incoming heals as a lighter extension of the health fill, giving you a preview of where your health will be when the heal lands. Uses the same visual style as Blizzard's default raid frames. *(Shadowhawk)*
- **Health Bar: Absorb Shields** — Active absorb shields (Power Word: Shield, Ice Barrier, etc.) are shown as a Blizzard-style shield texture on the health bar between the health fill and heal prediction. Compatible with TBC Anniversary Edition where the modern absorb API is unavailable — uses a smart UnitAura scanning fallback that updates in real time as shields take damage. *(Shadowhawk)*
- **Health Bar: Over-Absorb Glow** — A glowing edge effect appears when absorb shields exceed your missing health, indicating you have more shielding than you can currently use.
- **Health Bar Overlay Options** — New toggles in the Health Bar settings to individually enable/disable heal prediction, absorb shields, and over-absorb glow.
- **Resource Bar: Predicted Cost Toggle** — The predicted resource cost overlay can now be toggled on/off in resource bar settings. Enabled by default.
- **Queued Highlight Toggle** — The queued ability icon highlight can now be toggled on/off in icon behavior settings. Enabled by default.

### Changed

- **Config defaults cleanup** — All configuration defaults are now managed exclusively through the AceDB layer. Removed ~70 inline fallback defaults scattered across the codebase, improving consistency and preventing potential config mismatches.

## [1.0.47] - 2026-02-07

### Added

- **Configure Proc Tracker** — You can now choose which procs appear in the proc tracker area. A new "Proc Tracker" section at the bottom of the Spell Configuration window shows all available procs for your class with checkboxes to enable or disable each one. All procs are enabled by default. The "Reset Spell Config" button also resets proc visibility. *(Shadowhawk)*

### Fixed

- **Execute resource bar prediction** — The resource bar now correctly shows Execute consuming all remaining rage instead of only the base cost, giving an accurate preview of post-cast rage.
- **Queued ability cost stacking** — When multiple abilities are queued simultaneously, their costs are now combined on the resource bar instead of only showing one. Prevents double-counting with casting spells.

### LibSpellDB Updates
- Proc descriptions updated to reflect max talent rank values (Enrage: 25% damage, Blood Craze: 3% health)
- Warrior Execute marked as `consumesAllResource` for accurate rage prediction

## [1.0.46] - 2026-02-07

### Added

- **Queued Ability Highlight** — Icons for queued "next melee" abilities (Heroic Strike, Cleave, Maul, etc.) now show Blizzard's default bright highlight overlay, matching the visual feedback from the default action bars. Detects any queued ability dynamically via the WoW API. *(Togg, Shadowhawk, Artvil, RidiculedDaily, anonymous French warrior)*
- **Predicted Resource Cost** — The resource bar now shows a darkened section at the right edge of the fill representing the cost of pending actions. Works for queued next-melee abilities (e.g., Heroic Strike rage cost) and spells currently being cast or channeled. Updates instantly via events with no additional polling. *(Caworder)*

### Fixed

- **Proc tracker: multi-rank detection** — Proc buffs like Enrage, Flurry, and Blood Craze are now detected regardless of which talent rank the player has. Previously only the highest rank was tracked, causing procs to not appear for players with lower-rank talents.
- **Proc tracker: animation positioning** — Fixed a bug where the proc "pop-in" scale animation could corrupt icon positions when sliding animations were also active. Animations are now queued until after repositioning completes.

### LibSpellDB Updates
- Proc entries for Enrage, Flurry (Warrior & Shaman), and Blood Craze now include all talent rank spell IDs for multi-rank matching

## [1.0.45] - 2026-02-06

### Fixed

- **Cast feedback black box artifact** — Fixed a rendering bug where casting spells (especially Icy Veins and others) could cause a large black box to flash on screen during the cast feedback "pop" animation. This was caused by WoW's Scale animation API interacting badly with Cooldown frame rendering. The animation now uses a different technique that avoids the artifact entirely while preserving the same visual feel. *(Thanks Shadowhawk, FionaSilberpfeil, Syn2108 for reporting)*

### Added

- **Customizable Bar Texture** — All bars (health, resource, combo points, energy ticker) now use a shared status bar texture selectable from SharedMedia. Found in the new Appearance section of General settings.

### Changed

- **Gradient toggle consolidated** — The four separate per-module gradient toggles have been replaced by a single global "Show Gradient" setting in the Appearance section.

## [1.0.44] - 2026-02-06

### Fixed

- **Ready glow dimmed on cooldown rows** — When "dim on cooldown" was active, the ready glow was partially dimmed because it inherits the icon's alpha. The icon now brightens to full alpha when the ready glow is showing, so the glow and icon brighten together as a cohesive "almost ready" signal.
- **Flow layout last-row distribution** — Utility row flow layout now ensures the last row has at least half the configured max icons, preventing a single icon from sitting alone on a new row.

### Added

- **Ready Glow: Anticipation slider** — New option to control how early (0–2s) the ready glow triggers before an ability finishes its cooldown. Default remains 0.5s. Found in the Ready Glow section of icon options.

### Changed

- **"Persistent Glow" renamed to "Re-trigger"** — The ready glow row setting is now called "Re-trigger" to better describe its behavior: it controls which rows re-trigger the glow each time an ability becomes usable, rather than implying the glow stays on.

## [1.0.43] - 2026-02-06

### Fixed

- **Spell config opening unexpectedly** — Interacting with sliders (clicking the track) or pressing Enter in number fields could falsely trigger the Spell Configuration window to open. The Spells tab now uses an explicit "Open Spell Configuration" button instead of an automatic redirect.

## [1.0.42] - 2026-02-06

### LibSpellDB Updates
- **Shaman proc tracking** — Shamanistic Focus ("Focused") and Flurry now appear in the proc tracker for Enhancement Shamans
- **Priest proc tracking** — Clearcasting (Holy Concentration) now appears in the proc tracker for Holy Priests
- **Warrior proc tracking** — Blood Craze now appears in the proc tracker
- **Paladin: Seal of the Crusader** — Now appears in the spell list at all levels (all 7 ranks added)

## [1.0.41] - 2026-02-05

### Added

- **Profile Support** — Full profile management powered by AceDB. Create, copy, switch, delete, and reset profiles from the new Profiles tab. Legacy saved variables are automatically migrated.
- **Per-Spec Profiles** — Profiles can automatically switch when you change talent specializations (via LibDualSpec). Set a different profile for each spec in the Profiles tab.
- **Color Pickers** — Custom color options for health bar, resource bar, energy ticker, and combo points. Each has a color picker that activates when the automatic coloring option is unchecked.
- **Power Color** — Resource bar now uses "Power Color" mode (blue for mana, red for rage, yellow for energy) instead of the old "Class Colored" option. Uncheck to use a custom color.
- **Flow Layout for All Rows** — Flow layout (multi-row icon wrapping) is now available for Primary and Secondary rows, not just Utility. Configure icons per row with smart redistribution to avoid lone icons on the last row.
- **Per-Row Ready Glow Mode** — The "always glow while ready" behavior can now be configured per row. For example, keep persistent glow on Primary row while other rows flash once.

### Changed

- **Revamped Options UI** — The options panel is now a draggable AceConfig window instead of being embedded in Blizzard's Settings. Settings are organized into logical groups (Size, Text, Color, Spark, etc.) for easier navigation.
- **Standalone Spell Configuration** — Spell config is now a standalone draggable window that seamlessly transitions to/from the main options window, sharing position when switching between them.
- **Self-Contained Libraries** — All Ace3 libraries are now embedded in the addon, removing the need to install Ace3 separately. If you already have standalone Ace3 installed, it takes precedence automatically.

### Fixed

- **Ready glow false triggers** — Ready glow now verifies the player can actually afford the spell before triggering, preventing false glows when WoW reports abilities as "usable" during cooldowns despite insufficient resources.
- **Flow layout edge cases** — Fixed layouts breaking when icons per row was set to very low values; improved icon redistribution for small icon counts.

## [1.0.40] - 2026-02-05

### Added

- **Summon Stack Count** — Spells that summon multiple pets (like Force of Nature) now display the number of living pets as a stack count. When treants die, the count decrements so you know how many remain active.

## [1.0.39] - 2026-02-05

### Added

- **Keybind Text on Icons** — Shows keyboard shortcuts on cooldown icons, similar to default action bars. Scans action bars (including macros) to find matching spells and displays abbreviated keybinds (e.g., Shift+X → SX). Supports Bartender4, ElvUI, Dominos, and default UI. Toggle in options.

### Fixed

- **Spell Ordering** — Fixed a bug where disabling some abilities in a row could cause the remaining abilities to display in the wrong order

## [1.0.38] - 2026-02-05

### Improved

- **Mana Tick Timer ("Next Full Tick")** — Major accuracy improvements for the 5-Second Rule countdown:
  - Now correctly shows 5-7 second countdown to first full tick after casting
  - Progress bar only jumps forward on recalibration, never backward
  - Stays pinned at 100% until the full tick actually arrives (no premature resets)
  - Each observed partial tick automatically refines the prediction

## [1.0.37] - 2026-02-05

### LibSpellDB Updates

- **Faerie Fire (Feral)** — Now tracked separately from caster Faerie Fire (usable in cat/bear form)
- **Mangle (Bear)** — Now shows cooldown instead of debuff timer (you spam on 6s CD, debuff lasts 12s)

## [1.0.36] - 2026-02-05

### Added

- **Show at Full Energy** option — Energy ticker continues running at full energy, useful for timing openers (default ON)
- **Druid Powershifting Support** — Energy tick timer correctly resets when entering Cat Form, matching TBC mechanics

### Changed

- **Ready glow threshold** — Reduced from 1 second to 0.5 seconds before abilities become usable (felt too early)
- **Ready glow for Resource Timer** — Now triggers when resource prediction shows <0.5s until affordable
- Energy ticker only shows after observing a real tick (prevents inaccurate display after reload/zone change)

### Fixed

- Duplicate racial icons (Blood Fury, Arcane Torrent) no longer appear when multiple spell variants exist

### LibSpellDB Updates

- New `TEMPORARY_SUMMON` tag for short-duration pet abilities
- Added missing Hunter abilities (Multi-Shot, Volley, Arcane Shot, etc.)
- Fixed Maul missing `ROTATIONAL` tag

## [1.0.35] - 2026-02-04

### Fixed

- **Spell reordering** — Fixed drag-and-drop to allow dropping spells at the end of a category
- **Ready glow for lockout spells** — Ready glow now correctly triggers when a target lockout debuff (like Forbearance) is about to expire, even though the spell appears unusable during the lockout

## [1.0.34] - 2026-02-04

### Added

- **Cooldown Finish Sparkle** — WoW's native sparkle/bling effect now plays when cooldowns finish (per-row configurable, defaults to all rows). Note: Also triggers on GCD finish, matching default action bar behavior.
- **Smooth Dim Transition** — Icons now smoothly fade to 30% alpha when going on cooldown, synced with cast feedback animation timing. Can be disabled in Animations settings.

### Changed

- **More row options** — All row-based dropdowns now offer 6 choices: None, Primary Only, Primary + Secondary, All Rows, Secondary + Utility, Utility Only. This allows more flexible configurations like usable glow on primary row but sparkle on secondary/utility rows.

### Fixed

- **Prediction spiral cleanup** — Resource prediction spirals now clear immediately when you gain enough resources (e.g., zoning and gaining full mana)
- **Aura spiral cleanup** — Buff/debuff spirals now clear immediately when switching targets (instead of lingering from the previous target)
- **Dim alpha on reload** — Icons on cooldown now correctly show 30% alpha immediately after /reload (previously showed full alpha until state changed)

## [1.0.33] - 2026-02-04

### Changed

- **Migration popup improvements** — Now shows for all users affected by UI scale auto-compensation (not just those who manually scaled down). Message explains whether your HUD is now smaller or if manual settings are stacking.
- Migration popups are now skipped for brand new users (they get the correct behavior from the start)

## [1.0.32] - 2026-02-04

### Added

- **UI Scale Auto-Compensation** — VeevHUD now automatically adjusts for your in-game UI Scale setting, so the HUD looks the same size whether you use 65% or 100% UI scale. No more oversized icons at default settings!
- **Migration popup** — If you previously adjusted Global Scale to compensate for a high UI scale, a one-time popup will offer to reset it to 100%
- **Reusable MigrationManager** — Framework for future migration notices when addon behavior changes

### Changed

- Popups now appear 30% from the top of the screen (instead of center) to avoid covering the HUD
- Improved popup title centering

### LibSpellDB Updates

- New `auraTarget` system for explicit buff tracking targets (self, ally, pet, none)
- Added `GetAuraTarget()` API function

## [1.0.31] - 2026-02-03

### Fixed

- **Aura cache invalidation** — Fixed an issue where auras could fail to update when the same player was referenced by multiple unit tokens (e.g., "party1" and "targettarget"). Cache is now keyed by GUID for correct invalidation.

### LibSpellDB Updates

- `IsSelfOnly()` now correctly identifies `HAS_BUFF` and `CC_IMMUNITY` tagged spells as abilities that can target others

## [1.0.30] - 2026-02-01

### Changed

- **Range indicator during cooldown** — The out-of-range indicator now shows while abilities are on cooldown, as long as you have the resources to use them. This gives you a heads-up on positioning while waiting for the cooldown to finish.
- **Cleaner visual priority** — When you lack resources for an ability, the grey/resource indicators take priority and the range indicator is hidden. This prevents overlapping visual states and keeps feedback clear.

### Fixed

- **Range indicator after cooldown ends** — Fixed an issue where the range indicator wouldn't appear immediately when a spell like Bloodthirst came off cooldown (was incorrectly suppressed by the spell's healing buff)

## [1.0.29] - 2026-02-01

### Fixed

- **Config visibility** — HUD now stays visible at full opacity when the options panel is open, so visibility settings (Out of Combat Opacity, Hide on Flight Path) don't make it hard to configure

## [1.0.28] - 2026-01-31

### Added

- **Range Indicator** — Out-of-range spells now display a desaturated icon with a red range indicator at the bottom
- Smooth fade animations for range indicator transitions

### Changed

- **Improved buff tracking** — Rotational spells now track auras on your current target, while cooldown-only spells always show in the HUD
- Code cleanup: removed unused RangeChecker API methods

### LibSpellDB Updates

- New `IsSelfOnly()` and `IsRotational()` API functions for smarter buff tracking behavior

## [1.0.27] - 2026-01-31

### Fixed

- **AoE CC tracking** — When a CC effect breaks on one target (e.g., Psychic Scream), icons now correctly continue tracking remaining affected targets
- **Spell Configuration panel** — Utility row positioning now updates correctly when spells are reordered
- Various bug fixes and code cleanup

### Changed

- **Major refactor** — Extracted modules and removed ~1700 lines of unused/dead code
- All spell IDs now normalize to canonical (base) ID for consistent tracking across ranks

### LibSpellDB Updates

- Added Priest Chastise as soft CC for all specs
- Fixed duplicate spell ID warnings and nil access bugs

## [1.0.26] - 2026-01-31

### Changed

- **New Layout System** — Completely refactored how HUD elements (combo points, resource bar, health bar, proc tracker) are positioned
  - Elements now register with a central layout manager instead of calculating positions based on other modules
  - Automatic repositioning when any element's visibility changes (e.g., Druid entering/leaving Cat Form)
  - Cleaner architecture: modules no longer need to know about each other's positions
  - New `/vh layout` debug command to inspect element positions
- **Icon Row Gap setting** — New slider in Appearance section to control the gap between the icon row and the first bar above it

### Fixed

- Discord release notifications now use the description field (supports up to 3500 characters) instead of embed fields (which had a 1024 character limit)

## [1.0.25] - 2026-01-31

### Added

- **Font customization** — New global font setting lets you change the font used for all HUD text (cooldowns, stack counts, health/resource values, proc durations)
  - Integrates with LibSharedMedia-3.0 to discover fonts from other addons
  - Scrollable dropdown with font preview (each font rendered in its own typeface)
  - Fonts update instantly without requiring a UI reload
  - Default: Expressway, Bold (bundled with VeevHUD)
- **New FontManager module** (`Core/FontManager.lua`) — Centralizes font registration and utilities

### Changed

- **Text display options** — Replaced "Show Text" checkbox with a "Text Display" dropdown for Health Bar and Resource Bar
  - Options: Current Value, Percent, Both, None
  - More intuitive than separate toggle + format settings
- Font setting placed in Appearance section (after Vertical Offset)

### Removed

- Cleaned up unused font constants (`FONTS.DEFAULT`, `FONTS.BOLD`)

## [1.0.24] - 2026-01-30

### Fixed

- **Blood Fury GCD tracking bug** — Orc racial spell power variants (33697, 33702) no longer briefly show as "ready" when triggering a GCD while on cooldown
- **Spell ID discovery** — Now correctly tracks the actual spell ID from your spellbook instead of the library spell ID (fixes issues where class-specific spell variants weren't tracked properly)

### Changed

- Options UI consistency improvements and better user-friendliness

### LibSpellDB Updates

- Added all Orc Blood Fury variants (20572, 33697, 33702) for proper class-specific tracking
- Added Fire Nova Totem (all ranks)

## [1.0.23] - 2026-01-30

### LibSpellDB Updates

- Hemorrhage now shows cooldown display instead of debuff tracking (more useful for rotation)

## [1.0.22] - 2026-01-30

### Added

- **Resource Timer** — A new resource cost display mode that extends the cooldown spiral to show when you'll actually be able to cast, factoring in both cooldown AND resource regeneration
  - Icons show `max(cooldown_remaining, time_until_affordable)` as a unified countdown
  - **Energy**: Highly accurate tick-aware predictions (2-second ticks), accounts for Adrenaline Rush
  - **Mana**: Tick-aware with 5-second rule tracking, measures in-combat vs passive regen rates separately
  - **Rage**: Falls back to vertical fill (rage generation is unpredictable)
  - If prediction is wrong (resources spent mid-countdown), automatically falls back to deterministic vertical fill
  - Configure via "Resource Cost Style" → "Resource Timer" in settings
- **Mana Tick Indicator** for mana classes (Mage, Priest, Warlock, Paladin, Druid, Shaman, Hunter)
  - Shows a spark overlay on the resource bar indicating progress toward the next mana tick
  - **"Outside 5SR"** mode: Shows the 2-second tick cycle only when regenerating at full spirit rate
  - **"Next Full Tick"** mode (recommended): Intelligently combines 5-second rule AND tick timing — calculates exactly when your first full-rate tick will arrive and shows a seamless countdown. Cast right after it completes to maximize mana efficiency.
- New core modules: `TickTracker.lua`, `FiveSecondRule.lua`, `ResourcePrediction.lua`

### Changed

- Default energy ticker style changed to "Spark" (overlay on resource bar)
- Default resource cost display changed to "Resource Timer" (prediction mode)
- Increased debug log buffer from 200 to 500 entries

## [1.0.21] - 2026-01-29

### Added

- **Energy Tick Indicator** for Rogues and Druids
  - Shows progress toward the next energy tick (energy regenerates every 2 seconds)
  - Three styles: "Ticker Bar" (thin bar below resource bar), "Spark" (overlay on resource bar), or "Disabled"
  - Configurable in Options under Resource Bar section

### Fixed

- Spells Configuration panel now refreshes correctly when opened before initialization completes
- GitHub release workflow now correctly extracts changelog for v-prefixed tags

## [1.0.20] - 2026-01-30

### Added

- Discord release notifications now include changelog summary

### Changed

- **Refactored aura tracking** for LibSpellDB's new `triggersAuras` array structure
- Aura priority system: CC_HARD > CC_SOFT/ROOT > array order for abilities with multiple effects
- All spell lookups now normalize to canonical ID for consistent tracking across ranks

### Fixed

- Rampage stack count now displays correctly (was broken due to rank ID mismatch)
- Hamstring debuff tracking (same-ID auras now handled properly)
- Removed dead code (`GetLongestAuraRemaining`)

### LibSpellDB Updates

- **New `triggersAuras` array** for multi-aura spells (Pounce stun + bleed, Wyvern Sting sleep + DoT, etc.)
- **Comprehensive TBC spell ranks** added for all 9 classes from wago.tools data
- New trigger mappings: Scatter Shot, Wyvern Sting DoTs, Pounce Bleeds, Nature's Grasp roots, Misdirection
- New spells: Mage Cone of Cold, Dragon's Breath, Flamestrike, Blizzard, Slow; Rogue Backstab
- New APIs: `GetAuraInfo()`, `GetAuraSourceSpellID()`, `GetAuraTags()`, `AuraHasTag()`

## [1.0.19] - 2026-01-29

### Added

- **Combo Points Display** for Rogues and Feral Druids
  - 5 horizontal bars displayed below the resource bar
  - Rogues: Always visible when you have a target
  - Druids: Only visible while in Cat Form
  - Subtle scale animation when gaining combo points
  - Configurable width, bar height, and spacing in Options panel
- Shared bar utilities (CreateBarBorder, CreateBarGradient, FormatBarText, SmoothBarValue) extracted to Utils
- Shared glow utilities (GetLibCustomGlow, ShowButtonGlow, HideButtonGlow, ShowPixelGlow, HidePixelGlow) for cleaner module code
- Shared ConfigureCooldownText helper for OmniCC/ElvUI compatibility

### Changed

- Health bar, resource bar, and proc tracker now shift upward when combo points are visible
- Code consolidation reduces duplicate code across modules

## [1.0.18] - 2026-01-29

### Fixed

- **Targettarget Aura Support setting was never being read** - The setting path was incorrect, so enabling it had no effect. Now works correctly for healers using targettarget macros.
- Fixed Spell Configuration panel causing CPU spikes every second while open (replaced aggressive polling with OnShow refresh)
- Added `targettarget` to unit GUID lookup for accurate aura duration detection

## [1.0.17] - 2026-01-29

### Added

- **Smart Aura Target Resolution**: Aura tracking now intelligently selects the most relevant target
  - Hard CC (Polymorph, Fear, stuns) tracks across all targets
  - Hostile debuffs (DoTs) track only your current target
  - Helpful effects (buffs, heals) track appropriate friendly target
  - Soft CC (snares like Hamstring) follows normal debuff rules, not CC rules
- **Targettarget Aura Support** option: When targeting an enemy, shows your helpful effects on their target instead of yourself (useful for healers with targettarget macros)
- Completely rewrote README with improved structure and comprehensive documentation

### Fixed

- Lockout debuffs (Weakened Soul, Forbearance) now check the same target as the spell they restrict
- Fixed "permanent buff" glow appearing on debuffs (like Vampiric Embrace) when target was removed
- Fixed ready glow persisting after removing target while aura was active

### LibSpellDB Updates

- Vampiric Embrace now correctly tagged as debuff (was incorrectly tagged as buff)

## [1.0.16] - 2026-01-28

### Changed

- Dynamic Sort now deprioritizes conditional spells (Execute, Victory Rush, etc.) when they're not usable
- Unusable conditional spells sort after spells with cooldowns up to 60s, rather than always appearing first
- Welcome popup now shows `/vh` command earlier for faster onboarding

### Fixed

- Spell Configuration panel now correctly detects current spec when opened after a dual spec switch

## [1.0.15] - 2026-01-28

### Changed

- Target lockout debuffs (Forbearance, Weakened Soul) now show the **most restrictive** time remaining
- Example: Divine Shield (5min CD) with Forbearance (1min) shows the 5min CD since that's more restrictive
- Example: Avenging Wrath (ready) with Forbearance (1min) shows the 1min lockout

### LibSpellDB Updates

- Added Forbearance lockout tracking for Paladin immunity spells (Divine Shield, Divine Protection, Blessing of Protection, Avenging Wrath)

## [1.0.14] - 2026-01-28

### Added

- Dynamic Sort (Time Remaining) option for Primary and Secondary rows
- Icons reorder by "actionable time" (least time remaining first) so the ability needing attention soonest is always on the left
- Useful for DOT classes (see which debuff is expiring) and cooldown-heavy rotations

### LibSpellDB Updates

- **Critical Fix**: Bundled LibSpellDB now properly loads spell data. Previously, users who only downloaded VeevHUD from CurseForge had zero spells displayed because the embedded library wasn't loading its data files.

## [1.0.13] - 2026-01-28

### Fixed

- Out-of-combat alpha animation no longer gets stuck at very low values when fading to 0%

## [1.0.12] - 2026-01-28

### Added

- Icon Zoom setting (0-50%) to crop icon edges, similar to WeakAuras' zoom feature
- First-time welcome popup with Discord invite for new users
- Stack count text now renders above cooldown spiral for better visibility

### Changed

- Stack count text moved to top-right corner (consistent with proc tracker icons)
- Support link updated to Discord server ([https://discord.gg/HuSXTa5XNq](https://discord.gg/HuSXTa5XNq))

## [1.0.11] - 2026-01-28

### Added

- Icon Aspect Ratio setting for more compact HUD (Square, Compact 4:3, Ultra Compact 2:1)
- Icons shrink vertically while width stays the same, cropping textures proportionally
- Proc Tracker now supports tracking target debuffs (e.g., Deep Wounds)

### Fixed

- Spec detection now properly updates after respeccing at NPC
- Mortal Strike now prioritizes cooldown display over debuff tracking

### Changed

- Prompt for UI reload when changing aspect ratio with Masque installed (Masque requires reload for dynamic resizing)

### LibSpellDB Updates

- Added Deep Wounds proc tracking for Warriors (target debuff)
- Added `cooldownPriority` flag (renamed from `ignoreAura`) — shows cooldown/prediction first, then aura when ability is ready

## [1.0.10] - 2026-01-28

### Added

- Out of Combat Alpha setting to fade the entire HUD when not in combat
- Smooth fade animation when entering/leaving combat

## [1.0.9] - 2026-01-28

### Added

- Backdrop glow effect for active procs (soft halo behind icons)
- Animated pixel glow for active proc borders
- Smooth sliding animation when procs appear/disappear
- New Proc Tracker options: Icon Spacing, Gap Above Health Bar, Show Duration Text, Show Edge Glow, Backdrop Glow Intensity, Slide Animation

### Changed

- Proc icons now 26px by default (increased from 20px) for better visibility
- Duration text now displayed in center, stack count in top-right corner
- Duration text enabled by default
- Text renders above cooldown spiral for better readability
- Extracted shared text color (#ffe7be) to centralized constant

## [1.0.8] - 2026-01-27

### Changed

- Add buff/debuff caching to reduce aura scanning overhead (event-driven invalidation)

### LibSpellDB Updates

- Added `lib.Specs` constants for type-safe spec tagging
- All spells now have explicit `specs` field for better spec filtering

## [1.0.7] - 2026-01-27

### Added

- Built-in "Classic Enhanced" icon styling when Masque is not installed (uses same WoW game textures as Masque skin)

### Fixed

- Resource cost display now correctly uses action bar spell rank instead of base rank
- Mana abilities now properly desaturate when player lacks sufficient mana
- Improved caching for spell rank lookups with event-driven invalidation

### LibSpellDB Updates

- Added `GetAllRankIDs()` and `GetHighestKnownRank()` utility functions for accurate spell rank detection

## [1.0.6] - 2026-01-27

### Fixed

- Version display now dynamically reads from TOC file
- Updated changelog for CurseForge

## [1.0.5] - 2026-01-27

### Added

- Configurable "Dim on Cooldown" dropdown setting (None / Utility / Secondary+Utility / All)
- Right-click to reset any setting to default (with tooltip hint)

### Fixed

- Icon alpha now properly inherits to all child elements (resource fills, cooldown spirals, charges text)
- Aura glow respects icon alpha when Ready Alpha is reduced
- Version display now reads from TOC file

## [1.0.4] - 2026-01-26

### Fixed

- Debug logs only saved to SavedVariables when debug mode is enabled

## [1.0.3] - 2026-01-25

### Changed

- HUD is now fully click-through (no longer intercepts mouse clicks)
- Removed HUD dragging functionality (position controlled via Y-offset setting)

## [1.0.2] - 2026-01-25

### Added

- Secondary Row Gap setting (gap between Primary and Secondary rows)
- Ready glow now only initiates when player is in combat

### Fixed

- Charge Stun and Intercept Stun debuff tracking for Warriors

## [1.0.1] - 2026-01-24

### Fixed

- CurseForge publishing configuration for TBC Classic

## [1.0.0] - 2025-01-24

### Added

- Initial release
- Cooldown tracking with visual indicators
- Buff/debuff tracking with duration display
- Resource bar with cost preview
- Health bar with class coloring
- Proc tracking area for important buffs
- Ready glow for abilities coming off cooldown
- Cast feedback animations
- Full options panel with live-updating settings
- Support for all TBC Classic classes
- Masque skin compatibility

