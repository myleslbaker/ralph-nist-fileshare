#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop with live status display
# Usage: ./ralph.sh [--tool amp|claude] [max_iterations]

set -e

# ── ANSI colours ────────────────────────────────────────────────────────────
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; RED='\033[31m'; BLUE='\033[34m'
UP='\033[A'; CLEAR_TO_EOL='\033[K'; CLEAR_BELOW='\033[J'
IS_TTY=false; [ -t 1 ] && IS_TTY=true

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
    # Launch claude in background (plain --print mode — stream-json conflicts with --print)
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
      claude --dangerously-skip-permissions \
      --print "Read and follow ALL instructions in all .md files in the $PROJECT_DIR directory. This is iteration $i of $MAX_ITERATIONS." \
      >"$TMPLOG" 2>&1 &
    CLAUDE_PID=$!

    # Spinner while claude runs
    if $IS_TTY; then
      SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
      SP=0
      SPINNER_LINES=0
      while kill -0 "$CLAUDE_PID" 2>/dev/null; do
        ELAPSED=$(fmt_elapsed $(( $(date +%s) - ITER_START )))
        IFS='|' read -r cur_passing cur_total _nid cur_next_title < <(prd_stats)
        # Erase previous spinner line
        if (( SPINNER_LINES > 0 )); then
          printf "\033[%dA\033[J" "$SPINNER_LINES"
        fi
        local bar
        bar=$(printf '─%.0s' {1..64})
        printf "${BOLD}${CYAN}  ┌${bar}┐${RESET}\n"
        printf "${BOLD}${CYAN}  │${RESET} %-64s${BOLD}${CYAN}│${RESET}\n" \
          "$(printf "⏱  %s   📦 %s/%s passing   ▶ %s" "$ELAPSED" "$cur_passing" "$cur_total" "$cur_next_title" | cut -c1-64)"
        printf "${BOLD}${CYAN}  │${RESET}${DIM} %s  Claude working...%-45s${RESET}${BOLD}${CYAN}│${RESET}\n" \
          "${SPINNER[$SP]}" ""
        printf "${BOLD}${CYAN}  └${bar}┘${RESET}\n"
        SPINNER_LINES=4
        SP=$(( (SP + 1) % ${#SPINNER[@]} ))
        sleep 0.4
      done
      # Erase spinner
      if (( SPINNER_LINES > 0 )); then
        printf "\033[%dA\033[J" "$SPINNER_LINES"
      fi
    fi

    wait "$CLAUDE_PID" || EXIT_CODE=$?
    OUTPUT=$(cat "$TMPLOG")
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
