# Shared helpers for session-fork scripts. Sourced, not executed.
# Requires: bash 4+, jq, herdr (via HERDR_BIN_PATH).

HERDR="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="${HERDR_PLUGIN_ID:-mackt.session-fork}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/session-fork}"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-}"
LOG_FILE="$STATE_DIR/session-fork.log"

# ---- user config (optional) -------------------------------------------------
# $HERDR_PLUGIN_CONFIG_DIR/config.sh may override these.
NOTE_ON_FORK=1
NOTE_TEMPLATE=""            # empty → language default below
SPLIT_RATIO=""
SHOW_DETACHED_WORKTREES=0
UI_LANG=""                  # zh | en; empty → from $LANG
if [[ -n "$CONFIG_DIR" && -f "$CONFIG_DIR/config.sh" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_DIR/config.sh"
fi

# ---- UI strings -------------------------------------------------------------
if [[ -z "$UI_LANG" ]]; then
  case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in zh*) UI_LANG=zh ;; *) UI_LANG=en ;; esac
fi
if [[ "$UI_LANG" == zh ]]; then
  L_SPLIT_HERE='↔ 当前 workspace 分屏'
  L_NEW_WORKTREE='＋ 新建 worktree'
  L_NEW_HINT='输入分支名'
  L_MAIN_CLOSED='·主检出，未打开'
  L_NOT_OPEN='·未打开'
  L_HEADER='fork %s 会话%s → 目的地'      # kind, " · title"
  L_PROMPT='目的地 > '
  L_ASK_BRANCH='  在 %s 新建 worktree，分支名（基于该仓库 HEAD，留空取消）: '
  L_STARTING='  启动 %s fork %s → %s …'
  L_DONE_TITLE='session-fork 完成'
  L_ERR_NO_PANE='无法确定当前 pane'
  L_ERR_NO_AGENT='当前 pane 没有检测到 agent'
  L_ERR_UNSUPPORTED='暂不支持 fork %s 会话（支持 claude / codex / pi / grok）'
  L_ERR_NO_SID='herdr 还没拿到这个 %s 会话的 session id（integration 装了吗？）'
  L_SID_GUESSED='codex session id 是按目录猜的：%s…'
  [[ -n "$NOTE_TEMPLATE" ]] || NOTE_TEMPLATE='这个会话是从 {src_cwd} fork 过来的，现在的工作目录是 {dst_cwd}。之前对话里提到的相对路径和分支都指旧目录，后续操作请以当前目录为准。'
else
  L_SPLIT_HERE='↔ split in current workspace'
  L_NEW_WORKTREE='＋ new worktree'
  L_NEW_HINT='enter a branch name'
  L_MAIN_CLOSED='· main checkout, not open'
  L_NOT_OPEN='· not open'
  L_HEADER='fork %s session%s → destination'
  L_PROMPT='destination > '
  L_ASK_BRANCH='  new worktree in %s — branch name (from that repo'"'"'s HEAD, empty to cancel): '
  L_STARTING='  starting %s fork %s → %s …'
  L_DONE_TITLE='session-fork ready'
  L_ERR_NO_PANE='cannot determine the focused pane'
  L_ERR_NO_AGENT='no agent detected in the focused pane'
  L_ERR_UNSUPPORTED='forking %s sessions is not supported (claude / codex / pi / grok)'
  L_ERR_NO_SID='Herdr has no session id for this %s pane yet (is the integration installed?)'
  L_SID_GUESSED='codex session id guessed from cwd: %s…'
  [[ -n "$NOTE_TEMPLATE" ]] || NOTE_TEMPLATE='This session was forked from {src_cwd}; the working directory is now {dst_cwd}. Relative paths and branches mentioned earlier refer to the old directory — use the current one from here on.'
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

notify() {
  local title="$1" body="${2:-}" sound="${3:-none}"
  "$HERDR" notification show "$title" --body "$body" --sound "$sound" >/dev/null 2>&1 || true
}

die() {
  log "FATAL: $*"
  printf 'session-fork: %s\n' "$*" >&2
  notify "session-fork failed" "$*" request
  exit 1
}

# herdr_json <args...> — run herdr, fail loudly on non-zero, print stdout JSON.
herdr_json() {
  local out
  if ! out="$("$HERDR" "$@" 2>&1)"; then
    log "herdr $* failed: $out"
    printf '%s' "$out"
    return 1
  fi
  printf '%s' "$out"
}

# pane_info <pane_id> → JSON of .result.pane
pane_info() {
  herdr_json pane get "$1" | jq -c '.result.pane'
}

