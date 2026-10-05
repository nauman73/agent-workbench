# ctx-watch

A per-turn readout of how full the context window is, and one nudge to save a handoff when it
reaches the point you would rather start fresh.

## The problem

You cannot see your context filling up in the VS Code extension.

- **Custom `statusLine` is unsupported there.** The setting works in the terminal CLI; the
  extension's webview has no notion of it, so a status line that prints `ctx: 31%` is invisible in
  the place you actually work.
- **The extension's own indicator is hidden until 50%.** That threshold is hardcoded, with no
  setting to lower it. If you start a fresh session somewhere around a quarter full — which is what
  keeps compaction from ever happening — the indicator has still not appeared by the time the
  decision matters.
- **Third-party context bars report the wrong session.** `ezoosk.claude-context-bar` shows a
  continuous percentage, but it reports across every session on the machine, including other VS Code
  windows, and times sessions out.

Even with a number in front of you, there is a second gap: a readout cannot speak. Noticing 26% and
*acting* on it are different things, and the one that gets skipped is the acting.

## What it does

Two hook events, one script.

| Event | Who sees it | What it does |
|---|---|---|
| `Stop` | you | prints a readout after the turn: `ctx 26% (259/980k)` |
| `UserPromptSubmit` | the model | injects an instruction to raise the handoff, in its own words |

Both are needed, and neither substitutes for the other. The `UserPromptSubmit` injection is
**model-facing only** — it renders nowhere in the VS Code UI, so it cannot serve as the readout. And
the readout is a string printed at you; it cannot make the agent offer anything.

The readout is **stepped**, not printed every turn. Below the switch point it appears when the
percentage crosses a 5% boundary; at or above it, every 1%. Nothing is printed when the bucket has
not changed, so the line shows up when the number is moving and stays out of the way when it is not.

The suggestion fires **once per crossing**. Going 24% → 26% fires it; 26% → 27% is silent; a
compaction down to 8% and a climb back to 25% fires it again. There is no state file — see
"Stateless, by design" below.

What the model receives is a request to mention the switch point in one sentence and offer the
[`session-handoff`](../skills/session-handoff/) skill, phrased as something you are free to decline.
It is not an instruction to save anything.

With `block` on (off by default), the `Stop` hook also ends the turn once per band at or above the
switch point, telling the model to act on the project's house rules, and the `UserPromptSubmit`
suggestion is switched off. It exists for session chaining, described in
[`docs/session-chaining.md`](../docs/session-chaining.md).

## Configuration

`ctx-watch.json`, resolved in this order — later layers override earlier ones, and any key may be
set at any layer:

```
defaults baked into the script          works with no config file at all
  → ~/.claude/ctx-watch.json            your personal default
    → <project>/.claude/ctx-watch.json  per-repo, committable
      → CTX_WATCH_* environment vars    transient override, mostly for testing
```

| Key | Env var | Default | What it does |
|---|---|---|---|
| `switchPoint` | `CTX_WATCH_SWITCHPOINT` | `25` | the percentage you consider "time for a fresh session" |
| `stepBelow` | `CTX_WATCH_STEPBELOW` | `5` | readout granularity below the switch point |
| `stepWithin` | `CTX_WATCH_STEPWITHIN` | `1` | readout granularity at or above it |
| `warn` | `CTX_WATCH_WARN` | `true` | `false` keeps the readout, drops the suggestion |
| `enabled` | `CTX_WATCH_ENABLED` | `true` | `false` silences both |
| `window` | `CTX_WATCH_WINDOW` | unset | force the denominator; skips the whole resolution ladder |
| `bandLabel` | `CTX_WATCH_BANDLABEL` | `— switch point` | appended to the readout at or above the switch point |
| `block` | `CTX_WATCH_BLOCK` | `false` | `true` makes the `Stop` hook block once per band at or above the switch point |
| `blockStep` | `CTX_WATCH_BLOCKSTEP` | `5` | band width for blocking, counted from the switch point |

`enabled: false` silences the block too. `switchPoint` is read as a whole number, rounded (`8.5`
becomes 8); a `blockStep` that is not a whole number of at least 1 falls back to 5.

