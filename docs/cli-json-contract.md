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

Dates are ISO-8601 strings, not Foundation reference-date numbers.

## Commands

| command | payload key | notes |
|---|---|---|
| `version --json` | `version` | `{version, schema, commands[]}`. Also the probe. |
| `info --json` | `layout` | Same payload as `layout show --json`. |
| `layout show --json` | `layout` | Displays, union, gaps, coverage, fingerprint. |
| `layout list --json` | `sets` | Calibrated display combinations. `[]` when none — not an error. |
| `layout nudge\|set\|size\|reset --json` | `layout` | The state the edit produced. |
| `calibrate --json` | `layout` | Applies the test pattern, returns the layout it was drawn for. |
| `layout arrange --json` | `arrange` | Add `--dry-run` to preview, `--revert` to undo. |
| `config show --json` | `config` | |
| `config set … --json` | `config` | The state after the write. |
| `apply <img> [--dry-run] --json` | `applied` | Per-display PNG paths and cache hits. |
| `restore --json` | `restored` | Plus `skipped`, for saved displays not attached now. |
| `agent status\|install\|uninstall --json` | `agent` | `program` is the binary the plist launches. |

`cycle`, `preview`, `selftest` and `verify-mapping` reject `--json`: either they are a
foreground log, or their result is a human judgement rather than an object worth pinning
down.

### Fields worth knowing

- `config.imageCount` — `null` means the directory could not be scanned at all
  (permissions, unmounted volume); `0` means it was read and held nothing. A front-end has
  to tell those apart before blaming an empty folder.
- `config.configPath` — where the settings live, for a "reveal in Finder" affordance.
- `layout.calibrated` — false while every gap is still zero, i.e. seeded from EDID but
  never measured.
- `layout.displays[].densitySuspect` — EDID implies non-square pixels, so `layout size` is
  worth running.
- `agent.program` — what the installed plist actually launches, readable even when the
  agent is not loaded. This is how a front-end notices an agent left pointing at a moved
  or deleted binary.
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
- `agent.program` — what the installed plist actually launches, readable even when the
  agent is not loaded. This is how a front-end notices an agent left pointing at a moved
  or deleted binary.

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
    "commands" : [ "info", "apply", "preview", "cycle", … ],
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
