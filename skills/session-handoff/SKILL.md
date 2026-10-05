---
name: session-handoff
description: Save or resume from a structured task-state snapshot under the project's .claude/ folder so work can carry across cleared/compacted Claude Code or GitHub Copilot sessions. Has two modes. SAVE mode — use when the user says "save the session", "save context", "create a handoff", "I need to /clear", "compact is coming", "snapshot this task", "checkpoint this work", "update the handoff", "refresh the snapshot", "save and open a new session" (it can launch the next session for them). RESUME mode — use when the user says "resume from the handoff", "pick up where we left off", "continue from .claude/handoff-...", "read the handoff and continue", "load the handoff", or opens a fresh session pointing at a `.claude/handoff-*.md` file. Optionally archives the full session transcript (Claude Code or GitHub Copilot chat) as a readable Markdown or raw JSONL file alongside the handoff. Do NOT use this for general memory/preferences (use persistent memory) or recurring scheduled work (use a scheduled-task mechanism).
---

# session-handoff

Capture the current task's state into a self-contained markdown doc that a future, context-less session can read to pick up exactly where this one left off.

## Why this exists

Agent sessions get cleared, compacted, or run out of context. The assistant's persistent memory captures durable facts about the user and project, but not in-flight task state. This skill writes a focused, time-stamped handoff for one specific task — goal, progress, next step, open questions — so a fresh agent can resume without the user re-explaining.

The skill runs the same way whether the live session is **Claude Code** or **GitHub Copilot** (which can now run Claude Code skills directly). The handoff save/resume logic is identical in both — it summarizes the session you are currently in. The one place the two environments differ is the optional transcript archive, because each stores its session JSONL in a different location and format; that step asks you which environment you are in.

## Two modes

This skill has two modes. Decide which one applies from the user's phrasing before doing anything else.

**SAVE mode** — write or update a handoff doc. Trigger when the user signals they want to preserve current task state:
- "save this session" / "save context" / "snapshot this"
- "I'm about to /clear" / "compact is going to hit" / "context is filling up"
- "checkpoint this work" / "I'll resume tomorrow" / "create a handoff"
- "update the handoff" / "refresh the snapshot" (update an existing doc)
- "save and open a new session" / "hand this over to a new session" (save, then launch the next session; see `references/session-chaining.md` → "Opening the next session when chaining is off")
- a ctx-watch block ("[ctx-watch] Context usage is …") in a session whose house rules turn chaining on (see `references/session-chaining.md`)

**RESUME mode** — load an existing handoff doc and prepare to continue. Trigger when the user signals they want to pick up prior work:
- "resume from the handoff" / "pick up where we left off"
- "read .claude/handoff-<slug>.md and continue"
- "load the handoff" / "continue from the snapshot"
- a fresh session that opens with a reference to a `.claude/handoff-*.md` path

If the user is just asking you to remember a preference or fact, that is the assistant's persistent memory's job, not this. If the user wants a recurring background task, that is a scheduled-task mechanism's job. This skill is specifically for "I want a future session to continue this exact task."

These two modes are the entire scope. Copilot support is **not** a third mode — it is the same SAVE and RESUME flows, which work identically inside a GitHub Copilot session (Copilot can run Claude Code skills). The only environment-dependent part is the optional transcript archive in SAVE mode, which is covered in its own section below.

## Where handoffs live

Write to `.claude/handoff-<slug>.md` relative to the project root. The project-local `.claude/` folder is the canonical place for project-scoped Claude artifacts (settings, allowlists, and now handoffs and their optional transcripts) — if it doesn't exist, create it. Note this is the *project's* `.claude/`, not the user-level `~/.claude/`; the two are distinct (see "Path qualification" below).

Use `.claude/` for both Claude Code and GitHub Copilot sessions. It is this skill's artifact folder regardless of which environment runs it; keeping one predictable location means RESUME never has to guess where a handoff lives, and the handoff flow never has to know which environment produced it.

The slug should be short, kebab-case, and describe the task — `auth-refresh-bug`, `phase-7-config`, `users-feature-cleanup`. Infer it from the conversation; only ask the user if you genuinely cannot tell what the task is about.

## Path qualification — every referenced file must be locatable

A handoff is read by a future session with no memory of where files live. A bare path like `.claude/foo.md` is ambiguous: is it under the project root, the user-level Claude folder, somewhere else? The risk is especially sharp now that handoffs live in the project's `.claude/` — the name is the same as the user-level `~/.claude/` and the two are easy to confuse. If the future session searches the wrong root, it wastes turns and may even silently work on the wrong file. Eliminate that ambiguity by qualifying every path you write.

Use these conventions consistently throughout the handoff:

