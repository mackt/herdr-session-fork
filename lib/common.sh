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
# The note is a prompt for the agent; keep it English.
NOTE_TEMPLATE='This session was forked from {src_cwd}; the working directory is now {dst_cwd}. Relative paths and branches mentioned earlier refer to the old directory — use the current one from here on.'
SPLIT_RATIO=""
SHOW_DETACHED_WORKTREES=0
STARTUP_PROMPT_TIMEOUT_MS=300000   # how long to wait for the user to answer a startup prompt (e.g. trust dialog)
if [[ -n "$CONFIG_DIR" && -f "$CONFIG_DIR/config.sh" ]]; then
  # shellcheck disable=SC1091
  source "$CONFIG_DIR/config.sh"
fi

# ---- UI strings (English, matching Herdr's own UI) ----------------------------
L_SPLIT_HERE='↔ split next to this pane (same directory)'
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
L_TRUST_TITLE='Action needed'
L_TRUST_BODY='%s is entering %s for the first time — confirm the trust prompt in the pane'
L_BLOCKED_BODY='%s stopped at a prompt during startup — see pane %s'

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
    if [[ "$out" == *agent_not_ready* ]]; then
      # The agent is up but stopped at a startup prompt (typically Claude's
      # "trust this folder?"). Herdr already bound $name to the pane, so hand the
      # prompt to the user and wait for the agent to settle.
      wait_through_startup_prompt "$pane" "$kind" "$name" "$dst_cwd" && return 0
      return 1
    fi
    printf '%s\n' "$out" >&2
    return 1
  done
  printf '%s\n' "$out" >&2
  return 1
}

# Notify the user about a startup prompt in <pane>, focus it, wait until the agent is idle.
wait_through_startup_prompt() {
  local pane="$1" kind="$2" name="$3" dst_cwd="$4" screen body
  screen="$("$HERDR" pane read "$pane" 2>/dev/null || true)"
  if grep -qi 'trust this folder' <<<"$screen"; then
    body="$(printf "$L_TRUST_BODY" "$kind" "$dst_cwd")"
  else
    body="$(printf "$L_BLOCKED_BODY" "$kind" "$pane")"
  fi
  log "startup prompt in $pane: $body"
  notify "$L_TRUST_TITLE" "$body" request
  "$HERDR" pane focus --pane "$pane" >/dev/null 2>&1 || true
  if "$HERDR" agent wait "$name" --until idle --timeout "${STARTUP_PROMPT_TIMEOUT_MS:-300000}" >/dev/null 2>&1; then
    log "agent $name ready after startup prompt"
    return 0
  fi
  log "agent $name never became idle after startup prompt"
  return 1
}

render_note() {
  local src="$1" dst="$2" t="$NOTE_TEMPLATE"
  # quoted patterns: bash 3.2 mis-parses an escaped "}" inside ${var//pat/rep}
  t="${t//'{src_cwd}'/$src}"
  t="${t//'{dst_cwd}'/$dst}"
  printf '%s' "$t"
}
