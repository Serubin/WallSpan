# wallspan

A replacement for aging paid alternatives for applying multi monitor spanning wallpapers.

macOS only. No dependencies, no network access, no telemetry, no subscription.

## What it does

- **Spans one wallpaper across all your displays** as a single continuous image.
- **Compensates for bezels**, so the picture lines up to your eye rather than merely
  lining up in macOS's coordinate space.
- **Corrects for panels of differing pixel density**, so an image is the same real-world
  size on each screen.
- **Cycles a folder** on an interval, optionally running unattended in the background.

## Usage

```sh
wallspan info                                  # your displays, and how they're mapped
wallspan preview img.jpg -o out.png            # see the crop without touching anything
wallspan apply img.jpg                         # span it across every display
wallspan apply img.jpg --dry-run               # render only, change nothing
wallspan cycle ~/Pictures/Backgrounds --interval 15m
wallspan restore                               # back to your previous wallpaper
```

Once something is cycling, drive it without stopping it:

```sh
wallspan status                                # what is on screen, and what is next
wallspan next                                  # change now
wallspan pause                                 # stop changing; the setting sticks
wallspan resume
```

`pause` is a setting rather than a signal, so it survives a reboot and the agent
restarting. `next` works while paused and leaves it paused: pausing stops the schedule,
not the button.

`apply` saves your existing wallpaper the first time it runs, so `restore` always returns
to what you had before wallspan, not to whatever it set most recently.

