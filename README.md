# Keyboard lock indicators

A tiny bar widget that shows lock indicators for [Caps Lock](https://en.wikipedia.org/wiki/Caps_lock) and Num Lock. No layout label, no click, no config required.

## Features

- Two compact letters: `C` for Caps Lock and `N` for Num Lock. Each lights up in its configured color while that lock is on; inactive letters remain in the normal bar foreground color.
- **Instant refresh with zero config**: the widget registers its own non-consuming `Caps_Lock` and `Num_Lock` binds at runtime and re-asserts them after every config reload. No bind line for you to add.
- **Poll fallback**: a light 2-second poll (only while the widget is visible) keeps the indicators honest even if an event is missed.
- Reads lock modifiers from real keyboards, not from Hyprland's radio controls, hotkey arrays, mice, audio devices, or the fcitx5 virtual keyboard.
- Placement anywhere on the bar, per monitor, like any other bar widget.

## Install

```sh
omarchy plugin add <git-url-of-this-repo>
omarchy restart shell
```

Then add it to the bar and, if you like, move it anywhere:

```sh
omarchy bar add kansoit.keyboard-locks
omarchy bar move kansoit.keyboard-locks --section center
```

The plugin id is `kansoit.keyboard-locks` (third-party, `firstParty: false`). With the widget on the bar you can also rely on it being registered even if your host config is Lua — nothing needs a bind or `keyword` line.

## Omarchy keyboard configuration

This setup removes `compose:caps` from the user's Hyprland input options and
keeps `shift:both_capslock_cancel`. The override lives in
`~/.config/hypr/input.lua`, not in the plugin. It restores the Caps Lock key as
a normal Caps Lock key; `compose:caps` would otherwise turn that key into a
Compose key and the indicator would correctly report Caps Lock as inactive.

The logical lock state shown in the bar can be synchronized across the real
keyboards, while a Logitech keyboard's physical Caps Lock LED may remain out
of sync when the lock is changed from another keyboard. That is a HID/firmware
LED limitation, not a bar indicator state error.

## Settings

All settings are optional and come with the defaults below. Change them in the bar widget settings panel or as inline keys on the bar entry.

| Key          | Type    | Default | Description |
| ------------ | ------- | ------- | ----------- |
| `capsColor`  | string  | `auto`  | Caps Lock letter color. `auto` uses the active theme accent color. Any CSS color, e.g. `#ff4444`. |
| `numColor`   | string  | `auto`  | Num Lock letter color. `auto` uses the active theme accent color. Any CSS color, e.g. `#44aaff`. |

Example inline settings on the bar entry:

```json
{
  "id": "kansoit.keyboard-locks",
  "capsColor": "#ff4444",
  "numColor": "#44aaff"
}
```

## How it stays instant

The widget uses lock-key events as the fast path and keeps a slower fallback poll:

1. Registers non-consuming, locked, ignore-mods binds on `Caps_Lock` and `Num_Lock` (dispatcher: `omarchy-shell -q kansoit.keyboard-locks refresh`) via `hyprctl eval`.
2. Either bind invokes an IPC handler in the widget, which re-reads `hyprctl -j devices` a few times at short intervals so the published modifier state has time to settle.
3. A 2-second visible-only poll catches anything the events missed, including changes made by another input tool or systems where the eval bind is unavailable.

## Compatibility & limits

- Requires Hyprland with the Lua config provider (the default on Omarchy), because bind registration uses `hyprctl eval`.
- Clicking the letters to toggle locks is intentionally **not** included: Hyprland's synthetic key events (`send_key_state`/`send_shortcut`) do not flip the per-keyboard Lock state that this indicator reads, so a toggle feature would be unreliable. The widget is display-only.
- Caps Lock and Num Lock are per-keyboard: with several keyboards connected, the widget lights the corresponding indicator when the lock is active on any real keyboard. It still tracks the keyboard being typed on for event settling, but no longer hides a lock that remains active on another keyboard.

## Development

- `omarchy plugin validate ./kansoit.keyboard-locks` — manifest schema check.
- Files under `~/.config/omarchy/plugins/` hot-reload on save.
- `manifest.json` declares the `barWidget.schema` that drives the settings panel.

## Credits

Made by gpt5.6-luna. Heavily inspired by Omarchy's built-in keyboard layout widget (from which the refresh mechanics are taken).
