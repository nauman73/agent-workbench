# Session chaining

How a chain of sessions carries one task forward unattended. SKILL.md points here from SAVE and
RESUME; this file is the single definition.

## Contents
- [The chain setting](#the-chain-setting)
- [When the ctx-watch block arrives](#when-the-ctx-watch-block-arrives)
- [Unattended save](#unattended-save)
- [The chain line](#the-chain-line)
- [Chain step](#chain-step)
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
- **Chaining off:** offer the handoff to the user, in a sentence or as a question with choices,
  and end the turn. Never save on
  your own.
- **No setting yet:** ask the user once whether this project should chain, and record the answer
  in house rules (create the file and link it from the handoff if needed). If they say on, ask the
  transcript questions that the preferences block has not answered yet, so no later save asks
  anything.
- **The handoff's chain line already says `next session launched`** for this session: the
  session has been handed over. Say so in one line and stop.

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
3. Run `scripts/launch-next-session.ps1 -ProjectRoot <project root> -Prompt "<resume prompt>"`
   (resolve `scripts/` from this skill's folder, as SKILL.md describes), where the resume prompt is:
   `Use the session-handoff skill in RESUME mode on .claude/handoff-<slug>.md and continue per the house rules.`
4. Exit 0: end the turn with one line, such as `Handed over: the next session has started
   (generation 3 of 5).`, and stop working on the task. Nothing more: the handoff already records
   the save, the next session reads it, and nobody is watching this tab, so a summary here is
   never read and only delays the hand-over. Exit 3 or any other failure: replace the chain
   line's launch note with `launch failed`, report the script's message and the command to run
   by hand, and stop.

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
