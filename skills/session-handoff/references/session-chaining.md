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
3. Launch (next section) with the chain prompt:
   `Use the session-handoff skill in RESUME mode on .claude/handoff-<slug>.md and continue per the house rules.`
4. Exit 0: end the turn with one line, such as `Handed over: the next session has started
   (generation 3 of 5).`, and stop working on the task. Nothing more: the handoff already records
   the save, the next session reads it, and nobody is watching this tab, so a summary here is
   never read and only delays the hand-over. Any failure: replace the chain line's launch note
   with `launch failed`, and report as the next section says.

## Launching the next session

Run `scripts/launch-next-session.ps1 -ProjectRoot <project root> -Prompt "<prompt>"`, resolving
`scripts/` from this skill's folder as SKILL.md describes. The prompt must not contain `;` or `"`.

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
1. Write this line under the handoff's status line, after any `Previous handoff:` /
   `Related handoff:` lines, with the time from the clock:

       Handover: next session launched <YYYY-MM-DD HH:MM>

   Write it before the launch, so the new session never reads a handoff without it.
2. Launch (previous section) with the plain prompt
   `Use the session-handoff skill in RESUME mode on .claude/handoff-<slug>.md.` Leave out the
   chain prompt's "and continue per the house rules": nothing in the prompt should suggest
   starting work.
3. Exit 0: the whole reply is one line saying that the next session has started and that the
   task continues there, such as `Handed over: the next session has started and the task
   continues there.` Then stop working on the task. Leave out the "To resume…" line, the summary
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
