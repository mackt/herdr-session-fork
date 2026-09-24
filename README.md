# herdr-session-fork

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

Fork the focused **Claude Code**, **Codex**, **Pi** or **Grok** conversation
into somewhere else in Herdr, picked from a fuzzy list. Press one key in the
agent's pane and choose where the copy should live:

```
↔ split next to this pane (same directory) /Users/mack/code/personal/hugo-theme-kami
1. blog                                     ~/code/personal/blog
  └ ＋ new worktree                         blog · enter a branch name
2. pi-language-tutor                        ~/code/personal/pi-extensions/pi-language-tutor
  └ ＋ new worktree
5. kami                                     ~/code/personal/hugo-theme-kami
6. herdr                                    ~/code/personal/hugo-theme-kami
  └ 7. test                                 ~/.herdr/worktrees/hugo-theme-kami/test
  └ feat/x  · not open                      ~/.herdr/worktrees/hugo-theme-kami/feat-x
  └ ＋ new worktree                         hugo-theme-kami · enter a branch name
```

- **split next to this pane** — a sibling pane in the same directory, for a side-by-side branch of the conversation
- **an open workspace** — a new tab there
- **a worktree of the same repo that is not open yet** — opened as a workspace first
- **＋ new worktree** — creates a git worktree on a new branch, then forks into it

Workspaces are grouped per git repository: the main checkout on top, its
linked worktrees (open or not) indented beneath, plus one "new worktree"
entry per repo. The repo the source pane sits in is always listed, even when
none of its workspaces are open.

## What "fork" means

The original session is left untouched. The copy is a real fork made by the
agent's own CLI, so both sides keep the full history and continue
independently:

| agent  | command                                            | session reference Herdr reports |
|--------|----------------------------------------------------|---------------------------------|
| claude | `claude --resume <id> --fork-session`              | id                              |
| codex  | `codex fork <id>`                                  | id (via hook events)            |
| pi     | `pi --fork <session-file-or-id>`                   | session file path               |
| grok   | `grok --resume <id> --fork-session --cwd <dest>`   | id                              |

When the destination directory differs from the source, the forked agent
receives one note saying the working directory changed, so it stops treating
paths from the old conversation as current (configurable, see below).

## Requirements

- Herdr ≥ 0.9.0
- The Herdr integration for the agent you want to fork
  (`herdr integration install claude|codex|pi|grok`) — that is how Herdr learns
  the session id
- `fzf`, `jq`, bash 3.2+ (macOS default is fine)

## Install

```bash
herdr plugin install mackt/herdr-session-fork
```

For local development:

```bash
git clone https://github.com/mackt/herdr-session-fork
herdr plugin link /path/to/herdr-session-fork
```

Bind a key in `~/.config/herdr/config.toml` and run `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+shift+f"
type = "plugin_action"
command = "mackt.session-fork.fork"
description = "fork agent session to…"
```

The action is also available from Herdr's action menu.

## Configuration

Optional `config.sh` in `$(herdr plugin config-dir mackt.session-fork)`,
sourced by every run:

```bash
UI_LANG=""                   # "en" or "zh"; empty = follow $LANG
NOTE_ON_FORK=1               # 0 = do not send the "cwd changed" note
NOTE_TEMPLATE="…"            # custom note (English by default); {src_cwd} and {dst_cwd} are substituted
SPLIT_RATIO=""               # e.g. 0.5, for the split-here target
SHOW_DETACHED_WORKTREES=0    # 1 = also list detached-HEAD worktrees
STARTUP_PROMPT_TIMEOUT_MS=300000  # how long to wait for you to answer a startup prompt
```

## How it works

`bin/session-fork` (the action) reads the focused pane from
`HERDR_PLUGIN_CONTEXT_JSON`, confirms it is a supported agent with a known
session id, and opens `bin/picker` in a session-modal popup with the source
details in its environment.

The picker builds its list from `herdr api snapshot` and one
`herdr worktree list` per distinct workspace directory, runs `fzf`, creates the
destination pane (`pane split` / `tab create` / `worktree open` /
`worktree create`), waits for its shell prompt, and calls
`herdr agent start … -- <fork args>`.

Everything goes through the Herdr CLI (`HERDR_BIN_PATH`); nothing touches
session files directly.

Logs: `herdr plugin log list --plugin mackt.session-fork` and
`$HERDR_PLUGIN_STATE_DIR/session-fork.log`.

## Notes

- Codex reports its session id through hook events. If Herdr has not received
  one yet, the plugin falls back to the newest Codex rollout whose `cwd`
  matches the pane and says so in a notification.
- Grok pins a forked session to the source directory unless `--cwd` is given,
  so the plugin always passes the destination.
- If the agent stops at a startup prompt (Claude Code's "trust this folder?"
  on a directory it has not seen before), the plugin sends a notification,
  focuses the pane and waits for you to answer, then finishes the handoff.
- Adding another agent is a `case` branch in `start_forked_agent`
  (`lib/common.sh`) plus the allow-list in `bin/session-fork`, provided the
  agent's CLI can fork a session by id.

## License

MIT