A minimal file:

```json
{ "switchPoint": 25, "stepBelow": 5, "stepWithin": 1, "warn": true }
```

**The config must live in user or project space, never in the plugin folder.**
`${CLAUDE_PLUGIN_ROOT}` is replaced wholesale on `claude plugin update`. That is correct for the
script — it is code, and you want the new one — and destructive for a config file, which is your
edits. The same trap is documented for `smart-commit`'s saved conventions in
[`.claude-plugin/README.md`](../.claude-plugin/README.md).

`CLAUDE_CTX_WINDOW` is honoured as a silent alias for `CTX_WATCH_WINDOW`. It was the original
script's private convention, and its `CLAUDE_` prefix falsely implied an official Claude Code
setting — hence the rename.

## How the numbers are worked out

**The numerator** is the sum of `input_tokens`, `cache_read_input_tokens` and
`cache_creation_input_tokens` from the most recent `usage` record in the transcript tail. Checked
against Claude Code's own figure twice: 249,035 against 248,931, and 109,807 against 109,670 — both
inside 0.04%.

**The tail** is the last 256 KB of the transcript, read as bytes. When that is not enough — no
`usage` record, no turn start with an earlier one, or no `token_usage` attachment — the hook widens
the read once, to 2 MB.

**The denominator** is a ladder. First hit wins:

| # | Source | Quality |
|---|---|---|
| 1 | `window` config key / `CTX_WATCH_WINDOW` | exact |
| 2 | the `token_usage` attachment's `total` | exact |
| 3 | the `model` attachment's `identity.modelId`, through a size table | exact |
| 4 | `autoCompactWindow` from the settings chain | exact |
| 5 | the `model` pin in `settings.json`, through the size table | **estimate** |
| 6 | promotion to 1,000,000 when the count already exceeds the window | **estimate** |

When the window is an estimate the readout is marked with a tilde — `ctx 25% (250/1000k ~)` — so a
number you cannot fully trust never looks like one you can.

The size table is a **denylist** of 200K models with everything else assumed to be 1M, plus an
explicit `[1m]`-suffix rule checked first. A denylist ages better than an allowlist here: new
frontier models ship at 1M and need no entry, whereas an allowlist would silently mis-size every
model released after it was written.

Rungs 3 and 4 exist because neither hook payload carries the model or the window. The payload has
eight keys — `cwd`, `hook_event_name`, `permission_mode`, `prompt`, `prompt_id`, `scratchpad_dir`,
`session_id`, `transcript_path` — and the `Stop` payload is no richer. Everything else has to come
out of the transcript or the settings files, which is what the ladder is for.

### Optional: `CLAUDE_CODE_ENABLE_TOKEN_USAGE_ATTACHMENT`

Setting this environment variable makes Claude Code emit the `token_usage` attachment, which is
rung 2 — the exact window, direct from the source.

**This hook will never set it for you, and you probably do not need to.** The practical difference
is about half a percent: `25.6%` against 980,000 rather than `25.1%` against 1,000,000, because
rung 3 reports the model's nominal window while rung 2 reports what is actually left after Claude
Code's own overhead. Weigh that against what the flag costs: a `<system-reminder>` injected on every
turn forever, a permanent if small token charge, and an unmeasured change to how the model behaves —
none of which an installer asked for.

It is also undocumented, and could be renamed or withdrawn without notice. A hook that *depends* on
it would break; this one merely *benefits*, and drops to rung 3 if it disappears.

If you want it anyway, set it in your own environment. The hook will pick the attachment up on its
own, because it **detects by artifact, never by env var** — it looks for the attachment rather than
asking whether the flag is set. That stays correct whether the flag is global, per-project, set
inline, toggled mid-session, or withdrawn in a future release.

One related note: on an older Claude Code there is no `model` attachment either. It first appears in
transcripts dated 2026-09-09. Before that, the ladder falls through to rung 5 and every reading
carries a `~`. That is the graceful degradation working as intended, and the reason the marker
exists.

