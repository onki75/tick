# Tick

A floating circular timer and stopwatch for macOS. No Dock icon, no menu bar item: a small glowing ring
sits on top of your windows, you call it up with the keyboard, start it, and it hands focus back.
While the timer runs it can also keep you off distracting sites.

macOS 14 or later.

## Install

```sh
git clone https://github.com/onki75/tick.git
cd tick
./scripts/install.sh
```

`install.sh` builds Tick with `xcodebuild` (Xcode required), signs it ad hoc, and installs it to
`/Applications/Tick.app`. Re-running it updates the app.

### Option ×2 needs Accessibility permission

Pressing **Option twice** works from any app, which needs macOS **System Settings → Privacy & Security →
Accessibility** to allow Tick. Because the app is signed ad hoc, macOS treats every reinstall as a new app and
drops the permission: switch Tick off and on again (or remove and re-add it) in that list, then relaunch Tick.
Until then you can bring the timer forward by opening Tick from Spotlight or Raycast.

## Using it

Call the timer with **Option ×2**. It takes keyboard focus (the ring gets brighter). Press **Option ×2** again to
give focus back to the previous app.

| Key | Action |
| --- | --- |
| `Option` ×2 | Focus the timer / hand focus back to the previous app |
| `Space` | Start or pause. After starting, focus goes back to the previous app |
| Click | Click once to focus. Click again while focused to start or stop, and hand focus back |
| `Return` | Switch between timer and stopwatch |
| `Tab` | Enter a time. Type up to 4 digits (`mm:ss`, max 99:59); `Tab` again starts over; `Return` confirms; `Space` confirms and starts |
| `1` `2` `3` | Choose a preset while the timer is stopped (default 10 / 30 / 60 minutes) |
| `R` | Reset |
| Arrow keys, `h` `j` `k` `l` | Move the window; with `Shift`, snap to the screen edge |
| `,` `.` | Make the glow cooler (white) / warmer |
| `?` | Show or hide the key hints |
| `Esc`, `⌘W` | Hide the timer (a running timer keeps running; Option ×2 brings it back) |
| `⌘,` | Settings: presets and blocked sites |
| `⌘Q` | Quit |

When the timer ends it plays a sound. Focusing the timer or clicking it silences the alarm and resets it.

## Site blocking

While a timer or stopwatch is running, Tick blocks the sites in its list: YouTube, Instagram, TikTok and X by
default. Add more in **Settings** (`⌘,`); added sites apply from the next start. To remove one, edit
`~/Library/Application Support/Tick/blocklist.txt` (one host name per line).

Blocking works through `/etc/hosts`, so it needs a one-time setup that installs a small root-owned helper and a
`sudoers` rule allowing only that helper's `block` and `unblock`:

```sh
sudo ./scripts/setup-blocker.sh            # install
sudo ./scripts/setup-blocker.sh uninstall  # remove the helper and the rule
```

Read `scripts/setup-blocker.sh` and `scripts/tick-hosts` first; they are short. Without this setup Tick still
works as a timer, it just doesn't block anything.

Chrome and Safari keep open connections to a site, so an already open tab would not notice the block. Tick
therefore replaces such tabs with a plain black page (served from `tick.localhost`), moves the timer to the middle
of the screen over it, and puts the tabs back when the timer stops. This uses AppleScript, so macOS asks once
whether Tick may control the browser.

## Notes

- Pausing a timer lifts the block until you start again.
- The blocker never touches Claude or OpenAI domains, so coding assistants keep working.
- The timer fires up to 50 ms early; display is rounded to whole seconds.

## Layout

- `CircleTimer/`: the app (SwiftUI + AppKit). `AppDelegate.swift` holds the window, keys and site blocker,
  `TimerModel.swift` the timer state, `TimerFaceView.swift` the ring.
- `scripts/`: `install.sh`, `setup-blocker.sh`, `tick-hosts`.
- `Tick-icon.svg`: the icon source.
