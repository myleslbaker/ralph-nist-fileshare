#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop with live status display
# Usage: ./ralph.sh [--tool amp|claude] [max_iterations]

set -e

# ── ANSI colours ────────────────────────────────────────────────────────────
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; RED='\033[31m'; BLUE='\033[34m'
UP='\033[A'; CLEAR_TO_EOL='\033[K'; CLEAR_BELOW='\033[J'
IS_TTY=false; [ -t 1 ] && IS_TTY=true

WINDOW_LINES=12   # lines of rolling claude output to show

# ── Argument parsing ─────────────────────────────────────────────────────────
TOOL="amp"
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)    TOOL="$2";         shift 2 ;;
    --tool=*)  TOOL="${1#*=}";    shift   ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then MAX_ITERATIONS="$1"; fi
      shift ;;
  esac
done

if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'." ; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRD_FILE="$PROJECT_DIR/prd.json"
PROGRESS_FILE="$PROJECT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

# ── Helpers ───────────────────────────────────────────────────────────────────

fmt_elapsed() {
  local s=$1
  (( s < 60 ))  && echo "${s}s" && return
  (( s < 3600 )) && printf '%dm %02ds' $((s/60)) $((s%60)) && return
  printf '%dh %02dm %02ds' $((s/3600)) $(( (s%3600)/60 )) $((s%60))
}

# Read prd.json and return "passing|total|next_id|next_title"
prd_stats() {
  [ -f "$PRD_FILE" ] || { echo "0|0|?|unknown"; return; }
  python3 - "$PRD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
stories = data.get('stories', [])
passing  = sum(1 for s in stories if s.get('passes'))
total    = len(stories)
nxt      = next((s for s in stories if not s.get('passes')), None)
nid      = nxt['id']    if nxt else '-'
ntitle   = nxt['title'] if nxt else 'ALL DONE'
# Truncate long title
if len(ntitle) > 60:
    ntitle = ntitle[:57] + '...'
print(f"{passing}|{total}|{nid}|{ntitle}")
PY
}

# Parse stream-json log into human-readable lines for the rolling window.
# Emits tool calls + non-partial assistant text, one line each.
extract_display_lines() {
  local logfile="$1" n="${2:-$WINDOW_LINES}"
  python3 - "$logfile" "$n" <<'PY'
import json, sys, re
logfile, n = sys.argv[1], int(sys.argv[2])
out = []
try:
    with open(logfile) as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                # Plain-text fallback (shouldn't happen with stream-json)
                clean = re.sub(r'\x1b\[[0-9;]*m', '', raw).strip()
                if clean:
                    out.append(clean)
                continue
            t = obj.get('type', '')
            if t == 'assistant':
                partial = obj.get('partial', False)
                for block in obj.get('message', {}).get('content', []):
                    bt = block.get('type', '')
                    if bt == 'tool_use':
                        name = block.get('name', '?')
                        inp  = block.get('input', {})
                        # Best single-line summary of the tool call
                        detail = (inp.get('command')
                                  or inp.get('file_path')
                                  or inp.get('prompt', '')[:60]
                                  or str(inp)[:60])
                        out.append(f'[{name}] {detail}')
                    elif bt == 'text':
                        # Show text regardless of partial flag — stream-json marks
                        # all in-progress chunks as partial:true, so filtering on
                        # that hides everything until the very end.
                        for line in block.get('text', '').split('\n'):
                            line = line.strip()
                            if line:
                                out.append(line)
            elif t == 'system':
                pass   # skip init noise
except Exception:
    pass
for line in out[-n:]:
    print(line[:100])
PY
}

# Print the rolling-window header + last N parsed lines from stream-json log.
DRAWN=0
draw_window() {
  local logfile="$1" elapsed="$2" passing="$3" total="$4" next_title="$5"

  # Erase previous window (TTY only)
  if $IS_TTY && (( DRAWN > 0 )); then
    printf "\033[%dA\033[J" "$DRAWN"
  fi

  # Collect parsed display lines
  local raw_lines=()
  while IFS= read -r line; do
    raw_lines+=("$line")
  done < <(extract_display_lines "$logfile" "$WINDOW_LINES")

  local bar
  bar=$(printf '─%.0s' {1..64})

  printf "${BOLD}${CYAN}  ┌${bar}┐${RESET}\n"
  printf "${BOLD}${CYAN}  │${RESET} %-64s${BOLD}${CYAN}│${RESET}\n" \
    "$(printf "⏱  %s   📦 %s/%s passing   ▶ %s" "$elapsed" "$passing" "$total" "$next_title" | cut -c1-64)"
  printf "${BOLD}${CYAN}  ├${bar}┤${RESET}\n"

  local count=3
  if (( ${#raw_lines[@]} == 0 )); then
    printf "${CYAN}  │${RESET}${DIM} %-64s${RESET}${CYAN}│${RESET}\n" "(starting...)"
    ((count++))
  else
    for line in "${raw_lines[@]}"; do
      local clean
      clean=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-64)
      printf "${CYAN}  │${RESET}${DIM} %-64s${RESET}${CYAN}│${RESET}\n" "$clean"
      ((count++))
    done
  fi

  printf "${BOLD}${CYAN}  └${bar}┘${RESET}\n"
  ((count++))
  DRAWN=$count
}

# Print iteration banner (not erased, stays in scroll-back)
print_banner() {
  local iter="$1" max="$2" passing="$3" total="$4" next_id="$5" next_title="$6"
  echo ""
  printf "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════╗${RESET}\n"
  printf "${BOLD}${BLUE}║${RESET}  RALPH  Iter ${BOLD}%-4s${RESET}of %-4s │ Stories ${GREEN}%-3s${RESET}/ %-3s passing            ${BOLD}${BLUE}║${RESET}\n" \
    "$iter" "$max" "$passing" "$total"
  printf "${BOLD}${BLUE}║${RESET}  Next → #%-3s %s${RESET}\n" "$next_id" "$next_title" | \
    awk -v W=68 '{ s=substr($0,1,W); printf s; for(i=length(s);i<W;i++) printf " "; printf "'"${BOLD}${BLUE}║${RESET}"'\n" }'
  printf "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════╝${RESET}\n"
}

# Print iteration summary (stays in scroll-back)
print_summary() {
  local iter="$1" elapsed="$2" before_passing="$3" after_passing="$4" total="$5" \
        next_id="$6" next_title="$7" exit_code="$8"

  local delta=$(( after_passing - before_passing ))
  local status_colour="$GREEN"
  local status_word="OK"
  (( exit_code != 0 )) && { status_colour="$RED"; status_word="ERR"; }
  (( delta == 0 && exit_code == 0 )) && status_colour="$YELLOW"

  echo ""
  printf "${BOLD}${status_colour}▶ Iter %s done${RESET}  elapsed: ${BOLD}%s${RESET}  " "$iter" "$elapsed"
  if (( delta > 0 )); then
    printf "${GREEN}+%d stor%s passed${RESET}  " "$delta" "$([ $delta -eq 1 ] && echo y || echo ies)"
  else
    printf "${YELLOW}no new stories${RESET}  "
  fi
  printf "total: ${GREEN}%s${RESET}/%s\n" "$after_passing" "$total"
  printf "  Next → #%s %s\n" "$next_id" "$next_title"
  echo ""
}

# ── Archive previous run if branch changed ───────────────────────────────────
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ]      && cp "$PRD_FILE"      "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)"    >> "$PROGRESS_FILE"
    echo "---"                 >> "$PROGRESS_FILE"
  fi
fi

if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  [ -n "$CURRENT_BRANCH" ] && echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
fi

if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)"    >> "$PROGRESS_FILE"
  echo "---"                 >> "$PROGRESS_FILE"