## Stateless, by design

The hook writes nothing and remembers nothing. Both the stepping and the once-per-crossing rule fall
out of arithmetic on the transcript: the current percentage against the percentage as at the
previous turn. Warn when `current >= switchPoint` **and** `previous < switchPoint`, and re-arming
after a compaction needs no special case at all.

"Previous" means the last `usage` record before the most recent **real** user message — one whose
content carries no `tool_result` block. The distinction matters more than it sounds: a single
session here had 11 real user turns against 28 tool-result ones, so comparing against the previous
*usage record* would have compared two API calls within the same turn and almost never fired.

When "previous" cannot be determined — a resumed session, a short tail, a compaction — the hook
**prints anyway**. One redundant suggestion is a far better failure than being blind at exactly the
moment the context moved sharply.

The block keeps no state either. Claude Code's `stop_hook_active` flag says whether this turn has
already been blocked, and the band arithmetic — the band now against the band at the previous turn
— says whether this turn entered a new one. Together they replace a "did I already ask" file.

## Safety

**The stdout rule is the whole of it.** On `UserPromptSubmit`, *any* stdout is injected into the
model's context as an instruction — there is no JSON envelope to get wrong, bare stdout is wrapped
automatically. Once this ships in a plugin it runs on other people's machines every single turn. So:

> Every failure path exits 0 with empty stdout. Diagnostics go to stderr, never stdout.

Everything is wrapped in one try/catch that writes to `[Console]::Error`. A missing transcript, an
unparsable one, an empty payload, an unknown event — each exits silently. Three tests assert it
directly, and it was confirmed incidentally when a malformed payload produced a stderr diagnostic
and nothing at all on stdout.

Beyond that: the hook reads the transcript and the config files, and writes no files anywhere. It
exits 0 unconditionally, so it can never surface as a hook failure.

The block is the one place the hook acts on a turn, and it is guarded:

- **Opt-in.** Nothing blocks unless `block` is `true`.
- **At most once per turn.** When `stop_hook_active` is true the turn has already been blocked, and
  the hook prints the readout only. The flag is compared with `true` exactly, so an absent flag
  never disables the block.
- **A notice, not an interruption.** The block fires even while background work runs, and its
  reason tells the model to finish the current step, that work included, before acting.
- **Nothing else on stdout.** The block is one JSON object and is the only stdout on that path.
  Every failure path still exits 0 with empty stdout.

Claude Code shows the block's reason labelled `Stop hook error:`. That label is its own wording for
any `Stop` block; the hook has not failed.

## Requirements and portability

**PowerShell, and Claude Code only.** These are two separate limits with two different answers,
and it is worth being clear about which is which:

- **PowerShell** is a property of this implementation. The script is PowerShell and the launcher is
  a `cmd`/`sh` polyglot. Windows ships PowerShell; Linux and macOS need PowerShell 7, which installs
  as `pwsh`. With it present the hook runs; without it the launcher finds nothing to start and exits
  silently, rather than raising an error every turn. On Windows the launcher prefers
  `powershell.exe`; everywhere else it tries only `pwsh` — including WSL, which puts the Windows
  `PATH` on its own and would otherwise find a `powershell.exe` that can read neither a Linux script
  path nor a Linux transcript.
- **Claude Code** is not liftable by anyone. A hook is executed by the harness, not read by the
  model, so it exists only where that harness does. This is the sharp difference from a skill: a
  skill is portable markdown any agent can read.

Within Claude Code, **only the plugin install delivers this hook.** The other install routes carry
skills alone. Nothing scans `~/.claude/hooks/` — that folder is pure convention — and
`hooks/hooks.json` is read for plugins only. The registration for a local install lives in
`~/.claude/settings.json` and has to be written by hand. On Windows:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "\"%USERPROFILE%\\.claude\\hooks\\run-ctx-watch.cmd\"" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
                     "command": "\"%USERPROFILE%\\.claude\\hooks\\run-ctx-watch.cmd\"" } ] }
    ]
  }
}
```

On Linux and macOS, call `pwsh` directly instead of the launcher:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "pwsh -NoProfile -File \"$HOME/.claude/hooks/ctx-watch.ps1\"" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
                     "command": "pwsh -NoProfile -File \"$HOME/.claude/hooks/ctx-watch.ps1\"" } ] }
    ]
  }
}
```