To keep it cycling in the background and across logins, see
[Running unattended](#running-unattended).

## The menu bar app

`Wallspan.app` is a menu bar item for people who would rather not use a terminal: it shows
what is on screen and when it changes next, and offers Next, Pause, a folder picker, an
interval, and Restore.

```sh
Scripts/make-app.sh          # builds dist/Wallspan.app
open dist/Wallspan.app
```

It is a wrapper, not a second implementation — it spawns `wallspan` and reads its `--json`
output, and contains no wallpaper logic of its own. So it prefers whichever `wallspan` is
on your `PATH` and falls back to the copy inside the bundle, which means updating the CLI
updates the app's behaviour with no new app. **About Wallspan** shows which one is in use;
`defaults write net.serubin.wallspan.app PreferBundledCLI -bool true` pins it to the bundle.

The contract between them is [documented](docs/cli-json-contract.md) and versioned, so the
two can be released independently.

Two switches, deliberately separate. **Cycle in the Background** installs the LaunchAgent
described below, pointed at the binary the app resolved; cycling then continues after you
quit the app, which is the intent rather than a bug. **Open Wallspan at Login** only brings
the menu bar item back.

If the agent is left pointing at a binary that no longer exists — you moved the app out of
Downloads, say — the app repairs it on the next launch. If it points at a different but
working copy, the app leaves it alone and offers to switch instead.

**Install Command Line Tool…** symlinks the bundled CLI into `~/.local/bin`, so `wallspan`
works in a terminal too. A symlink rather than a copy, so it tracks the app.

### Calibrating from the app

**Displays ▸ Calibrate…** opens a window that does the bezel measurement described below
without the terminal. It puts the test pattern on your screens, and the arrow keys move
the selected panel — the judgement still happens by eye, across the bezel, so the window
stays small and out of the way. Gap readouts update as you go; the pattern follows a moment
later, once you stop pressing.

Two controls, because there are two ways to be wrong. **Arrow keys** move a panel, in
pixels — diagonals breaking across the bezel mean the position is off. **Panel scale**
changes its density, in PPI — circles breaking while the diagonals line up mean the scale
is off, and no amount of nudging fixes that.

It pauses cycling while it is open and resumes when you close it — unless you had already
paused it yourself, in which case it leaves it alone.

## Running unattended

```sh
wallspan config set --dir ~/Pictures/Backgrounds --interval 15m
wallspan agent install
wallspan agent status
wallspan agent uninstall
```

`agent install` sets it up as a login item, so it also re-applies your wallpaper each time
you log in. It has to be a background agent rather than a cron job: setting the desktop
picture requires a graphical login session, which cron does not have.

Settings live in `~/Library/Application Support/wallspan/config.json`, not in the agent's
configuration, so retuning is just an edit:

```json
{
  "intervalSeconds" : 900,
  "playlistDirectory" : "/Users/you/Pictures/Backgrounds",
  "recursive" : false,
  "shuffle" : true
}
```

A running agent notices changes within a few seconds — `wallspan config set --interval
30m` takes effect without a restart. Logs go to `~/Library/Logs/wallspan.log`.

If the folder lives on an external or network volume that is not mounted yet at login,
the agent waits and retries rather than giving up.

## Bezel compensation

Monitors have bezels. macOS places displays edge to edge and gives you no way to describe
the gap, so content that should be hidden behind the bezels gets squeezed into view
instead — and a spanned image looks subtly wrong even though it is technically correct.

wallspan models each panel's active area in millimetres, so bezel gaps become real dead
space: content there is rendered and discarded, which is what makes the picture read as
continuous.

```sh
wallspan calibrate                                  # apply a test pattern
wallspan layout nudge dell --dx 20px --dy -4px      # adjust
wallspan calibrate                                  # look again
wallspan layout show
wallspan layout reset                               # start over, edge to edge
```

Calibrate by eye against the long diagonals in the test pattern. Your eye is extremely
good at spotting a break in a straight line — far better than judging a gap width. If the
diagonals step **down-right** across the seam, the gap is too small; **up-right** means too
large. The red horizontal rules isolate purely vertical error, and the 10 mm grid is a
scale reference you can check against a tape measure.

The whole lattice is pinned to the centre of your main display, so the bullseye and the
diagonal crossing on it stay put while you move the other panels around them.

### Panel sizes, and why they need correcting

macOS reports each panel's physical size from EDID, and monitors frequently report it
wrong. One LG here claims 801.6 x 329.5 mm for a 3440x1440 panel - 109 PPI across but 111
PPI down. No flat panel has non-square pixels, so at least one of those numbers is false.
Left alone, a feature crossing the seam drifted 31 px.

wallspan corrects this without asking. The per-axis figures are untrustworthy but the
*diagonal* survives - EDID's base block stores size in whole centimetres, which moves each
axis by up to 5 mm while barely moving the diagonal - so it keeps the diagonal and imposes
the pixel aspect ratio, giving the one square-pixel rectangle that fits. Across panels from
14" to 49" that drives anisotropy to zero every time and roughly halves the mean error,
and where the reported size was already square it changes nothing.

`wallspan layout show` says when it has corrected a panel, and what the panel claimed.

What no amount of inference can find is a size wrong in *both* axes by the same
proportion: that is a pure scale error and EDID looks entirely self-consistent. It shows up
as circles that break across the seam while the diagonals line up. Dial it out by eye:

```sh
wallspan layout size lg --ppi 109.6      # or --scale 100.6
wallspan layout size lg --width 797.22mm # if you have the spec sheet
```

### Aligning the displays

System Settings only lets you *drag* display rectangles, which is too coarse to line up
panels of different heights — and that arrangement is what decides where your cursor
crosses between screens. `layout arrange` pushes the calibration into macOS with exact
precision:

```sh
wallspan layout arrange
wallspan layout arrange --dry-run
wallspan layout arrange --revert
```

Vertical only: macOS requires displays to be contiguous, so a bezel gap cannot be
expressed in the arrangement at all. Applied permanently, with your previous arrangement
saved so `--revert` always works.

Some residual misalignment is unavoidable when panels differ in density — macOS's
coordinate space has no notion of physical size, so one point cannot mean the same
distance on both screens. wallspan matches at the centre of the shared overlap to halve
the worst case, and prints what remains.

### Checking your calibration

```sh
wallspan verify-mapping <image|directory>   # exact check, valid at any bezel gap
wallspan selftest                           # proves the geometry (needs 2+ displays)
```

`verify-mapping` works backwards from the rendered output: for each sampled pixel it
computes which source pixel should be there, and compares. Real photographs come back at
0–0.05% mismatch.

## Build

```sh
swift build -c release
./.build/release/wallspan info
```

Needs only the Swift toolchain from Command Line Tools — no Xcode, no code signing.

## Known limits

- **Per-Space wallpaper.** macOS keeps a separate wallpaper per Space, and setting one only
  affects the Space you are currently on. `cycle` works around this by re-applying the
  current image whenever you switch Spaces, so each Space catches up on arrival — but a
  one-shot `wallspan apply` exits and cannot, so it reaches only the Space you ran it from.
- **Only one `cycle` runs at a time.** A second one exits immediately naming the pid that
  holds the lock, rather than fighting over the wallpaper and the saved playlist position.
- **The render cache never evicts.** Every image-and-arrangement pair keeps full-size PNGs
  under `~/Library/Application Support/wallspan/rendered`, and rearranging displays
  re-renders under a new key. Safe to `rm -rf` at any time.
- **Strict union mapping discards image.** Content that falls outside any panel — behind
  bezels, or above and below a shorter screen — is not shown. With an ultrawide beside a
  portrait panel that can be roughly a third of the source. `wallspan layout show` prints
  the figure.
- An image that already matches one display exactly gets scaled and cropped anyway, since
  it is mapped across the whole arrangement.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Copyleft, deliberately: anyone may use, modify or sell this, but anyone who distributes it
must make the full source available under the same terms. It cannot be turned into a
closed paid product — which is exactly what happened to the tools it replaces.

No code was taken from any existing product. wallspan is written from scratch against
public AppKit APIs.

## Acknowledgement

Made and maintained by a 15-year software veteran with the help of AI.
