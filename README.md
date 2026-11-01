# Dynamic brightness

Dims a monitor when it shows bright content and gives the brightness back when
the content goes dark, per monitor.

It was written for a mini-LED panel that was blinding on a white web page and
too dim on a dark editor at any fixed brightness. It works with any monitor
that accepts DDC/CI brightness commands, and with laptop panels.

## Platforms

| Platform | Status | Engine |
|---|---|---|
| Omarchy 4 (Hyprland) | working: shell plugin at the root of this repo | [wluma](https://github.com/maximbaz/wluma) |
| Other Linux desktops, macOS, Windows | planned | per platform |

On Omarchy the measuring and the brightness writes are done by wluma. The
plugin adds a bar button with an on/off switch and a **Dynamic** slider for each
monitor, and keeps wluma's config in sync with your monitors when connectors get
renumbered or plugged in. The plugin lives at the repo root because
`omarchy plugin add` needs its `manifest.json` there; ports to other platforms
will go in their own directories.

What every port shares is the settings model below, so one settings file means
the same thing everywhere.

## Install

```bash
yay -S wluma
omarchy plugin add https://github.com/vantuan5644/dynamic-brightness.git --enable
```

`omarchy plugin add` installs plugins disabled so you can read the code first,
unless you pass `--enable`. `omarchy plugin enable vantuan5644.dynamic-brightness`
turns it on later. It puts a 󰃡 button in the right of the bar; move it with
`omarchy bar move vantuan5644.dynamic-brightness --section left`.

Requirements: Omarchy 4 (the Quickshell-based shell), wluma 5, `jq`.
External monitors need DDC/CI turned on in their OSD (most have it on by
default). Run `ddcutil detect` to check that yours responds.

## Use

Click the button, switch a monitor on, and drag **Dynamic**.

- Set the monitor's brightness the way you normally would (OSD, brightness
  keys, or Omarchy's Display panel), with dark content on screen. That is the
  brightness you get on black.
- **Dynamic** is how much is taken off that brightness on a fully white
  screen: 40 means a white page runs at 60% of your setting. Content in between
  is scaled linearly by its average whiteness. 0 turns the dimming off.
- Change the brightness at any time and wluma takes the new value as your
  setting.

While the panel is open, each enabled monitor shows the whiteness wluma
measures (`content`) and the brightness it is applying. Keyboard: arrows move,
Enter toggles, Left/Right change Dynamic in steps of 5.

The same settings are available from a terminal:

```bash
~/.config/omarchy/plugins/vantuan5644.dynamic-brightness/bin/dynamic-brightness status
.../bin/dynamic-brightness set DP-1 on strength=40   # connector or part of the name
.../bin/dynamic-brightness set "LG HDR" off
.../bin/dynamic-brightness restart                   # e.g. after updating wluma
```

Restart wluma with `restart` rather than `systemctl --user restart wluma`; see
"How it works" for why.

## Settings

`~/.config/dynamic-brightness/settings.json` (under `$XDG_CONFIG_HOME`):

```json
{
  "version": 1,
  "monitors": {
    "Invalid Vendor Codename - RTK 0x2775 0x20230923": { "enabled": true, "strength": 40 }
  }
}
```

- Keys are the monitor's full description (make, model, serial), so a setting
  follows a monitor when its connector changes from `DP-1` to `DP-3`. If two
  connected monitors have the same description, each key gets ` @<connector>`
  appended.
- `strength` is 0-90: the percentage taken off the brightness you set, on a
  fully white screen. The reduction scales linearly with how white the screen
  is, and black is never dimmed. Out-of-range or non-numeric values are clamped
  or replaced with the default (40) rather than passed on.

## How it works on Omarchy

- The plugin writes `~/.config/wluma/config.toml`. wluma only honours entries
  keyed by connector name, so the plugin's service regenerates the file on every
  monitor add/remove and restarts `wluma.service` when it changes. If a config
  the plugin did not write is there, it is backed up first.
- Each enabled monitor gets wluma's `manual` predictor with a point at every
  luma from 0 to 100: no reduction at black, `strength`% at white, and the
  straight line between them rounded to whole percents. Two end points would
  be enough on paper, but wluma blends points by inverse distance squared,
  which turns two points into an S-curve: at strength 70 it took 4% off at 20%
  white and 48% at 60%, so mid-grey content swung brightness about twice as
  hard as the line. wluma uses a point as is when the luma matches it exactly,
  and luma is always a whole percent, so with a point at every luma it follows
  the line exactly.
- Monitors you have not switched on get `enabled = false`, so wluma does not
  adopt them in its learning mode.
- wluma's gamma control is turned off for every monitor, because Wayland gamma
  is exclusive and Omarchy's night light (hyprsunset) needs it. wluma's own idle
  dimming is off too, since Omarchy has its own screensaver and lock.
- No ambient light sensor is used, even on laptops that have one, so a Dynamic
  value always means the same thing.
- Each enabled monitor gets `transition_ms = 4000`: a brightness change takes
  up to about four seconds, in as many steps as the monitor can take in that
  time. Released wluma ignores the key, makes every change in at most four
  steps however long the monitor takes for them, and can overshoot the last
  one. A `transition_ms` option and the overshoot fix are proposed upstream
  ([max-baz/wluma#189](https://github.com/max-baz/wluma/pull/189) and
  [#188](https://github.com/max-baz/wluma/pull/188)); until a release has
  them, build wluma from the
  [`transition-time` branch](https://github.com/vantuan5644/wluma/tree/transition-time)
  to get the fade.

wluma's manual mode remembers your brightness as "the brightness on black",
learned from the last brightness it was handed and the content at that moment.
It relearns that on every start from whatever is on the panel, which may
already be dimmed. Left alone, each restart over a white page would lower your
brightness, and switching a monitor on over a white page would raise it. So the
plugin records each monitor's undimmed brightness
(`~/.local/state/dynamic-brightness/anchors.json`) and, once a restarted wluma
has measured the screen, hands it the value that makes it learn that brightness
again. If you changed the brightness yourself since, your change wins. Switching
a monitor off hands it back at its undimmed brightness. The first time a monitor
is switched on, the brightness it has then becomes its setting.

## Caveats

- DDC/CI is slow, and some monitors store brightness in non-volatile memory
  on every write. Each wluma step is a DDC read and a write; on one mini-LED
  panel over raw DDC that took 0.8 s, so a four-second fade there is about
  five steps. A faster DDC path would give more, smaller steps in the same
  time.
- wluma's raw DDC access sometimes fails to read a monitor once and then
  recovers. Installing [ddcutil-service](https://github.com/digitaltrails/ddcutil-service)
  (`yay -S ddcutil-service`) makes it more reliable, and wluma uses it
  automatically when it is there.
- Brightness only goes down from your setting. Nothing brightens dark content
  beyond it; set your brightness for dark content.
- Monitors with local dimming or "dynamic contrast" turned on in their OSD do
  their own version of this. Turn that off if the two fight.

## Remove

```bash
omarchy plugin remove vantuan5644.dynamic-brightness
systemctl --user disable --now wluma.service
rm -r ~/.config/dynamic-brightness ~/.local/state/dynamic-brightness ~/.config/wluma/config.toml
```

## Development

`tests/run.sh` runs offline tests of the CLI against stubbed `hyprctl`, `wluma`
and `systemctl`; it does not touch real monitors. `omarchy plugin validate .`
checks the manifest. Changes to `bin/dynamic-brightness` apply on its next
run; QML changes need `omarchy restart shell` (a rescan did not pick them up
when the plugin directory was a symlink).

## License

MIT
