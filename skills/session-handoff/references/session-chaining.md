# Session chaining

How a chain of sessions carries one task forward unattended, and how a session with chaining off
opens the next session when the user asks. SKILL.md points here from SAVE and RESUME; this file is
the single definition.

## Contents
- [The chain setting](#the-chain-setting)
- [When the ctx-watch block arrives](#when-the-ctx-watch-block-arrives)
- [Unattended save](#unattended-save)
- [The chain line](#the-chain-line)
- [Chain step](#chain-step)
- [Launching the next session](#launching-the-next-session)
  - [From the Claude desktop app](#from-the-claude-desktop-app)
  - [Relay (chains in the desktop app)](#relay-chains-in-the-desktop-app)
  - [The script](#the-script)
- [Opening the next session when chaining is off](#opening-the-next-session-when-chaining-is-off)
- [Continuing resume](#continuing-resume)
- [Stop conditions](#stop-conditions)

## The chain setting

Two lines in the project's house rules (`.claude/house-rules.md`):

    - Session chaining: on — at the context switch point, save the handoff and start the next session unattended.
    - Chain generation limit: 5

A handoff may override chaining for its own task in its `## Handoff preferences` block:

    - **Chaining:** off

The handoff's line wins over house rules. With no setting anywhere, chaining is off.

A chain hands over through the launch script, which opens each generation outside the desktop app.
To keep the generations inside the app, the user sets up a relay before the chain needs it; see
[Relay](#relay-chains-in-the-desktop-app).

## When the ctx-watch block arrives

The ctx-watch Stop hook may end a turn with a message starting `[ctx-watch] Context usage is`.

- **Chaining on:** finish the current step, including any background work it started (a
  background shell, a subagent, a monitor), then run an unattended save and the chain step. If
  that work is still running, end the turn to wait for it and hand over once its result has been
  handled; the block arrives only once per band, so carry the instruction across the wait
  yourself. Do not start a new step first. With nothing running, hand over before ending this
  turn: a chain session has no next prompt, so nothing would ask again.
- **Chaining off:** once the current step is done (the same waiting rule applies), offer the
  handoff as one question and end the turn; see
  [Opening the next session when chaining is off](#opening-the-next-session-when-chaining-is-off)
  for the choices. Never save on your own.
- **No setting yet:** ask the user once whether this project should chain, and record the answer
  in house rules (create the file and link it from the handoff if needed). If they say on, ask the
  transcript questions that the preferences block has not answered yet, so no later save asks
  anything.
- **You already handed this session over** (you launched the next session earlier in this
  session, chained or not): say so in one line and stop.

## Unattended save

A chain save is a normal SAVE with every question answered in advance:
- Transcript, environment, format and location come from `## Handoff preferences`.
- The chain always updates the handoff it resumed from; the workstream question does not arise.
- The decision table is not offered. Decisions stay under Recent decisions until the user is back.
- The size check still runs; any warning goes into the handoff's Open questions, not to a prompt.

## The chain line

One line under the handoff's status line, present only while chaining is on:

    Chain: generation <n> of <limit> · next session launched <YYYY-MM-DD HH:MM>

The first save of a chain writes generation 1. Each chain save writes the next number. The time
is the current local time read from the clock (for example `Get-Date -Format 'yyyy-MM-dd HH:mm'`),
never estimated: it is how the user, back later, tells which session handed over when.

## Chain step

After the save, the transcript and the size check:

1. If the next generation would exceed the limit: write `Chain: stopped at the limit of <N>`,
   do not launch, tell the user in one line, and stop.
2. Write `next session launched <YYYY-MM-DD HH:MM>` into the chain line, with the time from the
   clock.
3. Launch (next section): by the relay if the handoff's `Relay:` line has an id for the next
   generation, otherwise by the script with the chain prompt
   `Use the session-handoff skill in RESUME mode on .claude/handoff-<slug>.md and continue per the house rules.`
4. Started (the relay message was delivered or queued, or the script exits 0): end the turn with
   one line, such as `Handed over: the next session has started (generation 3 of 5).`, and stop
   working on the task. Nothing more: the handoff already records the save, the next session reads
   it, and nobody is watching this tab, so a summary here is never read and only delays the
   hand-over. Any failure: replace the chain line's launch note
   with `launch failed`, and report as the next section says.

## Launching the next session

There are three launchers. With chaining off, use the Claude desktop app's session tool when it is
available and the user asked for this launch; otherwise use the script. A chain step uses the relay
when one is set up; otherwise the script.

### From the Claude desktop app

In the Claude desktop app (Code tab), open the next session with `mcp__ccd_session__start_session`.
The new session opens inside the app, linked to this one, with a link the user can click and a note
back here when it ends a turn. The tool may be deferred: load it first with ToolSearch
`select:mcp__ccd_session__start_session`. If it does not exist (a plain `claude` terminal, GitHub
Copilot), use the script.

The app starts a session only in a turn that carries the user's own typed words; it refuses in a
turn that runs on another session's brief, a session's message or an automated event. Use the tool
when the user asked for this launch in this turn: they said to save and open a new session, picked
that choice at the ctx-watch offer, or asked for a save and their `always` preference applies. A
chain step never carries the user's words, so it never calls this tool; it uses the relay or the
script. A proposal card (`own_initiative`) is not a launch: it waits for a click, and nobody is
watching a chain.

These steps hold however the hand-over was asked for: "save and open a new session", "hand off to a
child session", "open a new fresh session", or any other words. Without them the user has to repeat
fresh, title and detach at every hand-over.

**Three launch choices.** The handoff's `## Handoff preferences` block may carry:

    - **Next session context:** ask        (ask | fresh | fork)
    - **Next session title:** ask          (ask | sequence)
    - **Detach the next session:** ask     (ask | always | never)

`ask` is the default when a line is absent. `fresh` or `fork` uses that context without asking;
`sequence` uses the proposed title (below) without asking; `always` detaches and `never` leaves the
session nested, without asking.

**The proposed title.** Read this session's title with `mcp__ccd_session_mgmt__get_session`
(`session_id: "self"`). If it ends in a number (`-3`, ` 3`, `_3`), propose the same title with the
number plus one; otherwise append `-2`. So `payment-retry-refactor-seams-2` becomes
`payment-retry-refactor-seams-3`. Keep it under 60 characters. If the user named the new
session in their message ("open payment-retry-4"), that is the title, and nothing is proposed.

**The name.** `name` is only a handle; the sidebar shows `title`. Derive it from the title:
lowercase it, turn every run of characters outside `[a-z0-9]` into one `-`, and trim `-` from both
ends. If the result is over 24 characters and ends in a number, shorten the part before the number
so the number survives (`payment-retry-refac-3`, not `payment-retry-refactor-s`); otherwise cut it
to 24. Do not leave the name to the app: it cuts at 24 characters itself and can lose the number.

**One question, before the launch.** If any of the three choices is `ask`, make one question tool
call before `start_session` (in prose where there is no question tool) holding only those choices,
and a last part on saving them:

| Question | Options |
|---|---|
| Context for the new session? | Fresh, reads the handoff (Recommended) · Fork, carries this conversation |
| Title for the new session? | `<proposed title>` (Recommended) · another (the free-text option) |
| Detach it from this session? | Keep it nested (Recommended) · Detach to top level |
| Use these choices for every later launch of this task? | Yes, save them · No, ask again next time |

Fresh is recommended because the handoff exists so the next session starts small; a fork copies
this session's full context, which is usually what triggered the hand-over. With "Yes, save them",
write the answers into the preference lines: `fresh` or `fork`; `sequence` if the proposed title
was picked (a typed title is not saved); `always` or `never`. Write nothing otherwise. With every
choice already set, ask nothing.

**The start call.** Load `start_session` and call it with:
- `initiation: "user_asked"`
- `prompt`: the launch prompt
- `title` and `name`, as above
- **Fresh:** `context: "fresh"`; `use_worktree: false`, so the next session works in this folder,
  on the branch and with the uncommitted changes the handoff describes; and `background`, at least
  80 characters, such as `Continues the task recorded in .claude/handoff-<slug>.md. The previous
  session saved it and handed over to this one.`
- **Fork:** `context: "fork"`, and leave out `use_worktree` (the tool rejects it with a fork) and
  `background` (ignored). The prompt is the same resume prompt, so the fork re-reads the handoff
  instead of trusting its copied memory of it.

- **Started:** the tool result says the session has started.
- **Refused or failed:** launch with the script instead.

**After the start, make the title stick.**
1. `mcp__ccd_session_mgmt__set_session_title` with the new session's id and the title.
2. `mcp__ccd_session_mgmt__get_session` with that id, and compare its `title`. If it differs, set
   it once more and read it again; if it still differs, say so in the hand-over reply
   (`… started as "<actual title>"; the proposed title did not take`).
3. If detaching was chosen, `mcp__ccd_session_mgmt__detach_session` with the new session's id. It
   moves the session to top level: it stops nesting under this session, is not archived with it,
   and no longer sends notes back here. `get_session` then shows `detached: true`.

### Relay (chains in the desktop app)

Since a chain step cannot start a session in the desktop app, a relay starts every generation up
front, in a turn where the user asks for it in words, and each generation wakes the next with a
message. Set it up when the user asks to run the chain as a relay, usually when the chain starts:

1. In that turn, start each remaining generation, up to the limit, with the desktop tool and the
   arguments above, titles `<base>-<n>` by the sequence rule above (the next number after this
   session's, then one more for each generation), and this prompt:

       You are generation <n> of the chain for .claude/handoff-<slug>.md. Reply waiting and end your turn. Read nothing and do nothing until a message says hand over. Then use the session-handoff skill in RESUME mode on .claude/handoff-<slug>.md and continue per the house rules.

   Start them all from this one session, so they share its permission mode: a message to a session
   in a different mode can be held for approval. This session is the current generation.
2. Ask the one question above once, before the first start, and apply the answers to every
   generation (the title answer is the base). Make each title stick and detach as above; a
   detached generation no longer sends notes back here.
3. Write their ids, in order, on one line under the handoff's chain line, and keep the line on
   every chain save until the chain ends:

       Relay: 2 local_<id> · 3 local_<id> · 4 local_<id> · 5 local_<id>

   A start that was refused leaves its generation out; that generation is launched by the script
   when its turn comes.

At the chain step, send `hand over` with `SendMessage` (`to`: the next generation's id; it may be a
deferred tool: load it with ToolSearch `select:SendMessage`). A result saying "delivered" or
"queued" means the next session has started. Do not call `start_session` or `detach_session` in a
chain step. If the send returns an error, launch with the script instead. A generation the script
opened has no desktop tools; it still uses the relay at its own chain step if it has
`SendMessage`, and the script if not.

When the chain ends, at a stop condition or the limit, tell the user which relay sessions are still
waiting; they are the user's to archive.

### The script

Run `scripts/launch-next-session.ps1 -ProjectRoot <project root> -Prompt "<prompt>"`, resolving
`scripts/` from this skill's folder as SKILL.md describes. The prompt must not contain `;` or `"`.
It opens a separate CLI session, outside the desktop app.

- **Exit 0:** the next session has opened, in a Windows Terminal tab or a console window.
- **Exit 3:** not Windows; nothing was launched, and the script printed the command.
- **Any other exit:** the launch failed.

On a failure, report the script's message and the command for the user to run by hand, and say
nothing was launched. Do not retry with a command of your own: the script exists so the launch is
the one that was tested.

## Opening the next session when chaining is off

With chaining off, the user can still have this session open the next one instead of starting it
by hand. The new session resumes and waits for instructions, as RESUME does when chaining is off.

**The preference.** The handoff's `## Handoff preferences` block may carry:

    - **Open the next session:** ask

`ask` (the default when the line is absent) offers; `always` launches after every save without
offering; `never` leaves the offer out. Write or change the line only when the user says which
they want (for example "always do that").

**At the ctx-watch block,** the offer is one question with these choices (with `never`, leave the
second out):
- **Save the handoff** — save, end with the "To resume…" line, and keep this session.
- **Save and open a new session** — save, then launch as below.
- **Keep going** — no save; carry on with the user's work.

Use the question tool where there is one; otherwise ask in prose with the same choices.

**After a manual save,** end with the "To resume…" line and then, with `ask`, one sentence such as
*"I can also open the next session for you now, if you want."* It is a sentence, not a question
tool call, so a save gains no extra step. With `always`, launch instead of offering. The same
applies when the user asked for both at once ("save and open a new session").

**Launching.**
1. From the desktop app, settle the launch choices first (the one question, previous section), so
   the title is known. Then write this line under the handoff's status line, after any `Previous handoff:` /
   `Related handoff:` lines, with the time from the clock:

       Handover: next session "<title>" launched <YYYY-MM-DD HH:MM>

   Write it before the launch, so the new session never reads a handoff without it. The title is
   the one chosen for a desktop-app launch, so the record says who took over; a script launch has
   no title, so leave out `"<title>" ` there. If the title that took differs, correct the line.
2. Launch (previous section) with the plain prompt
   `Use the session-handoff skill in RESUME mode on .claude/handoff-<slug>.md.` Leave out the
   chain prompt's "and continue per the house rules": nothing in the prompt should suggest
   starting work.
3. Started (the desktop tool says so, or the script exits 0): the whole reply is one line saying
   that the next session has started and that the task continues there, such as `Handed over:
   the next session "<title>" has started and the task continues there.` (add the title-did-not-
   take note from the previous section when it applies). Then stop working on the task. Leave out the "To resume…" line, the summary
   of what was saved and the user's open items: the new session reads the handoff and shows them
   there, and a copy-paste prompt here would invite a second session on the same task. Any
   failure: change the line to `Handover: launch failed`, report as the previous section says, and
   end with the "To resume…" line, since the user now starts the session by hand.

**Afterwards.** The `Handover:` line tells a reader which session took over; the next save
removes it. The new session ignores it: it is the next session. If the user goes on typing in
the old session, remind them in one line that the task moved to the new session, and ask before
doing more on it there; the user may have a reason, so do not refuse.

## Continuing resume

When chaining is on for the task, RESUME steps 1-4 run as usual and step 5 continues from
"Next step" without waiting. If a question needs the user, record it under
"Open questions / blockers", carry on with work that does not depend on it, and stop and wait
when nothing independent is left.

## Stop conditions

Stop conditions come from the user's workflow: house rules, the plan (for example a STOP at a
phase boundary), or the handoff. Carry forward the ones that exist; never invent one. At a stop
condition, save the handoff (not a chain save: no launch) and wait. The generation limit is the
backstop.