- **Project files** — write project-relative paths as-is: `frontend/src/lib/api.ts`, `.claude/handoff-users-feature.md`, `backend/app/models/user.py`. These are the default and need no decoration; the project root is implied by `git status` / `git log` checks. A bare `.claude/...` always means the project's `.claude/`, never the user-level one.
- **User-level Claude files** (skills, settings, memory under `~/.claude/`) — always prefix with `~/.claude/`: `~/.claude/skills/session-handoff/SKILL.md`, `~/.claude/CLAUDE.md`, `~/.claude/projects/<encoded-cwd>/...`. Never write these as bare `.claude/...` — that collides with the project's own `.claude/` directory and is the most likely source of confusion in this new layout.
- **Absolute paths** (anything outside both roots — system configs, other repos on the machine, network mounts, a Copilot chat JSONL under `%APPDATA%\Code\User\workspaceStorage\...`) — spell out the full path: `C:\Users\<user>\Documents\notes\foo.md`, `/etc/nginx/nginx.conf`, `D:\Work\Other\sibling-repo\src\bar.py`.
- **Never point into a session scratchpad or temp folder.** A session's scratchpad, `/tmp`, `%TEMP%` and similar folders are cleared or are invisible to the next session, so a link into one is broken by the time anyone follows it. If the handoff needs a file that lives there (a draft, a test fixture, a generated report), copy it to a durable location first, by default the project's `.claude/`, and link the copy.

**On first mention of any non-project path in the doc, add a brief parenthetical so the reader doesn't have to deduce the location.** Example:

> Related skill: `~/.claude/skills/session-handoff/SKILL.md` (user-level Claude skills folder, not the project `.claude/`).

Subsequent mentions of the same path can drop the parenthetical — the reader already knows where it lives.

This matters most in the **TODOs** and **How to resume** sections, where a future agent will act on the path directly. A path that turns out to live outside the repo silently breaks "commit and push" instructions, since user-level files cannot be part of a project commit. If a TODO involves a path outside the project root, call that out explicitly: *"Note: `~/.claude/skills/foo/SKILL.md` is user-level (outside the repo) and is NOT part of this commit."*

## SAVE mode — what to write

The handoff must be **self-contained**. The future session has zero memory of this conversation. Don't write "continue what we were doing" — write the goal explicitly. Don't write "the file we edited" — write the path. Don't reference earlier turns.

A handoff is a **snapshot of now, not a record of how we got here**. Every resume reads the whole file, so every line of history is paid for again by every future session, and none of it helps the next step. A handoff that keeps growing across weeks of saves can reach hundreds of kilobytes and cost well over 100K tokens before any work starts. History has better homes: git holds what was done, the project's documents hold what is true, and a decision log, if the user keeps one (see "Decisions leaving the handoff" below), holds how decisions changed.

Use this template:

```markdown
# Handoff: <Task title>

**Created:** <YYYY-MM-DD HH:MM> · **Updated:** <YYYY-MM-DD HH:MM> · **Branch:** <git branch> · **Status:** <in-progress | blocked | ready-for-review>
Previous handoff: <path>  ← only when this one replaced or split from another handoff; otherwise omit the line
Related handoff: <path>  ← only when another open handoff split from this one; otherwise omit the line
Handover: next session launched <YYYY-MM-DD HH:MM>  ← only when this session launched the next one (references/session-chaining.md); the next save removes it

## Goal
<1–3 sentences. What is the user trying to accomplish? Why does it matter? Be concrete enough that someone with no context understands the objective.>

## Current state
<Where things stand now — not how they got here. Bullet points. Reference exact files and line numbers where relevant, e.g. `frontend/src/lib/api.ts:42-58`. Qualify any path that is not project-relative (see "Path qualification" above). Name commits that matter for the next step; git holds the rest.>

## Next step
<The single next concrete action to take. Be specific: which file, which function, what change. If there are multiple parallel threads, list them in priority order.>

## TODOs
### <Owner — e.g. the user, a teammate, the agent>
- [ ] <action, one line> — <link to the document section holding the detail, if any>
### Parked
- [ ] <action> — <what it is waiting for>

## Recent decisions
<Decisions from recent sessions that the next step depends on and that are not yet written anywhere else. One or two sentences each: the decision and why. Skip the section if there are none.>

## Corrections
<Facts the user had to correct an agent on in this workstream, one line each: the correct fact and where it is recorded. Kept until the workstream closes. Skip the section if there are none.>

## Open questions / blockers
<Anything waiting on the user, a teammate, an external system, or an unresolved design question. If nothing, write "None.">

## Linked files
- Decision log: <path> (latest: D-NNN)  ← only if one exists
- House rules: <path>  ← only if one exists

## How to resume
1. Read this file in full, then the house rules if linked. Read the decision log and transcripts only when the work needs them.
2. `git status` and `git log -5` to confirm branch state matches "Branch" above.
3. <Any project-specific setup: env vars to set, services to start, migrations to run>
4. Begin from "Next step".
```

**TODOs are one line each.** Name the action and, where there is detail, link to the document section that holds it rather than copying the detail in. Each item appears once, under its owner. Parked items go under **Parked** with what they wait for. Done items are removed, not ticked and kept: git and the documents already record them.

**Corrections stay until the workstream closes.** When the user corrects a factual claim an agent made (for example "launches are blocked" when they work), record the correct fact in one line, with a pointer to where it is written down. Keep it even when a document already records it. A corrected fact is one the model has already got wrong, and the documents that hold it are read only on demand, so without the line the next session can make the same mistake. Corrections of a proposal or a preference are not facts; they go through Recent decisions as usual.

**Keep formatting minimal.** No emoji. Use bold only where missing it would cause harm, such as a warning that must not be skimmed past. A page where everything is emphasised has nothing emphasised, and the decoration costs tokens on every resume.

