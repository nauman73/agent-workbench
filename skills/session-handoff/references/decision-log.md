# Decision log — format and location

## Contents

- [What it is for](#what-it-is-for)
- [Where it lives](#where-it-lives)
- [Format](#format)
- [Rules](#rules)

## What it is for

A decision log is one chronological file holding the history of a piece of work's decisions:
what was decided, what it replaced, and why. It lets the documents and the handoff describe only
what is true now, because the history has somewhere else to go.

This file is the single definition of the format. Any skill that writes a decision log should
use it rather than keep a copy of its own, so that a log started by one skill can be continued by
another.

A log is always optional for this skill. The user decides, decision by decision, whether
something goes into the log, into a project document, into memory, stays in the handoff, or is
dropped. Never create a log, or move a decision into one, without the user choosing it.

## Where it lives

The location is not fixed. Before creating a log, look for an existing one, in this order:

1. the path recorded under **Linked files** in the handoff;
2. a `decision-log.md` anywhere in the project, skipping dependency and build folders
   (for example `plans/<feature>/decision-log.md`, a convention some workflows use).

If the handoff links one, use it. If the search finds one that may belong to different work (it sits in another feature's folder, or its title names other work), ask whether to use it or start a new one rather than writing this work's decisions into it. If several are found and the handoff does not say which applies, ask.

If none exists, ask the user where to create it, and record the answer under **Linked files** in
the handoff so no later session asks again. When asking, point out the one consequence that is
easy to miss: a log inside a tracked folder is committed and published with the project, so in a
public repository every entry becomes public. An untracked location such as `.claude/` keeps it
local.

## Format

```markdown
# Decision log — <project or feature>

Chronological record of decisions made or changed. The documents show only current
decisions; this file is the only history.

## Contents
- [D-001 · <YYYY-MM-DD> · <decision in one line>](#d-001--<yyyy-mm-dd>--<slug>)

## D-001 · <YYYY-MM-DD> · <decision in one line>

| | |
|---|---|
| **Decision** | <what is now true> |
| **Replaces** | <the old decision, quoted, plus its D-NNN if it had one; or "new"> |
| **Reason** | <why, in one or two sentences> |
| **Raised by** | <user / review / testing / …> |
| **Documents updated** | <document § section, …; or "none"> |
```

The anchor in each contents entry is the heading lowercased, with the `·` separators dropped and
spaces turned into hyphens, which is why it has double hyphens.

## Rules

- **Append-only.** Never edit or delete an entry. A reversal is a new entry whose **Replaces**
  names the one it reverses.
- **Replaces quotes the old text**, so each entry reads on its own, without the earlier version of
  any document.
- **Number in sequence.** Read the last entry's ID before writing; never reuse one.
- **Keep the contents list in step** with the entries.
- **Documents updated may be "none".** A decision logged straight from a handoff often has no
  document yet; say so rather than inventing one.
- **Documents do not cite entry IDs.** The log points to the documents, not the other way round,
  so a document never needs editing just because the log grew.
