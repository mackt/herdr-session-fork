# herdr-session-fork

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

把当前 pane 里的 **Claude Code / Codex / Pi / Grok** 对话 fork 到 Herdr 的另一个
地方。在 agent 的 pane 里按一个键，从模糊列表里选目的地（界面和 Herdr 本身一样是英文）：

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

- **split next to this pane** — 目录不变，在旁边开一个 pane，适合并排开一个分支对话
- **已打开的 workspace** — 在那个 workspace 里开新 tab
- **同一仓库里还没打开的 worktree** — 先把它作为 workspace 打开
- **＋ new worktree** — 新建分支和 git worktree，再 fork 进去

列表按 git 仓库分组：主检出 workspace 在顶层，同仓库的 worktree（不管开没开）
缩进挂在下面，每个仓库末尾一个「new worktree」。源 pane 所在的仓库一定会出现，
即使它一个 workspace 都没开。

## fork 是什么意思

原会话不动。副本是用 agent 自己的 CLI 做的真正 fork，两边都保留完整历史，
之后各聊各的：

| agent  | 命令                                               | Herdr 上报的会话引用     |
|--------|----------------------------------------------------|--------------------------|
| claude | `claude --resume <id> --fork-session`              | id                       |
| codex  | `codex fork <id>`                                  | id（hook 事件上报）      |
| pi     | `pi --fork <session 文件或 id>`                    | session 文件路径         |
| grok   | `grok --resume <id> --fork-session --cwd <目的地>` | id                       |

目的地目录和源目录不同时，fork 出来的 agent 会收到一句说明「工作目录已切换」，
免得它继续把旧对话里的路径当成当前目录（可配置，见下文）。

## 依赖

- Herdr ≥ 0.9.0
- 要 fork 的 agent 对应的 Herdr integration
  （`herdr integration install claude|codex|pi|grok`），Herdr 靠它拿到 session id
- `fzf`、`jq`、bash 3.2+（macOS 自带的就行）

## 安装

```bash
herdr plugin install mackt/herdr-session-fork
```

本地开发：

```bash
git clone https://github.com/mackt/herdr-session-fork
herdr plugin link /path/to/herdr-session-fork
```

在 `~/.config/herdr/config.toml` 里绑一个键，然后 `herdr server reload-config`：

```toml
[[keys.command]]
key = "prefix+shift+f"
type = "plugin_action"
command = "mackt.session-fork.fork"
description = "fork agent session to…"
```

Herdr 的 action 菜单里也能找到这个 action。

## 配置

可选的 `config.sh`，放在 `$(herdr plugin config-dir mackt.session-fork)` 下，
每次运行都会 source：

```bash
NOTE_ON_FORK=1               # 0 = 不发「工作目录已切换」那句说明
NOTE_TEMPLATE="…"            # 自定义说明；{src_cwd} 和 {dst_cwd} 会被替换
SPLIT_RATIO=""               # 例如 0.5，用于「分屏」目标
SHOW_DETACHED_WORKTREES=0    # 1 = 也列出 detached HEAD 的 worktree
STARTUP_PROMPT_TIMEOUT_MS=300000  # 等你处理启动提示的最长时间
```

## 工作原理

`bin/session-fork`（action）从 `HERDR_PLUGIN_CONTEXT_JSON` 读当前 pane，确认它是
受支持的 agent 且有已知的 session id，然后把源信息放进环境变量，在 session
级 popup 里打开 `bin/picker`。

picker 用 `herdr api snapshot` 加上每个不同 workspace 目录一次 `herdr worktree list`
生成列表，跑 `fzf`，创建目的地 pane（`pane split` / `tab create` /
`worktree open` / `worktree create`），等它到 shell 提示符，再调用
`herdr agent start … -- <fork 参数>`。

所有操作都走 Herdr CLI（`HERDR_BIN_PATH`），不直接碰 session 文件。

日志：`herdr plugin log list --plugin mackt.session-fork` 和
`$HERDR_PLUGIN_STATE_DIR/session-fork.log`。

## 说明

- Codex 的 session id 靠 hook 事件上报。Herdr 还没收到时，插件会退而找 `cwd`
  与该 pane 相同的最新 Codex rollout 文件，并用通知提示这是猜的。
- Grok 不传 `--cwd` 的话会把 fork 出来的会话钉在源目录，所以插件总是传目的地。
- agent 启动时停在提示上（比如 Claude Code 第一次进入某个目录时的「是否信任该目录」），
  插件会发通知、聚焦那个 pane，等你处理完再继续完成交接。
- 新增 agent 只需在 `lib/common.sh` 的 `start_forked_agent` 加一个 `case`
  分支，再把它加进 `bin/session-fork` 的白名单，前提是该 agent 的 CLI 支持按 id
  fork 会话。

## 许可

MIT