The launcher adds nothing there, and a copy made by hand usually loses its executable bit, which
would make the shell refuse to run it.

What has been verified in a live session, and what has not:

| | Windows | Linux | macOS |
|---|---|---|---|
| Registered by hand in `settings.json` | verified | verified | not tested |
| Plugin install | not tested | not tested | not tested |

The plugin row rests on two things no live session has yet exercised: Claude Code resolving
`${CLAUDE_PLUGIN_ROOT}` in [`hooks.json`](hooks.json) and firing the hook from an installed plugin,
and — off Windows — the launcher running from the plugin's own folder. The launcher is stored as
executable so that a plugin install keeps the bit, and both of its branches reach PowerShell when
driven directly, but that is not the same as a live session. macOS runs the same `pwsh` as Linux,
with nothing platform-specific in the script.

That asymmetry is structural rather than an oversight:

| | Skills | Hooks |
|---|---|---|
| Local | drop a folder in `~/.claude/skills/` — auto-discovered | script anywhere + **registration in `settings.json`** |
| Plugin | a folder under `skills/` | a folder under `hooks/` + `hooks/hooks.json` |

A skill is self-describing, so one copy serves both worlds. A hook's *registration* lives outside
the hook locally and inside the plugin when packaged, and no amount of design removes that.

### The launcher is a polyglot on purpose

Claude Code may invoke a hook command through **either** `cmd.exe` or Git Bash on Windows. A
launcher that handled only one would no-op silently under the other — the worst possible failure for
a tool whose normal state *is* silence. So `run-ctx-watch.cmd` is both a batch file and a shell
script, and both branches reach PowerShell.

**It must keep LF line endings** for the shell branch to parse. The batch branch is therefore
written without parenthesised blocks or labels, which are the constructs `cmd.exe` mishandles in an
LF-only file. [`.gitattributes`](../.gitattributes) pins this; do not "fix" it to CRLF.

## How to work on it

`~/.claude/hooks/` is the source of truth, exactly as `~/.claude/skills/` is for skills. Edit the
live copy, run the tests there, then publish:

```powershell
& "$HOME/.claude/hooks/test-ctx-watch.ps1"   # 82 tests
./tools/sync-hook.ps1 -Check                 # drift, without writing
./tools/sync-hook.ps1                        # publish into hooks/
```

**Run the suite from a PowerShell prompt, not through a Bash shell.** Under Bash on Windows, the
child `powershell.exe` falls back to a legacy code page and replaces the em dash in the default
`bandLabel` with a plain `-`. Six stepping and warning tests, plus "works with no config file at
all", then fail for a reason that has nothing to do with the code.

**Never edit `hooks/` in this repo** — the next sync overwrites it without warning. `-Check` is
there to catch exactly that mistake, reporting `same` / `DIFFERS` / `MISSING IN REPO` /
`STALE IN REPO` per file.

Three files are synced because they run in both places: `ctx-watch.ps1`, `run-ctx-watch.cmd` and
`test-ctx-watch.ps1`. The harness sits *beside* the script deliberately, so running the live copy
tests the live script and running the repo copy tests the repo script. `hooks.json`, this README and
`.syncignore` are repo-owned, and are preserved across the sync's wipe-and-copy.

The test suite covers all six ladder rungs, the `~` marker, stepping above and below the band, the
real-user versus tool-result distinction, the crossing test including re-arming, all four config
layers, the tail read and its widening, the block's bands and guards, and every failure path
exiting silently with empty stdout. It passes on Windows; under `pwsh` on Linux it was last run
before the block was added. The launcher is not part of the suite; it has been driven by hand through
`cmd.exe`, through `sh` with `OS=Windows_NT` (the Git Bash path), and through `sh` with `OS` unset
(the path every other POSIX host takes), reaching PowerShell and printing the same readout each way.
