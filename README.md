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

`apply` saves your existing wallpaper the first time it runs, so `restore` always returns
to what you had before wallspan, not to whatever it set most recently.

To keep it cycling in the background and across logins, see
[Running unattended](#running-unattended).

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
wallspan layout nudge dell --dx 14mm --dy -3mm      # adjust
wallspan calibrate                                  # look again
wallspan layout show
wallspan layout reset                               # start over, edge to edge
```

Calibrate by eye against the long diagonals in the test pattern. Your eye is extremely
good at spotting a break in a straight line — far better than judging a gap width. If the
diagonals step **down-right** across the seam, the gap is too small; **up-right** means too
large. The red horizontal rules isolate purely vertical error, and the 10 mm grid is an
absolute reference you can check against a tape measure.

### If the picture looks slightly stretched

macOS reports each panel's physical size from EDID, and monitors frequently report it
wrong. `wallspan layout show` flags a panel whose numbers imply non-square pixels. Setting
the true dimensions from the spec sheet is the single highest-value calibration input:

```sh
wallspan layout size lg --width 797.22mm --height 333.72mm
```

On the setup this was developed against, that cut the residual misalignment from ±19.5 pt
to ±4.2 pt.

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
