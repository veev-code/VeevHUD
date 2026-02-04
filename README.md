# VeevHUD

**A WeakAuras-inspired heads-up display for tracking cooldowns, buffs, debuffs, and resources.**

**Works out of the box** with intelligent defaults for every class and spec — no configuration required.

## Why VeevHUD?

*   **One addon, every class** — Tailored HUDs for all classes and specs, automatically
*   **Rotation-based layouts** — Spells organized by actual rotations, not arbitrary groupings
*   **Zero setup required** — Install and play; tweak later if you want
*   **Auto-updates** — Updates through your addon manager, no re-importing WeakAura strings
*   **Minimal, aesthetic design** — Every feature is designed to convey maximum information with minimum clutter.

---

## How It Works

VeevHUD displays your abilities in organized rows below your character:

*   **Primary Row** — Core rotation abilities you use on cooldown
*   **Secondary Row** — Throughput cooldowns, maintenance buffs/debuffs, AoE, and external cooldowns
*   **Utility Section** — Interrupts, CC, defensives, movement, and other situational abilities

Above the ability rows, you'll find **Health & Resource Bars** and a **Proc Tracker** for important buffs.

---

## Key Features

### Smart Aura Display

Icons don't just show cooldowns — they show your **applied effects**. Cast a stun? The icon displays the stun duration on your target, then transitions to the cooldown after it expires.

*   **Rotational abilities** follow your current target — DoTs track your enemy, heals track your friendly target (or yourself by default)
*   **Cooldowns and CC** always show when active, regardless of your current target
*   **Lockout awareness** — Lockouts from abilities like Power Word: Shield (Weakened Soul) and Paladin immunities (Forbearance) show whichever restriction is longer, so you always know when you can cast again
*   **Target-of-target support** — Healers can target the boss while tracking HoTs on the tank

### At-a-Glance Readability

Every visual element is designed to give you instant feedback:

*   **Resource cost display** — Icons show what percentage of required resources you have via a fill overlay or resource timer (see below)
*   **Usable glow** — A proc-style glow when abilities become usable (off cooldown + enough resources)
*   **Grey out** — Unusable abilities turn grey
*   **Range indicator** — Icons show a red overlay when your target is out of range
*   **Cast feedback** — A satisfying "pop" animation when you successfully cast
*   **GCD display** — Global cooldown shown on primary abilities

### Resource Timer (Energy/Mana)

A unique feature that **extends the cooldown spiral to show when you'll actually be able to cast** — factoring in both the cooldown AND resource regeneration.

Instead of seeing an ability go "ready" when you can't afford it, the icon shows a unified timer counting down to when you'll have enough resources. This transforms resource management from mental math into visual intuition.

*   **Energy** — Highly accurate tick-aware predictions for rogues and feral druids
*   **Mana** — Tracks the 5-second rule and adjusts predictions based on your actual regen rates
*   **Rage** — Uses a fill overlay instead (rage generation is inherently unpredictable)

### Dynamic Sort

Enable dynamic sorting to have icons **reorder by time remaining** — the ability needing attention soonest is always on the left.

*   **DOT classes** — See which debuff is closest to expiring
*   **Cooldown-heavy rotations** — See which ability comes off cooldown next

Arrange your row as a priority order and the leftmost icon is always the next best spell to cast.

Dynamic Sort is disabled by default.

### Proc Tracker

Small icons above the health bar for important temporary buffs: Enrage, Flurry, Clearcasting, and more. They appear only when active.

### Health & Resource Bars

Compact bars positioned with your HUD show health and mana/rage/energy at a glance.

*   **Combo Points** — Rogues and Feral Druids see combo point bars below the resource bar
*   **Energy Tick Indicator** — Shows progress toward the next energy tick via a spark overlay or ticker bar
*   **Mana Tick Indicator** — Shows when your next full spirit regen tick will arrive, accounting for the 5-second rule

---

## Configuration

VeevHUD is designed to work great out of the box, but nearly everything is configurable:

*   **Icon appearance** — Size, aspect ratio (square, 4:3, 2:1), spacing, opacity
*   **Visual feedback** — Glow behavior, animations, text display, per-row control
*   **Per-spell control** — Enable/disable spells, move them between rows, adjust priority
*   **Masque support** — Compatible with Masque for button theming

Access settings via **/vh** in chat, or **ESC → Options → AddOns → VeevHUD**. Right-click any setting to reset it to default; modified settings are marked with a gold asterisk.

---

## Current Status

VeevHUD currently supports only **TBC Anniversary**. The addon was deliberately designed to be extensible: it pulls spell data from [LibSpellDB](https://www.curseforge.com/wow/addons/libspelldb), so future versions can support additional Classic-era releases by providing a spell database for that version — the HUD engine remains the same.

Note: Due to recent addon restrictions in Retail (addons can no longer read most in-combat information), a Retail version is unlikely without substantial changes by Blizzard.

---

## Feedback & Contributions

VeevHUD is actively developed and your feedback helps improve it. If you find missing spells, miscategorized abilities, or edge cases, please report them — or just drop by to share suggestions.

Join the **Veev Addons Discord**: [https://discord.gg/HuSXTa5XNq](https://discord.gg/HuSXTa5XNq)

---

## Tip: HD Icons

For crisp, high-resolution spell icons, install **[Clean Icons - Mechagnome Edition](https://www.wowinterface.com/downloads/info25064-CleanIcons-MechagnomeEdition.html)**. This texture replacement pack works at the game level, so VeevHUD displays the sharper versions automatically.