# codex-converge

A [Claude Code](https://claude.com/claude-code) skill that makes **Claude, OpenAI Codex and Google Gemini review each other's work until they agree**.

One agent writes a solution, such as a plan, a design, a bug diagnosis or a patch proposal. The other agent reviews it, or a panel of several reviewers reviews it in parallel. With `--trio`, all three models take part in one run: one writes, the other two review. The author revises and the loop repeats until one of these happens:

- every reviewer approves in the same round,
- the agents deadlock, or
- the round cap is reached.

Gemini takes part through Google's Antigravity CLI (`agy`).

The loop runs **detached**, so it keeps going if you close your terminal or your SSH connection drops. Every agent, and every subagent it spawns, runs **strictly read-only**, so an unattended loop can never modify your project.

```
          ┌──────────── task ────────────┐
          ▼                              │
   author drafts ──► reviewer reviews ──► VERDICT: APPROVE ──► converged
          ▲                 │
          │     VERDICT: CHANGES_REQUIRED
          └──── author revises (or records dissent)
```

## Why

A single model reviewing its own work tends to agree with itself. Different models from different vendors catch different mistakes. The loop has a few rules that stop it from going around in circles:

- The reviewer must end with a greppable `VERDICT: APPROVE` or `VERDICT: CHANGES_REQUIRED`.
- Every issue is tagged `[BLOCKER]`, `[MAJOR]` or `[NIT]`. Only blockers and majors hold up convergence.
- The reviewer is told explicitly that approving is a valid outcome and that it should not invent work.
- The author is told **not** to give in on points it believes are right. It records those refusals in `dissent.md`, and the reviewer has to engage with that reasoning instead of repeating itself.
- A stall detector ends the run after two consecutive rounds that leave the solution byte-identical.

## Requirements

- **bash**, plus the standard coreutils (`timeout`, `nohup`, `awk`, `cksum`). `setsid` and `flock` are used when present. Tested on Linux. It should also work on macOS and on Git Bash for Windows (on Windows it falls back to `nohup` + `disown`).
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** (`claude`) on your `PATH` and logged in.
- **[OpenAI Codex CLI](https://github.com/openai/codex)** (`codex`) on your `PATH` and logged in.
- Optional, for Gemini: the **Antigravity CLI** (`agy`) on your `PATH` or in `~/.gemini/bin`, signed in once interactively (run `agy` in a terminal: headless runs cannot complete a login), plus `jq` or `python3`.

Only the CLIs a run actually uses are required. Check them:

```bash
claude --version && codex --version && agy --help >/dev/null && echo agy ok
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

> Have all three models (Claude, Codex and Gemini) work out the root cause of the leak in `cache/`, and let them argue with each other.

Claude expands your request into a self-contained task, starts the loop in the background, reports the run id and hands control back to you. Later, ask *"how is the converge run going?"* and Claude will check its status and summarize where the two agents still disagree.

### From the shell

```bash
S=~/.claude/skills/codex-converge/converge.sh

$S start --task "Propose a schema migration plan for ... (self-contained description)" \
         --dir ~/my-project --rounds 4

$S status          # state, round, per-reviewer verdicts, recent log lines
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
| `--author claude\|codex\|agy` | Which agent writes; without `--reviewer` or `--trio`, one other CLI reviews (Codex for a Claude author, Claude otherwise) | `claude` |
| `--reviewer SPEC` | Add a reviewer to the panel (repeatable, up to 6). See [Reviewer panel](#reviewer-panel). | one reviewer, the other CLI |
| `--trio` | The panel is the two CLIs other than the author, so all three models work on the task | off |
| `--crosstalk` | From round 2, each reviewer also reads the other reviewers' previous-round reviews. See [Crosstalk](#crosstalk). | off |
| `--agy-model M` | Gemini model for `agy` agents | `gemini-4-argon` |
| `--agy-effort E` | Gemini effort: `low`, `medium` or `high` | the model's default |
| `--codex-model M` | Codex model slug | your `~/.codex/config.toml` |
| `--codex-effort E` | Codex reasoning effort: `low`, `medium`, `high`, `xhigh` or `max` | config |
| `--codex-tier T` | Codex service tier, e.g. `fast` | config |
| `--claude-model M` | Claude model alias, e.g. `opus` | CLI default |
| `--claude-effort E` | Claude effort: `low`, `medium`, `high`, `xhigh` or `max` | the calling agent's effort (`$CLAUDE_EFFORT`) |
| `--claude-subagents N` | Each Claude agent may use up to N parallel read-only subagents. **Soft cap**: enforced by the prompt only. `0` means none. | none |
| `--codex-subagents N` | Each Codex agent is capped at N parallel subagents. **Hard cap**, set through Codex config; subagents cannot spawn their own. `0` turns Codex subagents off. | your `~/.codex/config.toml` |
| `--subagents N` | Sets both of the above; the per-side flags win. `agy` agents never get subagents. | unset |
| `--fresh-context` | Start a new context for every call instead of keeping one session per agent | off |
| `--foreground` | Run inline instead of detaching (for debugging) | off |

Environment variables:

- `CODEX_CONVERGE_HOME`: where runs are stored (default `~/.codex-converge`).
- `CODEX_CONVERGE_CALL_TIMEOUT`: per-agent-call timeout in seconds (default `1800`).
- `CODEX_CONVERGE_AGY_MODEL`: default Gemini model (default `gemini-4-argon`).

**Write a self-contained task.** Each agent is a separate process that knows nothing about your chat. A task like "fix the bug we discussed" means nothing to it.

**Cost:** each round is one author run plus one run per reviewer, billed against the quota of every CLI involved. Subagents add more. When the agents converge, it is usually by round 3.

**Speed:** reviewers run at the same time, so a round takes as long as the slowest reviewer rather than the sum. `--subagents N` also lets each agent read evidence in parallel. Caps apply per agent, and `start` prints the worst-case number of agent processes running at once.

### Reviewer panel

```bash
$S start --task "..." --dir ~/my-project \
   --reviewer "cli=codex,model=gpt-6-astra,effort=high,subagents=4" \
   --reviewer "cli=agy,effort=high" \
   --reviewer "cli=claude,focus=numerical stability, units and edge cases"

$S start --task "..." --dir ~/my-project --trio --crosstalk   # Claude writes, Codex + Gemini review and talk
```

- A spec is comma-separated `key=value`. `cli=claude|codex|agy` is required. `model`, `effort`, `tier` (Codex only) and `subagents` (not `agy`) fall back to the side-wide flags. `focus=` must come last and takes the rest of the string, commas included. A reviewer may use the same CLI as the author.
- The author is `A` and the reviewers are `R1..RK`, in flag order. Every reviewer reviews every round, including ones that approved earlier, because a revision can undo something they approved.
- **Converged** means every reviewer returned a review this round and every one says APPROVE.
- A reviewer that errors or times out is logged, the round continues without it, and it is retried next round. A round with a failed reviewer can still revise but cannot converge. The run fails only if every reviewer fails in the same round.
- The author sees all the reviews, headed by reviewer id, and answers every `[BLOCKER]`/`[MAJOR]` by id. When two reviewers contradict each other, the author picks one and records the other in `dissent.md` as `[R1 vs R2]`.
- Reviewers see the solution, `changelog.md` and `dissent.md`, but not each other's reviews unless `--crosstalk` is on. A reviewer given a `focus` reviews only that aspect.
- Warns above 3 reviewers: past that, the author's answer to each review gets thinner.

### Crosstalk

By default the reviewers only talk to the author, so their reviews stay independent. With `--crosstalk` they also talk to each other. From round 2, each reviewer reads the other reviewers' reviews from the previous round (skipping any call that failed) and reacts to them: `[AGREE Rk]` endorses a point it checked, `[DISPUTE Rk]` argues against one. A reviewer may raise someone else's point as its own only after verifying it. The author is told how to weigh those tags. Round 1 is always independent.

## Output

Every run gets its own directory, `~/.codex-converge/runs/<id>/`:

| File | Contents |
|---|---|
| `solution.md` | The current draft. This is the deliverable. |
| `review-N-R<k>.md` | Reviewer k's review in round N, ending in a `VERDICT:` line (runs before 1.4.0: `review-N.md`) |
| `dissent.md` | Points the author refused to concede, with its reasoning |
| `changelog.md` | What changed each round and what was rejected |
| `loop.log` | Timestamped run log |
| `meta.env`, `state.env` | Run configuration and live state |

### Terminal states

| Status | Meaning |
|---|---|
| `converged` | Every reviewer returned `VERDICT: APPROVE` in the same round. |
| `max-rounds` | The cap was reached with the agents still disagreeing. The open objections in the last review are real. |
| `stalled` | Two rounds passed with no change to the solution. This is usually a genuine deadlock. |
| `failed` | The author call, or every reviewer in one round, errored or timed out. Check `loop.log`. |
| `stopped` | The run was ended by `stop` or by a signal. |

**Always read `dissent.md`, even when the run converged.** A non-empty dissent file means the agents agreed on everything *except* those points, and that leftover disagreement is often the most useful output. Also, `converged` does not mean "correct". It means the reviewer stopped objecting.

## Safety model

- `claude` runs with `--strict-mcp-config --allowed-tools "Read Glob Grep"`, which means no Write, no Edit, no Bash and no MCP connector tools.
- With Claude subagents on, it also gets `--tools "Read,Glob,Grep,Agent"` (no other tool exists in the process), `--disallowed-tools "Bash Write Edit NotebookEdit"`, and one custom subagent, `reader`, limited to Read, Glob and Grep, which cannot spawn further subagents.
- `codex` runs with `-s read-only`. Resumed sessions force `sandbox_mode="read-only"`. Codex subagents inherit that sandbox, and `agents.max_depth=1` stops them spawning their own.
- Both were live-tested on 2026-09-24 (Claude Code 2.1.267, codex-cli 0.155.1): subagents told to write a file were blocked on both sides. Re-run that test after upgrading either CLI.
- `agy` may have no usable sandbox: its terminal sandbox needs unprivileged user namespaces, which many clusters disable. It therefore gets three independent layers:
  - `--mode plan`.
  - Per-call `--settings` with the `request-review` policy and deny rules for commands, writes, MCP and network. Headless runs refuse anything that needs an approval.
  - A `PreToolUse` hook, generated per run, that refuses every tool except `read_file`, and refuses `read_file` outside the context and run directories. The hook only ever refuses, so a payload it cannot parse ends in a refusal. It also beats any global allow rules in `~/.gemini/config/config.json`, which would otherwise auto-approve the commands they name.

  `agy` runs with its working directory in an empty per-agent workspace inside the run directory, and never gets subagents. Live-tested on 2026-11-01 (agy 1.4.12): `write_file`, `edit_file` and `run_command` (`ls`, `touch`, a nested `agy`) were all refused, and the context directory, `.git` included, was left untouched.
- `agy`'s headless toolset has no directory listing or search, so each run writes a list of the context directory's git-tracked files to `agy-files.txt` in the run directory for `agy` agents to read.
- If `agy`'s own policy refuses an action, the headless turn ends mid-reply. The loop treats that as a failed call, so a cut-off reply never becomes the solution or a review.
- Every file the loop produces is written by `converge.sh` itself, and only into the run directory.

The worst case for an unattended run is therefore a bad document in a scratch directory, never a damaged repository. To apply the agreed solution, read `solution.md` and apply it yourself in a normal, supervised session. Please don't fork this with write permissions turned on.

## Persistent context

By default each agent keeps one conversation for the whole run:

- **Claude:** `--session-id` on the first call, then `--resume` on later calls.
- **Codex:** `--json` on the first call to capture the thread id, then `codex exec resume` on later calls.
- **Gemini (`agy`):** the first call's `--output-format json` result carries `conversation_id`, then `--conversation` on later calls.

On later rounds the agents are told to re-read only the files that changed, which saves re-reading all the evidence every round. Every panel reviewer keeps its own session (`.claude_session.<id>`, `.codex_session.<id>`, `.agy_session.<id>` in the run directory). Subagents always start empty, so agents are told to use them only for reading they have not done yet. Pass `--fresh-context` to start every call from scratch instead.

## License

[MIT](LICENSE)
