# session-handoff

Carry one task across a cleared or compacted agent session, without re-explaining it.

## The problem

Agent sessions end badly. Context fills up and auto-compact silently drops the
middle of your conversation; you run `/clear` to get room back; you stop for the
day and come back tomorrow to a session that has no idea what you were doing.

Persistent memory does not solve this. Memory is for durable facts — who you are,
how the project is laid out, what you prefer. It is deliberately not a record of
*in-flight task state*: which file you were halfway through editing, which
approach you already tried and rejected, what you were blocked on.

So that state gets reconstructed by hand, from scratch, every time. You re-explain
the goal, re-locate the files, and re-derive the decision you already made
yesterday — and the agent confidently redoes work you had already finished.

## What it does

Two modes, chosen from how you phrase the request.

**SAVE** — writes a self-contained snapshot to `.claude/handoff-<slug>.md`:
the goal, where things stand with exact file paths and line numbers, the single
next concrete action, one-line TODOs grouped by owner, recent decisions the next
step depends on, and open blockers. Standing working rules and an optional decision
log live in their own files, which the handoff links rather than copies.

Say any of: *"save the session"*, *"I'm about to /clear"*, *"compact is coming"*,
*"checkpoint this work"*, *"update the handoff"*.

**RESUME** — finds the handoff, reads it and any linked house-rules file in full
(the decision log and transcripts only when a question needs them), checks `git status` and
`git log -5` against the branch the handoff recorded, echoes back a short summary,
and then **stops and waits**.

Say any of: *"resume from the handoff"*, *"pick up where we left off"*,
*"read .claude/handoff-auth-bug.md and continue"*.

You do not have to be the one who notices it is time. The [`ctx-watch`](../../hooks/)
hook in this repo watches how full the context window is and, once it passes a
threshold you set, has the agent offer you a SAVE — which is the moment the offer is
worth something and the moment you are least likely to think of it yourself.

## Design choices worth knowing

**A handoff stays a snapshot of now.** Every resume reads the whole file, so every
line of history in it is paid for again by every future session. A handoff that is
appended to across weeks of saves can pass a hundred kilobytes and cost more than
100K tokens before any work starts. So a save rewrites the state sections in place
instead of adding dated layers, removes finished TODOs, and keeps one transcript
reference rather than one per save. When the work moves to a different workstream,
the skill asks whether to update the handoff, start a new one and close the old, or
split into two open handoffs linked to each other. Over 100 KB, it warns you and
offers to trim; it never trims on its own.

**What leaves the handoff is your call.** When decisions look settled, the skill
proposes, in one table, where each should go: stay in the handoff, the decision log,
a project document, persistent memory, or nowhere. Nothing moves until you approve
or amend the table. It never creates a decision log you did not ask for, and never
writes to the project's `CLAUDE.md` without your confirmation of the exact rule.

**Resume does not auto-start the work.** The handoff was true when it was written.
You may have already done part of it, changed your mind, or want a different angle.
Auto-executing "Next step" risks redoing finished work or driving hard in the wrong
direction, so the skill confirms first. One short confirmation turn costs far less
than a batch of unwanted edits. If `git status` shows uncommitted changes the
handoff never mentioned, it flags them rather than working over the top of them.

**Every path is written to be locatable from the doc alone.** A future session has
no idea where anything lives, and `.claude/` is ambiguous — the project has one and
so does your home directory. So project files stay relative (`src/api.ts:42-58`),
user-level files are always written `~/.claude/...`, and anything else is spelled
out in full. This matters most in TODOs that imply a commit: a user-level file
cannot be part of a project commit, and the skill calls that out explicitly instead
of letting a future session discover it the hard way.

## Optional: archive the full transcript

A handoff is a snapshot, so it drops the running narrative on purpose. Occasionally
that narrative is what you need — the exact wording of an instruction, the full text
of an error that scrolled past, why a path was tried and abandoned.

So SAVE mode can also archive the complete session transcript next to the handoff,
as either a verbatim `.jsonl` copy or a rendered Markdown log with a metadata header
(session start/end, total duration, and active work time excluding idle gaps). It is
referenced from the handoff as **read-on-demand**, explicitly not part of normal
resume — otherwise a resuming session loads the entire transcript and you have
defeated the point of having a concise handoff.

This works for both **Claude Code** and **GitHub Copilot** chats. The skill asks
which environment you are in rather than guessing, because a wrong guess archives
the wrong conversation. Copilot needs the more careful handling of the two: its
JSONL is event-sourced, so reconstructing a turn means replaying incremental
splices rather than reading one record, and clarifying-question carousels have to be
extracted separately or the design decisions a handoff most needs vanish silently.

Both converters prefer a deterministic lookup for the active session and fall back
to "most recently modified" only when that fails — and they tell you when they fell
back, since that fallback can pick the wrong file if you have two sessions open in
the same folder.

## Requirements and portability

Saving and resuming a handoff needs nothing beyond the agent itself: it reads and
writes markdown and shells out to `git status` and `git log`. That part works
anywhere.

The optional transcript archive needs Python 3 — standard library only, no pip
installs — via the scripts in [`scripts/`](scripts/). Those scripts locate
themselves relative to the loaded skill folder, so it does not matter whether the
skill arrived as a user-level install, a project-level one, a Claude Code plugin,
or under an agent's `.agents/skills/` directory.

Two Claude Code specifics are worth knowing if you run this elsewhere:

- **Archiving only understands Claude Code and Copilot chat history.** As above,
  those are the two formats the scripts can find and parse. On Cursor, Codex or
  anything else, saving and resuming are unaffected — there is simply no transcript
  to attach, because each agent keeps its history somewhere different, if at all.
- **`AskUserQuestion` is a Claude Code tool.** It is what presents the archive
  choices as buttons. An agent without it should ask the same questions in prose;
  the flow degrades rather than breaking.

## The procedure

[`SKILL.md`](SKILL.md) is what the agent actually executes: the handoff template,
the transcript flow step by step, and the checks it runs against its own output
before calling the job done. [`references/decision-log.md`](references/decision-log.md)
defines the decision-log format, kept in one place so any skill that writes a log
can share it.

Read it before you rely on it. This skill writes files into your repository and,
if you turn archiving on, copies your session history into it as well — decide for
yourself that you want both.
