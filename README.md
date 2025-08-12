---

# BarBar (Beta)

BarBar is a fully configurable, **graphical action bar system** for Lich5.
It lets you create clickable buttons with custom icons, tooltips, timers, and state-based visuals — all set up through an **in-game GUI configurator**.

---

## Features

* Multiple bars with customizable size, position, and layout
* Button states that change automatically based on game conditions
* Built-in **timer overlay** for cooldowns and durations
* **Icon variants**: grayscale, solid borders, gradient borders, custom colors
* Category filters to organize buttons
* “Save All” configuration management
* **No YAML editing required** — all setup is handled in-game

---

## Installation

1. Download `barbar_beta.lic` and place it in your `lich5/scripts/` folder.
2. Place any **sprite maps** you want to use into:

   ```
   lich5/data/icons/
   ```
3. Launch the script in-game:

   ```
   ;barbar_beta
   ```

---

## Sprite Maps

* Sprite maps can be **any image size**.
* Each icon must be **64×64 pixels**.
* Icons should be **tiled without padding** between them.
* The **file name** (without `.png`) is used as the image name in the configurator.
* Icons are indexed left to right, top to bottom.

---

## Using the Configurator

Right-click any bar and choose **Configure BarBar** to open the GUI configurator.

The configurator has three main parts:

1. **Manage Buttons**

   * Create or edit button definitions.
   * Assign name, category, icon, variant styling, tooltip, and game commands.
   * Define multiple **states** for each button with their own condition and timer.

2. **Browse Icons**

   * View sprite maps and find icon numbers visually.

3. **Bar Settings**

   * Enable/disable the bar.
   * Set bar name, size, spacing, timer font size.
   * Choose which buttons appear on this bar.
   * Order buttons with ↑ / ↓ controls.

When you save a button definition, it will immediately be available for selection in bar settings.

---

## Conditions & Timers

Each button state has:

* **Condition** — A Ruby expression that decides when this state is active.
* **Timer** — A number of seconds remaining, shown as a countdown overlay.

BarBar evaluates conditions continuously; the first state whose condition returns `true` is the one displayed.

### Writing Conditions

Conditions can check anything the game exposes via Lich’s Ruby environment.
You can combine multiple checks with `&&` (and) / `||` (or).

**Examples:**

| Purpose                 | Condition                                       |
| ----------------------- | ----------------------------------------------- |
| Buff is active          | `Effects::Buffs.active?('Barkskin')`            |
| Buff is not active      | `!Effects::Buffs.active?('Barkskin')`           |
| Buff is on cooldown     | `Effects::Cooldowns.active?('Barkskin')`        |
| Spell 101 ready to cast | `Spell[101].affordable? && !Spell[101].active?` |
| At least 30 stamina     | `Char.stamina >= 30`                            |

---

### Writing Timers

The timer value determines the countdown shown on the button.
If set to `0`, no timer is displayed.

**Examples:**

| Purpose                   | Timer                                                            |
| ------------------------- | ---------------------------------------------------------------- |
| Time left on a buff       | `Effects::Buffs.expiration(/Barkskin/).to_i - Time.now.to_i`     |
| Time left on cooldown     | `Effects::Cooldowns.expiration(/Barkskin/).to_i - Time.now.to_i` |
| No timer (always ready)   | `0`                                                              |
| Fixed 10-second countdown | `10`                                                             |

---

## Icon Variants

You can visually change an icon without editing the image:

* **gs** — Grayscale
* **c\_XXXXXX** — Solid border (hex color)
* **cg\_XXXXXX\_YYYYYY** — Gradient border (top→bottom, hex colors)
* **bw\_N** — Border width (pixels)

These can be combined (e.g., `gs_c_00ff00_bw_3`).

All variant options are selectable in the configurator — no manual entry needed unless you want to type them directly.

---

## Tips

* Place most-specific conditions above more general ones — the first match wins.
* Keep categories consistent so you can filter and find buttons quickly.
* Use grayscale or colored borders to clearly indicate states like "ready," "active," or "cooldown."
* Tooltips can help you remember what a button does without cluttering the icon.

---

## Troubleshooting

* **Icons missing** — Make sure sprite map is in `lich5/data/icons/` and file name matches image name in configurator.
* **New button not in bar list** — Save the definition, then check bar settings for the button’s category.
* **Countdown not showing** — Ensure the timer field returns a positive number.

---
