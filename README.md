# VeevHUD

**A WeakAuras-inspired heads-up display for tracking cooldowns, buffs, debuffs, and resources.**

**Works out of the box** with intelligent defaults for every class and spec — no configuration required. But when you want control, VeevHUD offers **deep customization** for nearly every visual element.

## Why VeevHUD?

*   **One addon, every class** — Tailored HUDs for all classes and specs, automatically
*   **Rotation-based layouts** — Spells organized by actual rotations, not arbitrary groupings
*   **Zero setup required** — Install and play; tweak later if you want
*   **Auto-updates** — Updates through your addon manager, no re-importing WeakAura strings

---

## How It Works

VeevHUD displays your abilities in organized rows below your character:

*   **Primary Row** — Core rotation abilities you use on cooldown
*   **Secondary Row** — Throughput cooldowns, maintenance buffs, situational abilities
*   **Utility Section** — Interrupts, CC, defensives, movement, and more

Above the ability rows, you'll find **Health & Resource Bars** and a **Proc Tracker** for important buffs.

---

## Key Features

### Smart Aura Display

Icons don't just show cooldowns — they show your **applied effects**. Cast a stun? The icon displays the stun duration on your target, then transitions to the cooldown after it expires.

*   **Hard CC** (Polymorph, Fear, stuns) tracks the longest duration across all targets — important since these have cooldowns or limits
*   **Damage effects** (DoTs, debuffs) track only your current target, avoiding confusion with multi-dotting
*   **Buffs and heals** track the appropriate friendly target — yourself, or your ally if you're targeting them
*   **Lockout awareness** — Abilities like Power Word: Shield (Weakened Soul) and Paladin immunities (Forbearance) show whichever restriction is longer, so you always know when you can cast again

### At-a-Glance Readability

Every visual element is designed to give you instant feedback:

*   **Resource cost display** — Icons show what percentage of required resources you have via a fill overlay
*   **Ready glow** — A proc-style glow when abilities become usable (off cooldown + enough resources)
*   **Desaturation** — Unusable abilities turn grey, mimicking default action bar behavior
*   **Cast feedback** — A satisfying "pop" animation when you successfully cast
*   **GCD display** — Global cooldown shown on primary abilities

### Dynamic Sort (Optional)

Enable dynamic sorting to have icons **reorder by time remaining** — the ability needing attention soonest is always on the left.

*   **DOT classes** — See which debuff is closest to expiring
*   **Cooldown-heavy rotations** — See which ability comes off cooldown next
*   **Smart tie-breaking** — When multiple abilities are ready (or have equal time), they sort by their original row position. Arrange your row as a priority order and the leftmost icon is always the next best spell to cast.

Icons slide smoothly to new positions (or snap instantly if you prefer). Off by default.

### Proc Tracker

Small icons above the health bar display important temporary buffs: Enrage, Flurry, Clearcasting, and more. They appear only when active, with optional duration text and glow effects.

### Health & Resource Bars

Compact bars positioned with your HUD show health and mana/rage/energy at a glance. Class-colored options, text overlays, and smooth animations included.

---

## Deep Customization

VeevHUD works great with defaults, but nearly everything is configurable:

**Icon Appearance**
*   Size, aspect ratio (square, 4:3, 4:2), spacing, zoom level
*   Alpha levels for ready vs. on-cooldown states
*   Cooldown text and spiral display (per-row control)

**Visual Feedback**
*   Ready glow mode (once per cooldown, always, or disabled)
*   Cast feedback animation scale
*   Dim on cooldown (control which rows fade)
*   GCD display (control which rows show it)

**Aura Tracking**
*   Toggle buff/debuff display on icons
*   Targettarget support for healers (target the boss, see your HOTs on the tank)

**Dynamic Sort**
*   Enable for Primary, Primary + Secondary, or keep static
*   Smooth animation or instant snap

**Resource Display**
*   Vertical fill or bottom bar style
*   Control which rows show resource costs

**Health & Resource Bars**
*   Width, height, text format (current, percent, both)
*   Class coloring, spark effects, smooth animations

**Proc Tracker**
*   Icon size and spacing
*   Duration text, edge glow, backdrop glow intensity
*   Slide animation when procs appear/disappear

**Per-Spell Configuration**
*   Enable/disable specific spells
*   Move spells between rows
*   Adjust priority order within rows

**General**
*   Out of combat fade (adjustable alpha)
*   Hide on flight paths
*   Masque support for button themes

---

## Configuration

Access settings by typing **/vh** in chat, or via **ESC → Options → AddOns → VeevHUD**.

*   **Right-click** any setting to reset it to default
*   Modified settings are marked with a **gold asterisk**

---

## Current Status & Future Plans

VeevHUD currently supports **TBC Anniversary** only. However, VeevHUD is designed as a core engine that pulls spell data from [LibSpellDB](https://www.curseforge.com/wow/addons/libspelldb), a separate library. This architecture means future versions can support additional WoW releases (Classic Era, Wrath, Cata, Retail) by providing a spell database for that version — the HUD engine remains the same.

---

## Feedback & Bug Reports

Join the **Veev Addons Discord** for feedback, suggestions, and bug reports:
[https://discord.gg/HuSXTa5XNq](https://discord.gg/HuSXTa5XNq)

Since VeevHUD is new, there may be:
*   Spells missing or not properly categorized
*   Buffs/debuffs using different spellIds than the casting spell
*   Edge cases not yet encountered

Your feedback helps shape the addon's future!
