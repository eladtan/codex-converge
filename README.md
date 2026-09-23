# codex-converge

A [Claude Code](https://claude.com/claude-code) skill that makes **Claude and OpenAI Codex review each other's work until they agree**.

One agent writes a solution, such as a plan, a design, a bug diagnosis or a patch proposal. The other agent reviews it. The author revises and the loop repeats until one of these happens:

- the reviewer approves,
- the two agents deadlock, or
- the round cap is reached.

The loop runs **detached**, so it keeps going if you close your terminal or your SSH connection drops. Both agents run **strictly read-only**, so an unattended loop can never modify your project.

```
          ┌──────────── task ────────────┐
          ▼                              │
   author drafts ──► reviewer reviews ──► VERDICT: APPROVE ──► converged
          ▲                 │
          │     VERDICT: CHANGES_REQUIRED
          └──── author revises (or records dissent)
```

## Why

A single model reviewing its own work tends to agree with itself. Two different models from two different vendors catch different mistakes. The loop has a few rules that stop it from going around in circles:

- The reviewer must end with a greppable `VERDICT: APPROVE` or `VERDICT: CHANGES_REQUIRED`.
- Every issue is tagged `[BLOCKER]`, `[MAJOR]` or `[NIT]`. Only blockers and majors hold up convergence.
- The reviewer is told explicitly that approving is a valid outcome and that it should not invent work.
- The author is told **not** to give in on points it believes are right. It records those refusals in `dissent.md`, and the reviewer has to engage with that reasoning instead of repeating itself.
- A stall detector ends the run after two consecutive rounds that leave the solution byte-identical.

## Requirements

- **bash**, plus the standard coreutils (`timeout`, `nohup`, `awk`, `cksum`). `setsid` and `flock` are used when present. Tested on Linux. It should also work on macOS and on Git Bash for Windows (on Windows it falls back to `nohup` + `disown`).
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** (`claude`) on your `PATH` and logged in.
- **[OpenAI Codex CLI](https://github.com/openai/codex)** (`codex`) on your `PATH` and logged in.

Check both:

```bash
claude --version && codex --version
```

## Install

Clone the repo straight into your personal Claude Code skills directory:

```bash
git clone https://github.com/eladtan/codex-converge.git ~/.claude/skills/codex-converge
```

To install it for a single project instead, clone it into that project's `.claude/skills/codex-converge`.

Restart Claude Code (or start a new session). `codex-converge` should then appear in the skill list.

### Update

```bash
git -C ~/.claude/skills/codex-converge pull
```

> Do not pull while a loop is running. Running loops read `converge.sh` incrementally, so rewriting the file in place can break them. Check with `converge.sh list` first.

### Uninstall

```bash
rm -rf ~/.claude/skills/codex-converge
```

Run artifacts live separately in `~/.codex-converge/`. Delete that directory too if you no longer want them.

## Usage

### From Claude Code (recommended)

Just ask. For example:

> Have Claude and Codex converge on a plan for migrating our auth middleware to the new session store. Read `src/auth/` for context.

> /codex-converge Review the retry logic in `worker/queue.py` and agree on the root cause of the duplicate-delivery bug. rounds=3

Claude expands your request into a self-contained task, starts the loop in the background, reports the run id and hands control back to you. Later, ask *"how is the converge run going?"* and Claude will check its status and summarize where the two agents still disagree.

### From the shell

```bash
S=~/.claude/skills/codex-converge/converge.sh

$S start --task "Propose a schema migration plan for ... (self-contained description)" \
         --dir ~/my-project --rounds 4

$S status          # state, round, last verdict, recent log lines
$S show            # print the current solution
$S list            # all runs, newest first
$S watch           # follow the log (Ctrl-C only stops watching)
$S stop            # terminate the loop
```

With no run id, `status`, `show`, `watch` and `stop` act on the most recent run.

### Options for `start`

| Flag | Meaning | Default |
|---|---|---|
| `--task "<text>"` | What to converge on. Use `--task-file FILE` for long tasks. | required |
| `--dir DIR` | Directory the agents read for context. It is never written to. | current dir |
| `--rounds N` | Maximum number of review rounds | 4 |
| `--author claude\|codex` | Which agent writes; the other reviews | `claude` |
| `--codex-model M` | Codex model slug | your `~/.codex/config.toml` |
| `--codex-effort E` | Codex reasoning effort: `low`, `medium`, `high`, `xhigh` or `max` | config |
| `--codex-tier T` | Codex service tier, e.g. `fast` | config |
| `--claude-model M` | Claude model alias, e.g. `opus` | CLI default |
| `--fresh-context` | Start a new context for every call instead of keeping one session per agent | off |
| `--foreground` | Run inline instead of detaching (for debugging) | off |

Environment variables:

- `CODEX_CONVERGE_HOME`: where runs are stored (default `~/.codex-converge`).
- `CODEX_CONVERGE_CALL_TIMEOUT`: per-agent-call timeout in seconds (default `1800`).

**Write a self-contained task.** Each agent is a separate process that knows nothing about your chat. A task like "fix the bug we discussed" means nothing to it.

**Cost:** each round is two full agent runs, one billed against your Anthropic quota and one against your OpenAI quota. When the agents converge, it is usually by round 3.

## Output

Every run gets its own directory, `~/.codex-converge/runs/<id>/`:

| File | Contents |
|---|---|
| `solution.md` | The current draft. This is the deliverable. |
| `review-N.md` | Each round's review, ending in a `VERDICT:` line |
| `dissent.md` | Points the author refused to concede, with its reasoning |
| `changelog.md` | What changed each round and what was rejected |
| `loop.log` | Timestamped run log |
| `meta.env`, `state.env` | Run configuration and live state |

### Terminal states

| Status | Meaning |
|---|---|
| `converged` | The reviewer returned `VERDICT: APPROVE`. |
| `max-rounds` | The cap was reached with the agents still disagreeing. The open objections in the last review are real. |
| `stalled` | Two rounds passed with no change to the solution. This is usually a genuine deadlock. |
| `failed` | A CLI call errored or timed out. Check `loop.log`. |
| `stopped` | The run was ended by `stop` or by a signal. |

**Always read `dissent.md`, even when the run converged.** A non-empty dissent file means the agents agreed on everything *except* those points, and that leftover disagreement is often the most useful output. Also, `converged` does not mean "correct". It means the reviewer stopped objecting.

## Safety model

- `claude` runs with `--allowed-tools "Read Glob Grep"`, which means no Write, no Edit and no Bash.
- `codex` runs with `-s read-only`. Resumed sessions force `sandbox_mode="read-only"`.
- Every file the loop produces is written by `converge.sh` itself, and only into the run directory.

The worst case for an unattended run is therefore a bad document in a scratch directory, never a damaged repository. To apply the agreed solution, read `solution.md` and apply it yourself in a normal, supervised session. Please don't fork this with write permissions turned on.

## Persistent context

By default each agent keeps one conversation for the whole run:

- **Claude:** `--session-id` on the first call, then `--resume` on later calls.
- **Codex:** `--json` on the first call to capture the thread id, then `codex exec resume` on later calls.

On later rounds the agents are told to re-read only the files that changed, which saves re-reading all the evidence every round. Pass `--fresh-context` to start every call from scratch instead.

## License

[MIT](LICENSE)
