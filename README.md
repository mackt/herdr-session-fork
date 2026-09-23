# Session Fork — Herdr plugin

Fork the focused **Claude Code**, **Codex**, **Pi** or **Grok** conversation
into somewhere else in Herdr, picked from a fuzzy list:

- **↔ 当前 workspace 分屏** — split beside the current pane (same directory)
- **＋ 新建 worktree** — create a git worktree on a new branch and fork into it
- **any open workspace** — opens a new tab there
- **any unopened worktree** of the same repo — opens it as a workspace first

The original session is left untouched. The fork is a real fork, so both
sides keep the full history and continue independently:

| agent  | command                                   | session ref Herdr reports |
|--------|-------------------------------------------|---------------------------|
| claude | `claude --resume <id> --fork-session`     | id                        |
| codex  | `codex fork <id>`                         | id (hook-reported)        |
| pi     | `pi --fork <path-or-id>`                  | session file path         |
| grok   | `grok --resume <id> --fork-session`       | id                        | When the destination directory
differs from the source, the forked agent gets one note telling it the cwd
changed (configurable).

## Requirements

- Herdr ≥ 0.9.0 with the Claude Code and/or Codex integration installed
  (`herdr integration install claude` / `codex`) so Herdr knows the session id
- `fzf`, `jq`, bash 3.2+

## Install

```bash
herdr plugin install mackt/herdr-session-fork
```

or, for local development:

```bash
git clone https://github.com/mackt/herdr-session-fork
herdr plugin link /path/to/herdr-session-fork
```

Bind a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+shift+f"
type = "plugin_action"
command = "mackt.session-fork.fork"
description = "fork agent session to…"
```

then `herdr server reload-config`. The action is also in Herdr's action menu.

## Config

Optional `config.sh` in `$(herdr plugin config-dir mackt.session-fork)`:

```bash
NOTE_ON_FORK=1            # 0 to skip the "cwd changed" note
NOTE_TEMPLATE='这个会话是从 {src_cwd} fork 过来的，现在的工作目录是 {dst_cwd}。…'
SPLIT_RATIO=""            # e.g. 0.5, for the split-here target
```

## How it works

`bin/session-fork` (the action) reads the focused pane from
`HERDR_PLUGIN_CONTEXT_JSON`, confirms it is a claude/codex pane with a known
session id, and opens `bin/picker` in a session-modal popup with the source
details in its environment. The picker builds its list from
`herdr api snapshot` and `herdr worktree list`, runs fzf, creates the
destination pane (`pane split` / `tab create` / `worktree open` /
`worktree create`), waits for its shell prompt, and calls
`herdr agent start … -- <fork args>`.

Logs: `herdr plugin log list --plugin mackt.session-fork` and
`$HERDR_PLUGIN_STATE_DIR/session-fork.log`.

## Notes

- Codex reports its session id to Herdr through hook events. If Herdr has not
  received one yet, the plugin falls back to the newest Codex rollout whose
  `cwd` matches the pane and says so in a notification.
- Only `claude`, `codex`, `pi` and `grok` are supported; other agents get a
  clear error. Adding one is a `case` branch in `start_forked_agent`
  (`lib/common.sh`) plus the allow-list in `bin/session-fork`.