fi

# ── Main loop ─────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}Starting Ralph${RESET}  tool=${CYAN}${TOOL}${RESET}  max_iterations=${CYAN}${MAX_ITERATIONS}${RESET}\n"

for i in $(seq 1 $MAX_ITERATIONS); do

  # Snapshot stats before this iteration
  IFS='|' read -r before_passing total next_id next_title < <(prd_stats)

  print_banner "$i" "$MAX_ITERATIONS" "$before_passing" "$total" "$next_id" "$next_title"

  ITER_START=$(date +%s)
  TMPLOG=$(mktemp /tmp/ralph-iter-XXXXX.log)
  DRAWN=0
  EXIT_CODE=0

  if [[ "$TOOL" == "amp" ]]; then
    cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all >"$TMPLOG" 2>&1 || EXIT_CODE=$?
    OUTPUT=$(cat "$TMPLOG")
  else
    # Launch claude in background with stream-json so output arrives line-by-line
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
      claude --dangerously-skip-permissions --no-session-persistence \
      --output-format stream-json --include-partial-messages \
      --print "Read and follow ALL instructions in all .md files in the $PROJECT_DIR directory. This is iteration $i of $MAX_ITERATIONS." \
      >"$TMPLOG" 2>&1 &
    CLAUDE_PID=$!

    # Live rolling window while claude runs
    if $IS_TTY; then
      while kill -0 "$CLAUDE_PID" 2>/dev/null; do
        ELAPSED=$(fmt_elapsed $(( $(date +%s) - ITER_START )))
        # Re-read prd.json on each refresh so counts stay current
        IFS='|' read -r cur_passing cur_total _nid cur_next_title < <(prd_stats)
        draw_window "$TMPLOG" "$ELAPSED" "$cur_passing" "$cur_total" "$cur_next_title"
        sleep 0.4
      done
      # One final refresh then erase the window so the summary prints cleanly
      ELAPSED=$(fmt_elapsed $(( $(date +%s) - ITER_START )))
      draw_window "$TMPLOG" "$ELAPSED" "$before_passing" "$total" "$next_title"
      sleep 0.2
      $IS_TTY && (( DRAWN > 0 )) && printf "\033[%dA\033[J" "$DRAWN"
      DRAWN=0
    fi

    wait "$CLAUDE_PID" || EXIT_CODE=$?
    # Extract final result text from stream-json (the {"type":"result"} line)
    OUTPUT=$(python3 - "$TMPLOG" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        for raw in f:
            try:
                obj = json.loads(raw.strip())
                if obj.get('type') == 'result':
                    print(obj.get('result', ''))
            except Exception:
                pass
except Exception:
    pass
PY
)
    # Fallback: grep raw file if result extraction produced nothing
    if [ -z "$OUTPUT" ]; then
      OUTPUT=$(cat "$TMPLOG")
    fi
  fi

  rm -f "$TMPLOG"

  ITER_END=$(date +%s)
  ELAPSED=$(fmt_elapsed $(( ITER_END - ITER_START )))

  # Snapshot stats after
  IFS='|' read -r after_passing total next_id_new next_title_new < <(prd_stats)

  print_summary "$i" "$ELAPSED" "$before_passing" "$after_passing" "$total" \
                "$next_id_new" "$next_title_new" "$EXIT_CODE"

  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    printf "${BOLD}${GREEN}✓ Ralph completed all tasks! (iteration %s of %s)${RESET}\n\n" "$i" "$MAX_ITERATIONS"
    exit 0
  fi

  sleep 2
done

printf "${YELLOW}Ralph reached max iterations (%s) without completing all tasks.${RESET}\n" "$MAX_ITERATIONS"
printf "Check %s for status.\n" "$PROGRESS_FILE"
exit 1