# True when the pane sits at a bare interactive shell prompt (agent start precondition).
pane_is_available_shell() {
  local json
  json="$("$HERDR" pane process-info --pane "$1" 2>/dev/null)" || return 1
  jq -e '
    (.result.process_info // {}) as $i
    | ($i.shell_pid // null) as $sp
    | ($i.foreground_processes // []) as $fg
    | $sp != null and ($fg | length) == 1 and $fg[0].pid == $sp
    | if . then
        ($fg[0].name // "" | split("/") | last | ltrimstr("-") | ascii_downcase | sub("\\.exe$"; ""))
        as $n | (["zsh","bash","sh","fish","dash","ksh","pwsh","powershell","nu"] | index($n)) != null
      else false end
  ' <<<"$json" >/dev/null
}

wait_for_available_shell() {
  local pane="$1" timeout_s="${2:-20}" deadline=$((SECONDS + ${2:-20}))
  while (( SECONDS < deadline )); do
    pane_is_available_shell "$pane" && return 0
    sleep 0.2
  done
  return 1
}

# Find a pane at a shell prompt inside a workspace (prefers the active tab).
# Polls briefly because a freshly created workspace/tab may not have spawned yet.
find_shell_pane_in_workspace() {
  local ws="$1" timeout_s="${2:-15}" deadline=$((SECONDS + ${2:-15}))
  local snap active_tab pane
  while (( SECONDS < deadline )); do
    snap="$("$HERDR" api snapshot 2>/dev/null)" || { sleep 0.3; continue; }
    active_tab="$(jq -r --arg ws "$ws" '.result.snapshot.workspaces[] | select(.workspace_id==$ws) | .active_tab_id // empty' <<<"$snap")"
    for pane in $(jq -r --arg ws "$ws" --arg tab "$active_tab" '
        [.result.snapshot.panes[] | select(.workspace_id==$ws)]
        | sort_by(if .tab_id==$tab then 0 else 1 end)
        | .[] | .pane_id' <<<"$snap"); do
      if pane_is_available_shell "$pane"; then
        printf '%s' "$pane"
        return 0
      fi
    done
    sleep 0.3
  done
  return 1
}

# Newest codex rollout whose session_meta.cwd equals <cwd>. Heuristic fallback only.
codex_session_for_cwd() {
  local want="$1" f
  local root="${CODEX_HOME:-$HOME/.codex}/sessions"
  [[ -d "$root" ]] || return 1
  # newest first; only inspect the first line (session_meta) of each rollout
  while IFS= read -r f; do
    if head -1 "$f" | jq -e --arg cwd "$want" '.type=="session_meta" and .payload.cwd==$cwd' >/dev/null 2>&1; then
      head -1 "$f" | jq -r '.payload.id'
      return 0
    fi
  done < <(ls -t "$root"/*/*/*/rollout-*.jsonl 2>/dev/null | head -200)
  return 1
}

# Unique herdr agent name, prefix sf-.
alloc_agent_name() {
  local suffix candidate
  for _ in 1 2 3 4 5 6 7 8; do
    suffix="$(printf '%04x' "$((RANDOM % 65536))")"
    candidate="sf-${suffix}"
    "$HERDR" agent get "$candidate" >/dev/null 2>&1 && continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# Start the forked agent in <pane>, retrying while the shell settles.
# (bash 3.2 on macOS: no mapfile, so the argv is built inline.)
start_forked_agent() {
  local pane="$1" kind="$2" sid="$3" name="$4" dst_cwd="${5:-}"
  local -a args
  case "$kind" in
    claude) args=(--resume "$sid" --fork-session) ;;
    codex)  args=(fork "$sid") ;;
    pi)     args=(--fork "$sid") ;;                  # accepts a session file path or (partial) UUID
    grok)   args=(--resume "$sid" --fork-session)    # grok pins the fork to the source cwd unless told otherwise
            [[ -n "$dst_cwd" ]] && args+=(--cwd "$dst_cwd") ;;
    *) log "unsupported agent kind $kind"; return 1 ;;
  esac
  local attempt out
  for attempt in 1 2 3 4 5 6 7 8; do
    wait_for_available_shell "$pane" 15 || log "pane $pane not at shell yet (attempt $attempt)"
    if out="$("$HERDR" agent start "$name" --kind "$kind" --pane "$pane" -- "${args[@]}" 2>&1)"; then
      log "agent start ok: $name in $pane"
      return 0
    fi
    log "agent start attempt $attempt: $out"
    if [[ "$out" == *agent_pane_busy* || "$out" == *'not an available shell'* ]]; then
      sleep 0.4
      continue
    fi
    printf '%s\n' "$out" >&2
    return 1
  done
  printf '%s\n' "$out" >&2
  return 1
}

render_note() {
  local src="$1" dst="$2" t="$NOTE_TEMPLATE"
  # quoted patterns: bash 3.2 mis-parses an escaped "}" inside ${var//pat/rep}
  t="${t//'{src_cwd}'/$src}"
  t="${t//'{dst_cwd}'/$dst}"
  printf '%s' "$t"
}
