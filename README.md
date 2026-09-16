# Caps lock indicator

A tiny bar widget that shows a single dot while [Caps Lock](https://en.wikipedia.org/wiki/Caps_lock) is on. No layout label, no click, no config required.

## Features

- One dot, zero text. Lights up in the bar's active color while Caps Lock is on, dims (or hides) when it's off.
- **Instant refresh with zero config**: the widget registers its own non-consuming `Caps_Lock` bind at runtime and re-asserts it after every config reload, so the dot responds the moment caps is pressed or released. No bind line for you to add.
- **Poll fallback**: a light 500 ms poll (only while the widget is visible) keeps the dot honest even if the bind can't be registered.
- Reads the Lock modifier from a real keyboard, not from Hyprland's radio controls, hotkey arrays, or the fcitx5 virtual keyboard, so it can't get stuck.
- Placement anywhere on the bar, per monitor, like any other bar widget.

## Install

```sh
omarchy plugin add <git-url-of-this-repo>
omarchy restart shell
```

Then add it to the bar and, if you like, move it anywhere:

```sh
omarchy bar add mero.caps-indicator
omarchy bar move mero.caps-indicator --section center
```

The plugin id is `mero.caps-indicator` (third-party, `firstParty: false`). With the widget on the bar you can also rely on it being registered even if your host config is Lua — nothing needs a bind or `keyword` line.

## Settings

All settings are optional and come with the defaults below. Change them in the bar widget settings panel or as inline keys on the bar entry.

| Key          | Type    | Default | Description |
| ------------ | ------- | ------- | ----------- |
| `dotColor`   | string  | `auto`  | Dot color while Caps Lock is on. `auto` uses the bar's active (urgent) color. Any CSS color, e.g. `#ff4444`. |
| `dotSize`    | integer | `6`     | Dot diameter in pixels. |
| `hideWhenOff`| boolean | `false` | Hide the dot entirely while Caps Lock is off instead of showing it dimmed. |
| `dimOpacity` | integer | `35`    | Dimmed brightness (0-100) of the dot while Caps Lock is off. |

Example inline settings on the bar entry:

```json
{
  "id": "mero.caps-indicator",
  "dotColor": "#ff4444",
  "dotSize": 8,
  "hideWhenOff": true
}
```

## How it stays instant

Caps Lock raises no Hyprland event, so the widget:

1. Registers a non-consuming, locked, ignore-mods bind on `Caps_Lock` (dispatcher: `omarchy-shell -q mero.caps-indicator refresh`) via `hyprctl eval`, exactly once per shell per config reload (`mero.caps-indicator` is a runtime-only binding id and is re-added when Hyprland reloads).
2. The bind invokes an IPC handler in the widget, which re-reads `hyprctl -j devices` a few times at short intervals to catch both the press (lock engages) and the release (lock disengages).
3. A 500 ms visible-only poll catches anything the bind missed (for example, if the eval bind is unavailable on an installed system).

## Compatibility & limits

- Requires Hyprland with the Lua config provider (the default on Omarchy), because bind registration uses `hyprctl eval`.
- Clicking the dot to toggle caps is intentionally **not** included in v1: Hyprland's synthetic key events (`send_key_state`/`send_shortcut`) do not flip the per-keyboard Lock state that this indicator reads, so a toggle feature would be unreliable. The dot is display-only.

## Development

- `omarchy plugin validate ./mero.caps-indicator` — manifest schema check.
- Files under `~/.config/omarchy/plugins/` hot-reload on save.
- `manifest.json` declares the `barWidget.schema` that drives the settings panel.

## Credits

Made by Mero J. Heavily inspired by Omarchy's built-in keyboard layout widget (from which the dot and the refresh mechanics are taken).