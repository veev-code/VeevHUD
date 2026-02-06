# VeevHUD

**A WeakAuras-inspired heads-up display for tracking cooldowns, buffs, debuffs, and resources.**

**Works out of the box** with intelligent defaults for every class and spec — no configuration required.

## Why VeevHUD?

*   **One addon, every class** — Tailored HUDs for all classes and specs, automatically
*   **Rotation-based layouts** — Spells organized by actual rotations, not arbitrary groupings
*   **Zero setup required** — Install and play; tweak later if you want
*   **Auto-updates** — Updates through your addon manager, no re-importing WeakAura strings
*   **Minimal, aesthetic design** — Every feature is designed to convey maximum information with minimum clutter

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

*   **Resource cost display** — Icons show whether you can afford to cast via a fill overlay, bar, or resource prediction (see below)
*   **Usable glow** — A proc-style glow when abilities become usable (off cooldown + enough resources), with configurable persistent or one-shot modes
*   **Grey out** — Unusable abilities turn grey (desaturate)
*   **Range indicator** — Icons show a red overlay when your target is out of range, even during cooldown
*   **Cast feedback** — A satisfying "pop" animation when you successfully cast (configurable scale)
*   **GCD display** — Global cooldown shown on configurable rows
*   **Cooldown bling** — WoW's native sparkle effect when cooldowns finish (per-row configurable)
*   **Dim on cooldown** — Icons fade to a configurable alpha when on cooldown (per-row)
*   **Keybind text** — Optional keyboard shortcut display on icons (scans your action bars, supports Bartender4, ElvUI, Dominos)
*   **Summon stack count** — Spells that summon multiple pets (like Force of Nature) show how many remain alive

### Resource Prediction

A unique feature that **extends the cooldown spiral to show when you'll actually be able to cast** — factoring in both the cooldown AND resource regeneration.

Instead of seeing an ability go "ready" when you can't afford it, the icon shows a unified countdown to when you'll have enough resources. This transforms resource management from mental math into visual intuition.

Three resource display modes are available:

*   **Prediction** (Recommended) — Extends the cooldown sweep to include resource regeneration time. Energy and Mana predictions are highly accurate (tick-aware). Rage falls back to Fill since rage income is unpredictable.
*   **Fill** — Darkens the icon from top to bottom proportional to missing resources. Simple and easy to read.
*   **Bar** — Shows a small colored bar at the bottom of each icon that fills up as you gain resources.

### Dynamic Sort

Enable dynamic sorting to have icons **reorder by time remaining** — the ability needing attention soonest is always on the left.

*   **DOT classes** — See which debuff is closest to expiring
*   **Cooldown-heavy rotations** — See which ability comes off cooldown next

Arrange your row as a priority order and the leftmost icon is always the next best spell to cast. Includes optional smooth slide animation.

Dynamic Sort is disabled by default.

### Proc Tracker

Small icons above the health bar for important temporary buffs: Enrage, Flurry, Clearcasting, and more. They appear only when active, with configurable glows, backdrop halo, slide animations, and duration text.

### Health & Resource Bars

Compact bars positioned with your HUD show health and mana/rage/energy at a glance.

*   **Combo Points** — Rogues and Feral Druids see combo point bars below the resource bar
*   **Energy Tick Indicator** — Shows progress toward the next energy tick via a spark overlay or ticker bar. Supports powershifting and full-energy display.
*   **Mana Tick Indicator** — Shows when your next full spirit regen tick will arrive. Two modes: "Outside 5-Second Rule" (only during full regen) or "Next Full Tick" (recommended — always active, predicts first full tick after casting)

---

## Configuration

VeevHUD is designed to work great out of the box, but nearly everything is configurable. Settings are organized into tabs:

*   **General** — Position (horizontal + vertical offset), global scale, font, visibility (out-of-combat fade, hide on flight path), smooth bar/dim animations, layout spacing
*   **Icons** — Appearance (aspect ratio, zoom, spacing, gaps), alpha (ready/cooldown), cooldown display (text, spiral, bling, GCD, dim-on-cooldown), resource display (prediction/fill/bar), and behavior (aura tracking, cast feedback, ready glow, dynamic sort, range indicator, keybind text)
*   **Bars** — Proc tracker, health bar, resource bar (with energy ticker and mana ticker sub-tabs), and combo points — each with size, text format, gradient, spark, and class coloring options
*   **Rows** — Per-row settings for Primary, Secondary, and Utility: icon size, max icons, and flow layout (utility row wraps into multiple lines)
*   **Spells** — Per-spell control: enable/disable, move between rows, adjust priority order via drag-and-drop
*   **Profiles** — Save and switch between configuration profiles. Automatic per-spec profile switching via LibDualSpec (dual spec users get separate profiles for each spec).

Access settings via **/vh** in chat, or **ESC → Options → AddOns → VeevHUD**. Every setting shows its default value in the tooltip.

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
