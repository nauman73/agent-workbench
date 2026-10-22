# Session chaining

Carry one long task across several Claude Code sessions without anyone at the keyboard: when the
context window reaches the point you would rather start fresh, the agent saves a handoff and opens
the next session, which picks the task up and carries on.

Session chaining is not a separate install. It is what the [`ctx-watch`](../hooks/) hook and the
[`session-handoff`](../skills/session-handoff/) skill do together once you turn it on. This page is
the one place that describes it; the two READMEs cover their own components and link here.

## Contents

- [What it does](#what-it-does)
  - [Opening the next session without chaining](#opening-the-next-session-without-chaining)
  - [Opening it from the Claude desktop app](#opening-it-from-the-claude-desktop-app)
- [How a hand-over happens](#how-a-hand-over-happens)
  - [Chains in the Claude desktop app: the relay](#chains-in-the-claude-desktop-app-the-relay)
- [Requirements](#requirements)
- [Setup checklist](#setup-checklist)
  - [Once per machine](#once-per-machine)
- [What to expect](#what-to-expect)
- [Caveats](#caveats)
- [Tested so far](#tested-so-far)

## What it does

`ctx-watch` watches how full the context window is. With blocking turned on, it stops the agent at
the end of the turn in which usage crosses your switch point, and tells it to act on the project's
house rules. What happens next depends on one line in those rules:

- **Chaining on:** the agent saves the handoff without asking anything, opens the next session, and
  stops. The new session resumes from the handoff and continues the work without waiting for
  confirmation.
- **Chaining off:** the agent asks what you want, with three choices: save the handoff, save it
  and open a new session, or keep going. It saves nothing until you answer.

A chain is a series of sessions, each one a *generation*. A limit on the number of generations is
the backstop that ends it.

### Opening the next session without chaining

With chaining off, the agent can still open the next session for you, so you do not have to start
it and paste the resume line by hand. Pick "save and open a new session" at the switch point, or
take up the one-sentence offer at the end of any handoff save. The new session reads the handoff
and waits for your instructions; the old one notes the hand-over in the handoff
(`Handover: next session launched <time>`) and stops working on the task. This works without
`ctx-watch` too, from a save you ask for yourself.

To make it automatic, or to stop the offer, add one line to the handoff's
`## Handoff preferences` block: `- **Open the next session:** always`, or `never`. Outside the
Claude desktop app the launch is the same as a chain's, so the [requirements](#requirements) and
the [one-time dialogs](#once-per-machine) below apply to it as well.

### Opening it from the Claude desktop app

In the Claude desktop app (Code tab), the next session opens inside the app instead of in a
terminal, on any operating system, linked to the one that started it. Before the launch the agent
asks one question covering three choices, plus whether to keep the answers:

- **Context:** fresh, where the new session starts small and reads the handoff (recommended), or a
  fork that carries the whole conversation.
- **Title:** the current session's title with its number raised by one (`payment-retry-3` after
  `payment-retry-2`; `-2` is appended when there is no number), or one you type.
- **Detach:** keep the new session nested under this one (recommended), or move it to the top level,
  where it is not archived with this session and sends no notes back to it.

Saved answers go into the handoff's preferences block, and later launches of the same task ask
nothing:

```markdown
- **Next session context:** fresh        (ask | fresh | fork)
- **Next session title:** sequence       (ask | sequence)
- **Detach the next session:** never     (ask | always | never)
```

A title you name in the request ("open payment-retry-4") is used as given. After the launch the
agent sets the title, reads it back, and says so if it did not take; the `Handover:` line records it
(`Handover: next session "payment-retry-3" launched <time>`).

The app starts a session only in a turn that carries your own words, so this launch happens when
you ask for it, or when an `always` preference applies to a save you asked for. Where the app
refuses, or outside the app, the agent falls back to the launch script.

## How a hand-over happens

1. **The block.** At the end of each turn the Stop hook compares the usage now with the usage at the
   end of the previous turn. The first turn that ends at or above the switch point is blocked, and
   then the first turn that enters each further band (`blockStep` wide, 5 points by default): with a
   switch point of 25, blocks come at 25, 30, 35 and so on. The hook blocks at most once per turn.
2. **Finishing the step.** The block is a notice, not an interruption. The agent finishes the step
   it is on. If that step started background work (a background shell, a subagent, a monitor) that
   is still running, the agent ends the turn to wait for it and hands over once its result has been
   handled; the work's completion notification starts the next turn, so the chain does not stall.
   With nothing running, it hands over before ending the turn: a chain session has no next prompt,
   so nothing would ask again.
3. **The save.** An unattended save is a normal handoff save with every question answered in
   advance from the handoff's preferences block (whether to archive the transcript, and in which
   format and location). It always updates the handoff it resumed from. Decisions stay in the
   handoff until you are back to sort them.
4. **The chain line.** Under the handoff's status line the agent writes the generation and the time
   it launched the next session, read from the clock:
   `Chain: generation 3 of 5 · next session launched 2026-10-05 14:20`.
5. **The launch.** A bundled script opens the next session in the project folder with the prompt
   `Use the session-handoff skill in RESUME mode on .claude/handoff-<slug>.md and continue per the house rules.`
   In the desktop app, a [relay](#chains-in-the-claude-desktop-app-the-relay) wakes a waiting
   session instead. The old session says so in one line and stops working on the task.
6. **The resume.** The new session reads the handoff and house rules, checks `git status` against
   the recorded branch, and continues from the handoff's "Next step". A question that needs you is
   written into the handoff's open questions; the session carries on with whatever does not depend
   on it, and stops when nothing independent is left.
7. **The limit.** When the next generation would exceed the limit, the agent saves the handoff,
   writes `Chain: stopped at the limit of <N>`, tells you, and launches nothing.

### Chains in the Claude desktop app: the relay

A chain step runs without anyone typing, and the desktop app starts sessions only in a turn that
carries your words, so a chain cannot open its next generation inside the app on its own. By
default the launch script opens it in a terminal instead. To keep every generation inside the app,
ask for the chain to run as a relay when it starts. In that turn the agent:

1. asks the [launch question](#opening-it-from-the-claude-desktop-app) once, and starts every
   remaining generation up to the limit, titled in sequence. Each one replies that it is waiting and
   does nothing more.
2. records their ids in the handoff, under the chain line:
   `Relay: 2 local_<id> · 3 local_<id> · 4 local_<id> · 5 local_<id>`.

At each chain step, the agent sends `hand over` to the next generation instead of launching
anything, and that generation resumes from the handoff. If the message cannot be sent, or a
generation was never started, the script launches it instead. When the chain ends, the agent tells
you which relay sessions are still waiting; archiving them is up to you.

Stop conditions you already have, such as a plan's review point at the end of a phase, still
apply: at one, the agent saves the handoff without launching and waits for you. The skill never
invents a stop of its own.

The exact rules the agent follows are in the skill's
[`references/session-chaining.md`](../skills/session-handoff/references/session-chaining.md).

## Requirements

- **Claude Code, with the `ctx-watch` hook installed.** The hook's block is what starts a
  hand-over. GitHub Copilot, Cursor and Codex can run the `session-handoff` skill but not the hook,
  so chaining never triggers there.
- **The standalone `claude` CLI on `PATH`, for the script launch.** The next session is started
  from the command line. A copy bundled inside an editor extension is skipped, so an install that
  has only the VS Code extension has nothing to launch. A launch from the Claude desktop app, and a
  relay, need neither this nor Windows.
- **Windows, for the automatic script launch.** The next session opens as a new tab in the current
  Windows Terminal window when `wt.exe` is on `PATH`, and in a new console window otherwise. On
  Linux and macOS the chain still saves the handoff, then prints the command to start the next
  session and pauses until you run it.

## Setup checklist

1. **Turn blocking on** in `ctx-watch.json`, in your user folder (`~/.claude/ctx-watch.json`) or
   the project's (`.claude/ctx-watch.json`):

   ```json
   { "switchPoint": 25, "blockStep": 5, "block": true }
   ```

   Use whole numbers for both: a fractional `switchPoint` is rounded (`8.5` is read as 8), and a
   fractional `blockStep` is ignored in favour of 5. With `block` on, the hook's usual
   suggestion before each prompt is switched off, since the block replaces it. The
   [hook's README](../hooks/README.md#configuration) lists every key.
2. **Turn chaining on** with two lines in the project's house rules, `.claude/house-rules.md`:

   ```markdown
   - Session chaining: on — at the context switch point, save the handoff and start the next session unattended.
   - Chain generation limit: 5
   ```

   With no setting anywhere, the first block asks you once whether the project should chain and
   records the answer there. A single task can opt out by adding `- **Chaining:** off` to its
   handoff's `## Handoff preferences` block; the handoff's line wins over house rules.
3. **Answer the transcript questions in advance.** An unattended save asks nothing, so the
   handoff's preferences block must already say whether to archive the transcript. Saving the
   handoff once by hand records it; when chaining is first turned on, the skill asks any of these
   questions that are still unanswered.
4. **Register the hook once.** If the hook is registered by hand in `~/.claude/settings.json` and
   you then install the plugin, remove the by-hand registration: two copies would both block.

### Once per machine

A chained session runs in your normal permission mode, with nobody there to answer a dialog. Two
dialogs appear only the first time, and each needs answering once:

- **Trust the folder.** The first session launched in a project folder asks whether to trust it.
  Start `claude` in the folder by hand once and answer it.
- **Allow reads outside the working directories.** In a terminal session, Auto mode asks once, with
  a "Read outside the working directories" dialog, before reading a file outside the working
  folders, such as the skill's own files under `~/.claude/`. Answer "Yes and keep allowing" in any
  terminal session; the answer then holds for every later session on the machine. Sessions in the
  VS Code panel do not show this dialog, because the extension handles permission questions
  itself, so answering it there is not possible: use a terminal session.

## What to expect

- **The hand-over comes a little after the switch point.** The block arrives at the end of a turn,
  and the agent finishes its current step first. In testing, with steps of about half a percent
  each, hand-overs came at 9.2-9.5% against a switch point of 9.
- **A long turn runs past the switch point.** The hook can act only when a turn ends. A turn that
  does a lot of work without ending, as a resumed chain session often does, is blocked only when it
  ends, which may be well past the switch point. Set the switch point low enough to leave room for
  one long step.
- **The block shows as an error.** Claude Code displays the hook's message labelled
  `Stop hook error:`. It is the expected block, not a failure. The usual readout
  (`ctx 26% (259/980k) — switch point`) is shown alongside it.

## Caveats

- **Auto mode can refuse the launch.** Its safety check may occasionally decline the command that
  starts the next session. None of the test runs saw this. If it happens, the handoff records
  `launch failed` (on the chain line, or the `Handover:` line), the old session reports the command,
  and nothing continues until you run it.
- **Moving a launched session into the VS Code panel.** A session the agent opens runs in a
  terminal. To continue it in the VS Code panel, close its terminal tab, run **Developer: Reload Window**, and
  open the session from the session list.

## Tested so far

| | Windows | Linux | macOS |
|---|---|---|---|
| Hook registered by hand in `settings.json` | tested | not tested | not tested |
| Plugin install | not tested | not tested | not tested |

The Windows runs covered a three-generation chain in Windows Terminal tabs ending at its limit, a
two-generation chain launched through the console-window fallback, and a session with chaining off
that offered a handoff and saved nothing.
