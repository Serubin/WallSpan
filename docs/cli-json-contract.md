# The `--json` contract

`wallspan` is driven by other programs — the menu bar app, and anything else you point at
it — by spawning subcommands with `--json`. This is that interface.

The contract exists so the CLI and the app can be released on different schedules. The app
bundles a copy of the CLI but prefers whichever `wallspan` is on `PATH`, so **the parser is
routinely older than the binary it is parsing**. Every rule below follows from that.

## Envelope

Success is one object on stdout, exit 0:

```json
{ "schema": 1, "layout": { … } }
```

Failure is one object on stdout, exit non-zero:

```json
{
  "schema": 1,
  "error": { "code": "playlist_unreadable", "message": "permission denied: /Users/x/wp" }
}
```

stdout in both cases — one stream to read, with the exit status carrying success. Nothing
else is ever written to stdout under `--json`: prose commentary is suppressed, and a
subcommand with no defined payload rejects the flag rather than fall back to prose.

## Versioning

`schema` is a single integer.

- **Adding** a field, or a new `code`, does **not** bump it.
- **Removing** or **re-typing** a field does.

So a caller must:

- accept `schema >= 1`, never `schema == 1`;
- ignore keys it does not recognise;
- ignore `code` values it does not recognise, falling back to showing `message`.

`wallspan version --json` reports `commands`, the subcommands this binary accepts. Use it
to feature-detect rather than to compare version strings — that is what keeps additive
growth from needing a bump.

`channel` and `commit` say how the binary was built (`release`, `snapshot`, `dev`, or
`local` for an unstamped working tree) and which commit it came from. They exist so a bug
report names a tree rather than a version, and are for display only — a caller that gates
on `channel` strands anyone running a snapshot, which is exactly the audience most worth
hearing from. `commit` is empty for a local build.

Dates are ISO-8601 strings, not Foundation reference-date numbers.

## Commands

| command | payload key | notes |
|---|---|---|
| `version --json` | `version` | `{version, channel, commit, schema, commands[]}`. Also the probe. |
| `info --json` | `layout` | Same payload as `layout show --json`. |
| `layout show --json` | `layout` | Displays, union, gaps, coverage, fingerprint. |
| `layout list --json` | `sets` | Calibrated display combinations. `[]` when none — not an error. |
| `layout nudge\|set\|size\|reset --json` | `layout` | The state the edit produced. |
| `calibrate --json` | `layout` | Applies the test pattern, returns the layout it was drawn for. |
| `layout arrange --json` | `arrange` | Add `--dry-run` to preview, `--revert` to undo. |
| `config show --json` | `config` | |
| `config set … --json` | `config` | The state after the write. |
| `status --json` | `status` | Everything a status display needs. See below. |
| `pause --json` / `resume --json` | `config` | |
| `next --json` | `next` | `{pid, signal}`. The effect is async — poll `status` for it. |
| `apply <img> [--dry-run] --json` | `applied` | Per-display PNG paths and cache hits. |
| `restore --json` | `restored` | Plus `skipped`, for saved displays not attached now. |
| `agent status\|install\|uninstall --json` | `agent` | `program` is the binary the plist launches. |

`cycle`, `preview`, `selftest` and `verify-mapping` reject `--json`: either they are a
foreground log, or their result is a human judgement rather than an object worth pinning
down.

### `status`

Composed from three sources rather than read from one file: `status.json` says what the
cycler last did, `config.json` says what it is meant to do, and the cycle lock says whether
anything is actually doing it. A front-end reading only the file would show a confident
countdown for a cycler that died an hour ago.

- `running` — something holds the cycle lock. Covers a foreground `wallspan cycle` as well
  as the LaunchAgent, which `launchctl print` alone does not. The lock is probed, not
  inferred from a pid, so a stale lock file reads as "nobody" and a recycled pid cannot
  masquerade as a live cycler.
- `nextAt` — when the next change is due, already computed. `null` exactly when a countdown
  would be a lie: nothing running, paused, or nothing applied yet.
- `intervalSeconds` — a running cycler's *effective* interval, which is not always the
  config's: `cycle --interval 10m` overrides the file for that run.
- `lastError` — why the last tick failed, cleared by the next one that succeeds. This is how
  an unreadable playlist directory reaches a UI at all: the agent runs under launchd and
  cannot raise a TCC prompt, so without this the folder just appears to do nothing.