**House rules live in their own file.** Standing working agreements, meaning constraints that apply to every session of this work whatever the next step is ("never push without asking", "run the suite natively, not through Bash"), go in a separate file linked under **Linked files**, by default `.claude/house-rules.md`. They change rarely, so copying them into every handoff repeats them in every save, and the copies drift. If the user states a new standing rule during the session, offer to add it to that file.

**Permanent rules may belong in the project's `CLAUDE.md` instead**, meaning rules that hold for anyone working in the project, indefinitely (a commit format, a folder that is never committed). That file is loaded into every session automatically and is usually shared with the team, which is exactly why it is not yours to change unasked. You may suggest moving a rule there, and the user may ask you to add one, but **never write to `CLAUDE.md` without the user's explicit confirmation** of the exact rule being added.

End your reply to the user with a single line:

> To resume in a new session: read `.claude/handoff-<slug>.md`

That line is the user's copy-paste prompt for the fresh session.

After it, unless the save is part of a chain, offer to open that session for the user, or open it
when their preferences say `always`; `references/session-chaining.md` → "Opening the next session
when chaining is off" has the wording and the launch. Saving them the copy-paste is the point, so
the offer is one sentence, not a question.

**When this save opens the next session**, by the user's choice or their `always` preference, and
the launch succeeds, the reply is the reference's single hand-over line instead of all of the above:
no "To resume…" line, no summary of the save. The new session is already reading the handoff, so a
copy-paste prompt would invite a second session on the same task. If the launch fails, keep the
"To resume…" line: the user now starts the next session by hand.

## RESUME mode — load and wait

When the user wants to pick up prior work, do NOT immediately start coding. The point of the handoff is shared situational awareness — confirm both sides have it before acting.

Steps, in order:

1. **Find the doc.** If the user named a path, use it. If they said "the handoff" without specifying, run `Glob .claude/handoff-*.md` and pick the most recently modified one — but if there's more than one match and the right one isn't obvious, ask the user which. If `.claude/` has no matches, also try the legacy location `Glob plans/handoff-*.md` for handoffs written before this skill moved its default location; if you find one there, note the legacy location to the user when you echo back the summary so they know to expect future handoffs in `.claude/`.
2. **Read the doc in full** with the Read tool. Do not skim or read partial ranges: a half-read handoff produces a confident resume from the wrong state. If the doc's status line says it is **closed and replaced by** another handoff, tell the user and offer to resume from the replacement instead.
   **Then read the house-rules file**, if the handoff links one, also in full. It is short, and the rules in it exist for the mistakes that cost the most, so it is read on every resume rather than left to a judgement about whether the next piece of work falls under it.
   If the handoff tells you to read another document, or part of one, in full, read all of it, in as many Read calls as it takes. A read that stops early because the file is too large for one call is not finished: continue from where it stopped instead of starting work.
   **Leave the other linked files unread for now.** The decision log and any saved transcripts are listed in the handoff so they can be found, not so they are loaded on every resume; they are also the files that grow large. Read the decision log when a question turns on why something was decided, and a transcript only when the handoff cannot answer a specific question.
3. **Verify the working state matches.** Run `git status` and `git log -5 --oneline`. Compare against the "Branch" line in the handoff. If they don't match (different branch, missing modified files, advanced commits), surface the discrepancy to the user before proceeding — do not silently reconcile.
4. **Echo back a tight summary** to the user: 2–4 lines covering the goal, the next step from the doc, and any open question or blocker. This proves you read it and gives the user a chance to correct stale info.
5. **Stop and wait for explicit instruction, unless the task chains.** If chaining is on for this task (see `references/session-chaining.md` → "The chain setting"), continue from "Next step" without waiting, as that file's "Continuing resume" describes. Otherwise do not begin "Next step" automatically. End with something like *"Ready to continue from `<next-step>` — say the word and I'll start, or tell me to do something else."*

Why wait (when not chaining): the handoff was written at one point in time. Things may have changed externally (the user may have already done part of the work, decided to abandon the task, or want to take a different angle). Auto-executing the next step risks redoing work or going in the wrong direction. The cost of one short confirmation turn is much lower than the cost of unwanted edits.

If `git status` shows uncommitted changes the handoff did not mention, flag them — they may be the user's in-progress work from another session and must not be overwritten.

## Session chaining and the ctx-watch block

A `[ctx-watch] Context usage is …` block at the end of a turn, or a resume in a project that chains, is handled per `references/session-chaining.md`: it says when to save and launch the next session, when to offer a handoff instead (with the choice of opening the next session), and when to continue rather than wait. A chain save is an ordinary SAVE with every question answered in advance from the handoff's preferences block, so it never stops to ask.

## SAVE mode — optionally save the full session transcript

A handoff is a *snapshot* — it intentionally drops the running narrative. But sometimes a future session (or the user) really does need the conversational detail: *why* a particular path was tried and abandoned, the exact wording of a user instruction, an error message that scrolled past. Saving the full transcript alongside the handoff gives the future session an escape hatch for those cases — without bloating the handoff itself.

After the handoff doc is written and **before** you print the "To resume…" line, run this short flow.

### Locating the bundled scripts

