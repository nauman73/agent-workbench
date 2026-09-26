# Agent Workbench

Skills, hooks and other pieces for day-to-day engineering work with coding agents,
published one at a time as each proves itself on real tasks. Built for Claude Code;
some of it runs on any agent — [What's in here](#whats-in-here) says which.

## What's in here

Everything here is written and used against Claude Code, so that is where it is
proven, and the plugin is the only route that installs all of it in one command. How
much further a piece travels depends on what that piece *is*, so each kind says so
below. The rule underneath them is the same each time: **content the model reads is
portable; anything the harness runs is not.**

### Skills

A folder containing a `SKILL.md`: frontmatter naming the skill and describing the
situations it applies to, followed by the procedure itself. The agent keeps only that
description in context and loads the body when your request matches it.

The practical consequence is that a skill costs you almost nothing until it fires.
Instructions you paste into one ever-growing project file are paid for on every
single turn, whether relevant or not — which is why that file eventually gets ignored
and a folder of skills does not.

**Skills travel in full.** They are markdown the model reads, so any agent that can
read a file can run one, and the `skills` CLI installs them for Cursor, Copilot and
Codex directly. One caveat within that: a skill can still *reach for* something
specific to Claude Code — a tool like `AskUserQuestion`, or a path such as
`~/.claude/projects/`. Where one does, its own README says which parts are affected
and what the alternative is, rather than leaving you to find out mid-task. Typically
it degrades rather than breaking: a question asked as prose instead of buttons, an
optional step that finds nothing to do.

### Hooks

A script the harness runs at a fixed point in the session — after a turn, before a
prompt is sent — rather than something the model chooses to read. That difference
cuts both ways. A hook can tell you something the model has no way to know, and it
runs whether or not the model thought to. It also runs **every turn,
unconditionally**, which is the exact opposite of the property that makes skills
cheap; see [Before you run any of this](#before-you-run-any-of-this).

**A hook does not travel.** Being executed rather than read binds it to one agent and
one shell, where a skill is bound to neither.

Room here later for agents and MCP servers, which are neither of the above. Each will
say in its own section how far it reaches; the answer is not the same for all of them.

## Catalogue

| Name | Type | Works with |
|---|---|---|
| [`jira-story`](skills/jira-story/) | skill | Any agent · any OS |
| [`session-handoff`](skills/session-handoff/) | skill | Any agent · any OS |
| [`smart-commit`](skills/smart-commit/) | skill | Any agent · any OS |
| [`ctx-watch`](hooks/) | hook | Claude Code, plugin install only · Windows |

The **Works with** column applies the rule above per item, and shows why the two
limits on a hook need stating separately. `ctx-watch` is Claude-Code-only because it
is a hook, which nothing fixes. Its Windows limit is a different kind: a statement of
what has been tested, not of what the code can do. The script is PowerShell, and it
runs on Linux under PowerShell 7 when registered by hand in `settings.json`; the
plugin install, the route this catalogue describes, stays listed as Windows until a
live session has run it elsewhere. The
[hook's README](hooks/README.md#requirements-and-portability) has the full matrix.

What each one does:

- **`jira-story`** — turns a plan, design doc or short brief into one story-shaped
  markdown document: title, type, description, value statement, numbered acceptance
  criteria, definition of done, out of scope. Infers the story type from what the work
  produces, and defines when to reconcile the story with the code once it drifts.
- **`session-handoff`** — carries one task across a cleared or compacted session.
  Writes a self-contained snapshot — goal, state, next step, decisions, blockers —
  and can archive the full Claude Code or GitHub Copilot transcript alongside it.
- **`smart-commit`** — commits in the format the branch already uses. Stages
  explicitly rather than with `add -A`, asks before including untracked files, and
  shows the finished message for approval before anything is written.
- **`ctx-watch`** — prints how full the context window is after each turn, and once
  it passes a threshold you set, has the agent offer you a handoff. Fills a gap in
  the VS Code extension, which has no custom status line and hides its own indicator
  until 50%.

## Installing

Two routes, and the difference between them is what you get rather than how it
arrives: the Claude Code plugin installs everything, and every other route installs
the skills.

### Claude Code — everything

At the Claude Code prompt:

```
/plugin marketplace add https://github.com/nauman73/agent-workbench.git
/plugin install nh-workbench@nh-agent-workbench
```

Typing `/plugin` on its own opens the plugin manager, where you can browse what is
installed, enable or disable a set, and configure it — worth knowing, as it is the
quickest way to turn these off again without uninstalling.

> **⚠ `/plugin` works only in the terminal CLI.** The VS Code extension answers
> `/plugin isn't available in this environment`. Use the shell commands below there
> instead — the extension loads and runs installed plugins normally, it just cannot
> manage them.

**In your shell** — works wherever the `claude` CLI is installed, including for VS
Code extension users:

```bash
claude plugin marketplace add https://github.com/nauman73/agent-workbench.git
claude plugin install nh-workbench@nh-agent-workbench          # --scope user|project|local
claude plugin details nh-workbench                            # inventory + token cost
claude plugin list
```

Skills arrive namespaced — `/nh-workbench:session-handoff`. The hook is not
namespaced and needs no invocation; it starts running on the next session. Start a
new session afterwards either way; a running one will not see any of it. Later,
`marketplace update` pulls new additions, `plugin update nh-workbench` moves to the
latest version, and `plugin uninstall nh-workbench` removes the set — each available
in both forms.

> **Already have one of these skills in `~/.claude/skills/`?** You will then have it
> twice — once unnamespaced from your own folder, once as
> `/nh-workbench:session-handoff` — with both descriptions loaded at startup and no
> clear answer as to which fires. Move your copy aside first, or install to
> `--scope project` in a repo you are only testing in. The same applies to the hook:
> if you already have it wired into `~/.claude/settings.json`, remove that
> registration when you install the plugin, or it runs twice per turn.

### Any other agent — the skills

Nothing below carries the hook. A hook has to be *registered* with the harness, and
only a plugin carries its own registration; [`hooks/README.md`](hooks/README.md)
explains the asymmetry and gives the `settings.json` block to paste if you would
rather wire it up by hand.

**With the `skills` CLI.** [`skills`](https://github.com/vercel-labs/skills) finds
this repo's root-level `skills/` directory on its own, and reads the manifests in
`.claude-plugin/` too:

```bash
REPO=https://github.com/nauman73/agent-workbench.git

npx skills add $REPO --list                      # inspect first
npx skills add $REPO --skill session-handoff     # one skill
npx skills add $REPO -a claude-code -a cursor    # chosen agents
npx skills add $REPO -g                          # global install
```

Installs are symlinks by default — add `--copy` for independent files you can edit
freely, and `-y` to run unattended. `--skill` repeats per skill; it does not take a
list.

> **Note:** this CLI reports install telemetry for repositories GitHub confirms are
> public. `DISABLE_TELEMETRY=1` or `DO_NOT_TRACK=1` turns it off, and neither the
> plugin nor the by-hand route below involves it.

**By hand.** A skill is a directory, so put it where your agent looks:

```bash
git clone https://github.com/nauman73/agent-workbench.git

cp -r agent-workbench/skills/session-handoff your-project/.claude/skills/   # one project
cp -r agent-workbench/skills/session-handoff ~/.claude/skills/              # everywhere
```

Start a new session, or run `/skills`, and it will be picked up.

**Where each agent looks:**

| Agent | Per-project | Global |
|---|---|---|
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| GitHub Copilot | `.agents/skills/` | `~/.copilot/skills/` |
| Cursor | `.agents/skills/` | `~/.cursor/skills/` |
| Codex | `.agents/skills/` | `~/.codex/skills/` |

The `skills` CLI covers many more than these four; run it to see the current list.
Where an agent has no skills mechanism at all, commit the folder to your repo and
reference it from `AGENTS.md`, instructing the agent to consult the relevant
`SKILL.md` before that kind of task.

## Before you run any of this

These act on your repository, and one of them can copy your session history into it.
That is worth understanding rather than trusting. Each folder holds a `README.md`
covering what the thing is for and the reasoning behind how it behaves, next to the
`SKILL.md` or script that actually runs.

**A hook asks more of you than a skill does.** A skill sits inert until your request
matches its description, so the worst an unread one does is nothing. A hook runs on
every turn from the moment it is installed, whether or not it has anything to say, and
you do not invoke it — which means you are unlikely to be watching the first time it
behaves unexpectedly. Some hook events can also inject text straight into the model's
context, so a hook is in a position to influence what the agent does, not merely to
report to you.

None of that makes hooks a bad idea; it makes an unread one a bad idea. Read the
hook's own `README.md` before installing it — [`hooks/README.md`](hooks/README.md)
here — and expect it to tell you what it reads, what it writes, and what it can put in
front of the model. If it does not, that is the answer.

## Licence

[MIT](LICENSE). Fork it, strip it, rewrite it.