### Pause and next

`pause` is durable state in `config.json`, not a signal — `KeepAlive` respawns the agent, and
a signalled pause would not survive a crash or a logout. The running cycler notices within
five seconds; resuming changes the wallpaper immediately rather than waiting out the interval.

`next` is a signal (`SIGUSR1`), because "change now" has no durable meaning worth persisting.
It works while paused and leaves the pause in place: pause governs the schedule, not manual
control, so a front-end with both a pause switch and a Next button does not end up with a
Next that silently does nothing.

### Fields worth knowing

- `config.imageCount` — `null` means the directory could not be scanned at all
  (permissions, unmounted volume); `0` means it was read and held nothing. A front-end has
  to tell those apart before blaming an empty folder.
- `config.configPath` — where the settings live, for a "reveal in Finder" affordance.
- `layout.calibrated` — false while every gap is still zero, i.e. seeded from EDID but
  never measured.
- `layout.displays[].reportedSizeMM` — what the panel itself claims, beside `sizeMM`,
  which holds the corrected figure. They differ when a panel reported non-square
  pixels; showing both is what makes the correction overrulable.
- `layout.displays[].densitySuspect` — the size in use still implies non-square pixels,
  which after correction means it was set by hand.
- `gaps[].leftUUID` / `.rightUUID` — the names beside them are for display only. Two
  identical monitors report the same `localizedName`, so a caller mapping a gap back to a
  panel it can nudge must use the UUID. `layout nudge` accepts a UUID as well as an index
  or a name substring, and the UUID is the only form that cannot be ambiguous.
- `arrange.targets[].residualTopPt` / `.residualBottomPt` — panels of differing density
  cannot agree at every height, so some misalignment is irreducible and only movable. A
  caller should show it rather than imply the arrangement is exact.
- `arrange.applied` — false for `--dry-run` *and* when nothing needed changing. With one
  display attached, `targets` is empty and this is false; that is a normal answer, not an
  error.
- `agent.program` / `agent.programExists` — what the installed plist actually launches, and
  whether it is still there. Readable even when the agent is not loaded. Together they let a
  front-end tell "pointing at a different binary" from "pointing at nothing", which is the
  difference between offering to switch and having to repair. Point the agent somewhere
  specific with `agent install --binary <path>`, which stages no copy.

## Error codes

Codes are stable; `message` is not — never parse it.

| code | meaning |
|---|---|
| `bad_argument` | malformed or missing argument |
| `no_such_file` | a named path does not exist |
| `no_playlist_directory` | no cycling directory configured |
| `playlist_unreadable` | the directory could not be read — missing, not a directory, or denied |
| `playlist_empty` | read fine, no decodable images |
| `no_displays` | no displays attached |
| `no_calibration` | nothing calibrated for the displays attached now |
| `display_not_found` | a display query matched nothing, or was ambiguous |
| `no_saved_wallpaper` | nothing to restore |
| `agent_not_running` | the LaunchAgent is not loaded |
| `already_running` | another `cycle` holds the lock |
| `render_failed` | decode or render failed |
| `internal_error` | anything else — show `message`, do not branch on it |

## Checking it

`Scripts/check-json-contract.sh [binary]` asserts every supported command emits one
parseable envelope and every unsupported one refuses the flag. It accepts an `error`
envelope as a pass, because a machine with no attached display legitimately fails
`layout show` — the shape is what is being checked.

The mutating commands run only after it has *confirmed* the support directory redirected
into a scratch dir, by reading `config.configPath` back. `HOME` alone does not redirect it:
`NSSearchPathForDirectoriesInDomains` reads the passwd entry, so `CFFIXED_USER_HOME` is
what Foundation honours. Getting that wrong rewrites the invoking user's real settings and
wallpaper, which is why the check verifies rather than assumes.

## Example

```console
$ wallspan version --json
{
  "schema" : 1,
  "version" : {
    "channel" : "release",
    "commands" : [ "info", "apply", "preview", "cycle", … ],
    "commit" : "1a2b3c4",
    "schema" : 1,
    "version" : "0.1.0"
  }
}

$ wallspan apply /nope.jpg --json; echo "exit=$?"
{
  "schema" : 1,
  "error" : {
    "code" : "no_such_file",
    "message" : "no such file: /nope.jpg"
  }
}
exit=1
```