Steps 4 and 5 run Python scripts that ship inside this skill's own folder. **Resolve
them relative to the directory this `SKILL.md` was loaded from** — written below as
`<skill-dir>` — never from a hardcoded root. The skill is installed in different
places depending on how it arrived:

| Installed as | `<skill-dir>` |
|---|---|
| User-level skill | `~/.claude/skills/session-handoff` |
| Project-level skill | `<project-root>/.claude/skills/session-handoff` |
| Claude Code plugin | `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/session-handoff` |
| Copilot / Cursor / Codex | `<project-root>/.agents/skills/session-handoff`, or that agent's global skills folder |

Assuming `~/.claude/skills/...` breaks every case but the first. If you cannot tell
where the skill folder is, locate `scripts/copilot_discover.py` by searching for it
rather than guessing a root, and if it genuinely is not on disk, say so plainly
instead of running a path you have not verified.

### Step 0 — check the handoff for saved preferences

**Before asking anything, read the handoff doc for a `## Handoff preferences` section.** If one is
present, it records what the user chose the last time this task was saved. Honour it and **skip
Steps 1, 1.5, 2 and 3 entirely** — go straight to Step 4 (locate) with those answers.

```markdown
## Handoff preferences (for subsequent saves of this task)

- **Save a transcript:** yes, always
- **Environment:** Claude Code
- **Format:** `.md`
- **Location:** default — `.claude/transcript-<slug>-<YYYY-MM-DD-HHMM>.md`
```

If the block says transcripts are not wanted, skip the whole transcript flow and go to Step 7.

**Why the handoff and not persistent memory.** This preference is scoped to *one task and every
session that resumes it* — which is exactly the handoff doc's lifetime. Memory is scoped to a
user or a project, so a default saved while working in one repo silently fails to apply in
another, and the questions come back. The doc also travels with the task across repos, machines
and agent tools, and the user can change their mind by editing one visible line rather than
asking you to rewrite a memory they cannot see.

Asking is still correct the **first** time a task is saved — a new handoff has no block to read.
Ask once, then record the answers (Step 6) so it is asked only once per task, not once per
session. Do not ask whether to make the answers a default; recording them in the doc *is* the
mechanism, and the user can edit or delete the block.

### Step 1 — ask the user

Only if Step 0 found no preferences block. Use `AskUserQuestion` with a single question:

> **Save the full session transcript alongside this handoff?**
> A future session can refer to it if the handoff alone isn't enough.

Options:
- **Yes, save it** — proceed to Step 2.
- **No, skip it** — record the answer via the Step 6 preferences block (so this task does not ask again), then go to Step 7. Do not add a transcript reference to the handoff.

The wording "alongside" matters — the user should understand the transcript is *supplementary*, not a replacement for the handoff.

### Step 1.5 — ask which environment this session is

The transcript lives in a different place and format depending on whether this is a **Claude Code** session or a **GitHub Copilot** chat. The skill does not auto-detect this — detection is not reliable enough to silently act on, and a wrong guess archives the wrong conversation. Ask, and act on the answer.

Use `AskUserQuestion`:

> **Which environment is this session?**
> This determines where the session transcript is read from.

Options:
- **Claude Code** — transcript comes from `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
- **GitHub Copilot** — transcript comes from VS Code's `workspaceStorage/<hash>/chatSessions/<session-id>.jsonl`.

This is the only question that branches the flow. The format choice (Step 2) and the destination (Step 3) are the same regardless of the answer; only Step 4 (locate) and Step 5 (produce) differ. Remember the answer — it selects the discovery method and the converter in those two steps.

### Step 2 — ask which format to save in

The native transcript on disk is JSONL (one event per line, exactly what the agent wrote). That is fully lossless — every tool call, tool result, thinking block, system reminder is preserved — but it is awkward to skim. A rendered Markdown view is easier for a human to read and scan but folds/omits some structural detail. Both are legitimate; the right choice depends on whether the future consumer is a person browsing or another agent loading specific detail.

Use `AskUserQuestion`:

> **Save the transcript in which format?**

Options:
- **`.jsonl` (raw copy)** — verbatim copy of the session's native JSONL. Lossless, machine-readable, awkward to skim.
- **`.md` (human-readable)** — rendered Markdown conversation log. Easier to scan, slightly lossy on structural detail.

Note on the Copilot raw form: Copilot's JSONL is event-sourced (incremental patches rather than one self-contained record per turn), so a raw `.jsonl` copy is faithful but very hard to read by hand — the `.md` rendering is usually the better choice for a Copilot session unless a machine consumer specifically needs the raw events.

Remember the choice — it determines both the file extension you propose in Step 3 and the action you take in Step 5.

### Step 3 — propose default filename and location

Default filename: `transcript-<handoff-slug>-<YYYY-MM-DD-HHMM>.<ext>` — same `<slug>` as the handoff doc, so the pair is obvious. Use `.jsonl` or `.md` depending on the Step 2 choice.

Default location: `<project-root>/.claude/` — the same project-local Claude folder where the handoff lives. The two files sit side by side (`.claude/handoff-<slug>.md` and `.claude/transcript-<slug>-<timestamp>.<ext>`); the differing filename prefixes are what distinguish primary doc from reference material. Create the folder if it does not exist.

Use a second `AskUserQuestion` so the user can accept or change both:

> **Save transcript as:**
> Default: `.claude/transcript-<slug>-<YYYY-MM-DD-HHMM>.<ext>`

Options:
- **Use default path** — proceed with the defaults.
- **Change filename only** — keep `.claude/`, take a new filename from the user (free-text "Other"). If the user supplies a filename without an extension, append the one matching the Step 2 format choice.
- **Change location only** — keep the default filename, take a new directory from the user.
- **Change both** — take both from the user.

If the user picks any "change" option, follow up with a plain question to collect the new value(s). Validate that the directory exists or can be created; do not silently fall back to the default if the user-supplied path is unusable — surface the problem and re-ask.

### Step 4 — locate the current session's transcript file

This step branches on the Step 1.5 answer. In both environments, prefer the **deterministic** mechanism and fall back to recency only if it yields nothing — and tell the user which method was used, because the fallback can be wrong.

#### Claude Code

Claude Code stores each session as `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.

**Deterministic (primary):** Claude Code sets the environment variable `CLAUDE_CODE_SESSION_ID` to the current session's id — set **per session**, so even two sessions open in the same folder each see their own. The transcript is then exactly:

```bash
echo "$CLAUDE_CODE_SESSION_ID"
# -> ~/.claude/projects/<encoded-cwd>/$CLAUDE_CODE_SESSION_ID.jsonl
```

The `<encoded-cwd>` is the working directory with **both the drive-letter colon and every path separator replaced by `-`** — so `C:\Users\foo\src\bar` becomes `C--Users-foo-src-bar` (note the **double** dash from `C:` + `\`). A common past bug was dropping the colon (yielding a single dash, `C-Users-...`), which points at a directory that does not exist on Windows. If unsure of the exact encoding, just list `~/.claude/projects/` and match the folder, or locate the file by its known session-id filename across the projects tree.

**Recency (fallback):** if `CLAUDE_CODE_SESSION_ID` is unset (older Claude Code), use the most-recently-modified `*.jsonl` in the project dir:

```powershell
$projDir = "$env:USERPROFILE\.claude\projects\<encoded-cwd>"
Get-ChildItem $projDir -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 1
```

…or on POSIX, `ls -t ~/.claude/projects/<encoded-cwd>/*.jsonl | head -1`. This is reliable for a single session (the active session is the one being written) but can pick the wrong file if **two sessions are open in the same folder** and the other one was just touched — so warn the user when you fall back to it.

#### GitHub Copilot

Copilot Chat stores each session as `%APPDATA%\Code\User\workspaceStorage\<hash>\chatSessions\<session-id>.jsonl`. The `<hash>` is opaque, and the active session id is not exposed via an env var — both must be resolved from VS Code's own state. The bundled `copilot_discover.py` does all of this; do not hand-roll it.

```powershell
python "<skill-dir>/scripts/copilot_discover.py" --project-root "<project-root>"
```

It prints JSON with `path`, `session_id`, `title`, `method`, and `workspace_hash`. How it works (and what to surface to the user):

1. **Workspace hash** — it scans every `workspaceStorage/*/workspace.json` and matches the recorded `folder` URI against `--project-root`. Deterministic.
2. **Active session (primary, `method: "active-pointer"`)** — it reads `state.vscdb` (read-only, lock-safe even while VS Code is running) for the focused chat under `memento/interactive-session-view-copilot` and base64-decodes the session id. Exact, even with several chats open.
3. **Recency (fallback, `method: "recency-fallback"`)** — most-recently-modified `chatSessions/*.jsonl`. Same concurrent-session caveat as Claude Code; if `method` comes back as the fallback, warn the user.

To let the user pick a *past* (not currently-focused) Copilot chat, run `copilot_discover.py --project-root <root> --list` to print all sessions (id, title, date, size, which is active) and confirm the target with them.

**Live-session caveat (both environments, but pronounced in Copilot):** the transcript of the session you are *currently in* may not be fully flushed to disk yet. In Copilot specifically, per-turn completion data (`completedAt`/`elapsedMs`) is written late, so a just-started session often has **no timing records** — the converter reports active work honestly as `≥0s` with upper bounds rather than a fabricated number. The conversation text is still captured correctly; only the timing header is mostly bounds. This is expected, not an error.

In either environment, if you cannot find a transcript file, tell the user honestly — do not invent one or save a partial reconstruction.

### Step 5 — produce the transcript at the destination

The action depends on the Step 2 format choice and the Step 1.5 environment. All four bundled scripts require only the Python standard library — no extra installs.

**If `.jsonl` was chosen** (either environment) — copy the located source file to the destination verbatim (PowerShell `Copy-Item`, or `cp` on POSIX). Do not transform or summarize: the value of the raw form is its fidelity, and any future reader expects the native on-disk format.

**If `.md` was chosen — Claude Code** — invoke `jsonl_to_md.py`, which walks the JSONL deterministically and renders a readable Markdown log (rich metadata header) without spending Claude turns or context:

```powershell
python "<skill-dir>/scripts/jsonl_to_md.py" `
  "<source-jsonl-path>" "<destination-md-path>" `
  --session-name "<session name>" `
  --participants "<User Name> (<email>) · Claude Code (<model>, <context window>)" `
  --note "<one-line session-specific narrative>"
```

Its header table has: **Session name, Date, Participants, JSONL source, Session start, Session end, Total duration, Active work**. The calculation component `scripts/session_stats.py` derives every deterministic field (date, start/end, total, active, idle) from the JSONL; you supply only what the JSONL cannot know, via flags:

- `--session-name` — the session's name (omit if unnamed; header then shows `_(unnamed session)_`).
- `--participants` — human (name + email; email is in `~/.claude/CLAUDE.md` if set) and assistant (model + context window, e.g. `Opus 4.8, 1M context`). If omitted, falls back to `Claude Code (<model-id from JSONL>)`.
- `--note` — one line of session-specific narrative appended to the active-work sentence. Optional.

Its **active-work definition**: a *turn* starts at each human user prompt; its active span runs to the last assistant timestamp before the next human prompt; active work sums those spans, excluding idle gaps. Wall-clock **Total duration** can be far larger when a session is left open — expected, which is why both are shown. Run `session_stats.py <jsonl> --json` on its own to inspect the numbers first.

**If `.md` was chosen — GitHub Copilot** — invoke `copilot_jsonl_to_md.py`. Copilot's JSONL is a different, event-sourced format, so it has its own converter:

```powershell
python "<skill-dir>/scripts/copilot_jsonl_to_md.py" `
  "<source-jsonl-path>" "<destination-md-path>" `
  --session-name "<override title — optional>" `
  --participants "<optional participants row>" `
  --note "<one-line session-specific narrative — optional>"
```

What it does that the Claude Code converter does not have to:

- **Reconstructs each turn's full response** by accumulating appended request objects and replaying the incremental `i`-indexed response splices. Reading only the first append would drop most of the assistant's text — this is essential, not optional.
- **Timing from `elapsedMs`/`completedAt`** (millisecond epochs, not ISO timestamps). Turns whose completion event was never flushed are **flagged with an upper bound** (gap to the next turn) rather than dropped, and active work is shown as a `≥` floor with an `(n/total turns)` count. As noted in Step 4, a currently-open session often has *no* timing yet — that is handled gracefully, not an error.
- **Title** defaults to the first `customTitle` in the JSONL (VS Code's descriptive auto-title); `--session-name` overrides it. The header table has **Session ID, Source, Model, Session start, Session end, Total duration, Active work, Idle/think, Turns, JSONL source** (and a Participants row only if you pass `--participants`).
- **Extracts interactive Q&A.** When the agent asks clarifying questions, Copilot stores them as a `questionCarousel` response item (a sibling of the text, *not* part of the `vscode_askQuestions` tool call) with the user's picked/freeform answers in its `data` map. These are rendered inline as a "Clarifying questions asked" block where they occurred — without it, the design decisions a handoff most needs would silently vanish.
- Output is normalized to clean LF line endings (Copilot stores user text with embedded CRLF).

All flags on both converters are optional; with none, each still emits a valid header.

If any copy or conversion fails (path too long, permission denied, disk full, script error), report the exact error to the user and ask how to proceed. Do not write a misleading reference into the handoff for a file that does not actually exist or is empty.

### Step 6 — record the preferences, and reference the transcript

**First, if Step 0 found no preferences block, write one now** — just before the transcript
section — recording the answers the user actually gave in Steps 1–3, so this task never asks
again:

```markdown
## Handoff preferences (for subsequent saves of this task)

- **Save a transcript:** <yes, always | no>
- **Environment:** <Claude Code | GitHub Copilot>
- **Format:** <`.md` | `.jsonl`>
- **Location:** <default — `.claude/transcript-<slug>-<YYYY-MM-DD-HHMM>.<ext>` | the custom path given>

A future SAVE for this task should honour these and **skip the transcript questions entirely**.
If the answer ever changes, edit this block — it is the source of truth for this task.
```

The block may also hold `- **Open the next session:** <ask | always | never>` and
`- **Chaining:** off`, defined in `references/session-chaining.md`. Add either only when the user
states that choice; never ask for them as part of the transcript questions.

Write it even when the user declined a transcript: "no" is just as much an answer worth not
re-asking. In that case write the block, skip the transcript section, and go to Step 7.

If Step 0 *did* find a block, leave it exactly as it is — the user may have edited it deliberately.

**Then** reference the transcript in a single section just before "How to resume". If the handoff already has this section, update it in place rather than adding another: replace the latest path with the new one and keep the "Earlier sessions" line. A handoff saved many times keeps exactly one transcript section of a fixed size, while every earlier transcript stays findable on disk through the pattern.

```markdown
## Full session transcript (reference only)

Latest session: `<relative path to the new transcript, e.g. .claude/transcript-<slug>-<YYYY-MM-DD-HHMM>.md>`
Earlier sessions: `<the same folder>/transcript-<slug>-*`  ← only once an earlier transcript exists; no extension, so both `.md` and `.jsonl` match

**Consult these transcripts only when necessary.** The handoff above is the intended source of truth; the transcripts are here for cases where you need the exact wording of a prior instruction, the full text of an error, or the reasoning behind a path that was tried and abandoned. Do not load or read them as part of normal resume — read one only if a specific question cannot be answered from the handoff alone.
```

If earlier transcripts were saved under a different slug or folder (for example before a split), write that pattern instead, or list both patterns.

The "reference only" framing matters. Without it, a resuming session may try to read the entire transcript as part of resume setup, which defeats the point of having a concise handoff. State explicitly that the transcript is on-demand, not default reading.

### Step 7 — finish

Run the size check (next section), then print the standard "To resume…" line as before, followed by the offer to open the next session (see "SAVE mode — what to write", after the "To resume…" line). The user now has both the handoff (primary) and the transcript (fallback) saved together. If this save opens the next session, end with the one hand-over line instead (same section).

## SAVE mode — size check

After every save, check the handoff's size on disk, measured on the file as just saved. This is also the one point at which the convert offer is made (see "Rewrite, never append" below), so the user gets at most one offer per save:

- **Over 100 KB, current template** — the size warning below.
- **Over 100 KB, older layout, no "older layout kept" note** — the combined offer below, not two offers.
- **100 KB or less, older layout, no note** — the convert offer alone.
- **Older layout with the note** — the user has already declined converting; do not offer it again. A size warning over 100 KB still applies.

If it is **over 100 KB**, tell the user, just before the "To resume…" line:

> The handoff is now <N> KB, roughly <N/4>K–<N/2>K tokens to read on every resume. The largest parts are <the two or three biggest sections>. I can trim it if you want; otherwise it stays as it is.

The range is because the cost per kilobyte depends on how the file is written: plain prose runs at about 4 bytes per token, while tables, symbols and heavy formatting can halve that.

**This is a warning, not an action.** Do not trim, move or drop anything unless the user asks. They may know that the size is justified, and deleting from a handoff on your own judgement is how context gets lost. If they do ask, the options are in "Decisions leaving the handoff" below, and the same choices apply to old state and history: keep it, move it to a document, the decision log or memory, or drop it.

**If the doc also predates the current template**, do not make the trim offer and the convert offer one after the other. Converting is itself the biggest trim, since dated layers and inline copies go, so make one offer that covers both:

> The handoff is now <N> KB (roughly <N/4>K–<N/2>K tokens per resume) and uses an older layout. The largest parts are <sections>. I can convert it to the current template, which would also bring it down to about <estimate> KB; otherwise it stays as it is.

**Converting must not lose decisions.** Dated layers and old "Key decisions" sections often hold decisions. Before converting, collect every decision that would not survive into the new template's sections and put them through the decision table in "Decisions leaving the handoff". Convert only after the user has replied to it.

Count the transcript files separately, not as part of the handoff: they are read only on demand.

## SAVE mode — update an existing doc

If a handoff for this task already exists, update it instead of creating a new one. Find it in this order, and do not rely on the slug alone: a session's slug comes from what it worked on, so a session that drifted to new work would otherwise look for a file that does not exist and skip the workstream check below.

1. The handoff this session resumed from, whatever its slug.
2. `.claude/handoff-<slug>.md`, then the legacy `plans/handoff-<slug>.md` (for files that predate the move to `.claude/`).
3. If neither exists and `.claude/` holds open handoffs (status not closed), name them and ask whether this save belongs to one of them. The user's answer settles the workstream question below as well, so do not ask it again in the same save.

If you update a legacy file in `plans/`, move it to `.claude/` as part of the update so the layout stays consistent.

### Same workstream, or a new one?

Before updating, compare what this session worked on with the handoff's **Goal**. If the work has clearly moved to a different workstream (a different feature, a different deliverable, a switch from one integration to another), ask:

> This session's work looks like a different workstream from the handoff's goal ("<goal>"). How should I save it?
> - **Update the existing handoff** — treat it as the same workstream.
> - **New handoff, close the old one** — the old workstream is finished or abandoned.
> - **New handoff, keep the old one open (split)** — both workstreams carry on.

Ask only when the difference is clear. A session that went deeper into the same goal, or fixed something along the way, is the same workstream; asking every time turns a save into a quiz.

If the user chooses either kind of new handoff:
- Write the new file under a new slug, with the line `Previous handoff: <path to the old one>` under its status line. Carry over only what still applies to the new work: open TODOs, recent decisions, linked files.
- Copy the `## Handoff preferences` block across unchanged. It records how the user likes saves done, which rarely changes with the topic.

Then, for **close the old one**: in the old file, change only the status line, to `**Status:** closed — replaced by <path to the new one> on <YYYY-MM-DD>`, and leave everything else exactly as it was. It is the record of that workstream, and a future session that opens it is sent to the right place. A closed handoff is not updated, so if it sits in the legacy `plans/` folder, leave it there rather than moving it.

For **split**: the old handoff stays open, so update it as normal for whatever this session did on its own workstream, and add the line `Related handoff: <path to the new one>` under its status line. Move any TODOs and decisions that now belong only to the new work out of the old file rather than copying them, so each item lives in one handoff. The two links let a session that opens either file find the other.

### Rewrite, never append

- Set `Updated:` to the new timestamp and keep the original `Created:` date.
- **Rewrite "Current state", "Next step" and "TODOs" in place** to describe now. Do not add dated layers ("UPDATED <date>", "Session 4 notes", "Arising from the review…") and do not keep superseded text for reference. Each layer seems small when added, and together they are what turns a handoff into a history book that every resume pays for in full.
- Remove TODOs that are done, merge duplicates, and keep each remaining item under its owner.
- Remove any `Handover:` line under the status line: it described the previous hand-over, and this save is newer. (A launch from this save writes a fresh one.)
- Carry forward recent decisions that still apply. Do not remove a decision because it looks superseded or settled: propose it in the decision table (see "Decisions leaving the handoff"), usually as log or drop, and let the user choose.
- Keep every line under **Corrections** while the workstream is open, and add a line for any correction made this session. Do not offer them for removal or move them into a document: being documented is not enough for these (see "Corrections stay until the workstream closes").
- If the existing doc predates this template (for example it has a "Key decisions & context" section, or house rules written inline), keep its content and its shape; do not restructure it unasked. The offer to convert it is made once per save, at the size check after the file is saved (see "SAVE mode — size check"), never here during the update, so it can be combined with a size warning into a single offer. The conversion is the user's call.
- If the user declines converting (they answer at the size check, after the file is saved), add this line to the saved file straight away, as a small follow-up edit, so that a resuming session is not misled by stale dated sections and later saves do not ask again: `> Older layout kept by choice on <YYYY-MM-DD>; do not offer to convert it again. The undated sections are current; where dated sections conflict with them, the undated sections win.` Put it under the status line, after any `Previous handoff:` / `Related handoff:` lines. Add it once; keep it on later saves.
- **Preserve any `## Handoff preferences` block verbatim.** It is the record of what the user
  already chose for this task, and rewriting or dropping it makes the transcript questions come
  back on the next save. Change it only if the user asks for a different choice this time (a
  transcript choice, or whether to open the next session) — in which case update the block to
  match what they just chose.

### Decisions leaving the handoff

**Recent decisions** is for decisions the next steps still depend on. When some look settled, you may point them out and offer to move them out. For each one, the user chooses:

- **keep** it in the handoff;
- **log** it in the decision log only (format and location rules in `references/decision-log.md`, next to this file);
- **document** it in a project document, with or without a log entry;
- **memory** — save it to the assistant's persistent memory;
- **drop** it without saving it anywhere.

All five are legitimate, and none is a precondition for another. **Never remove a decision on your own judgement**, and never create a decision log the user has not chosen. Making the offer is enough. Respect the choice, including "drop it": the user knows which decisions are already obvious from the code, and which ones they will never revisit.

Lines under **Corrections** are not offered here: they stay until the workstream closes.

**Make the offer as one table, not one question per decision.** Propose a choice for every decision, with a short reason, and let the user approve the lot or amend individual rows in a single reply. A row may propose two choices that go together, such as "document + log":

| # | Decision | Proposed | Why |
|---|---|---|---|
| 1 | Retry failed uploads three times, then alert | document + log | Settled behaviour; it replaced the earlier no-retry rule |
| 2 | Use the v2 client, not v1 | drop | Obvious from the code now that v1 is removed |
| 3 | Defer the cache until load tests run | keep | The next step still depends on it |

> Reply "approve" to apply these, or name the rows to change (for example "2: keep").

Asking one by one costs a turn per decision, and a question tool that fits only a few options cannot show all five choices anyway. Apply nothing until the user has replied.

## Quality checks before finishing

Before declaring done, re-read the doc with this question: *if I handed this to a colleague who had never seen this codebase, could they pick up the next step?* If the answer is no, fix it. Common gaps:
- Vague goal ("fix the bug" — which bug?)
- Missing file paths
- **Ambiguous file paths** — every path should be locatable from the doc alone. Bare `.claude/handoff-foo.md` or `src/foo.ts` is fine for project files; user-level Claude files must be written as `~/.claude/skills/foo/SKILL.md`; absolute paths must be fully spelled out. The collision between project `.claude/` and user `~/.claude/` is the trap to watch for — never write a bare `.claude/...` when you mean the user-level folder. The first mention of any non-project path should carry a brief parenthetical explaining where it lives. Watch especially for items in **TODOs** that imply a commit — a user-level path silently can't be part of a project commit.
- Links into a session scratchpad or temp folder — copy the file somewhere durable and link that
- "Next step" that assumes context from the conversation
- TODOs phrased as reminders to self instead of actionable items
- History that crept in: dated "updated" layers, superseded text kept for reference, the same TODO listed twice, done TODOs still present, more than one transcript section

## What NOT to include

- Full conversation transcripts or running commentary inlined into the handoff body — the doc is a snapshot, not a log. (Saving the transcript as a *separate* referenced file under `.claude/` is fine and is covered by "SAVE mode — optionally save the full session transcript" above.)
- How the task got here: completed work, dated progress notes, or decisions already superseded. Git, the documents and the decision log hold those.
- Copies of the house rules or of a document's content — link to them instead.
- Emoji and decorative formatting.
- Information already in the project's AI-instructions file (`CLAUDE.md` and/or `.github/copilot-instructions.md`), README, or obvious from the code — link/reference instead.
- User preferences or durable facts — those belong in the assistant's persistent memory.
- Secrets, tokens, or credentials — even if they came up in the session.
