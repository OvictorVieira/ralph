#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ralph [--tool amp|claude] [max_iterations]

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: ralph [--tool amp|claude] [max_iterations]

Options:
  --tool TOOL        Agent to run. Supported: amp, claude
  --tool=TOOL        Same as above
  --claude           Shortcut for --tool claude
  --amp              Shortcut for --tool amp
  -h, --help         Show this help message

Arguments:
  max_iterations     Number of Ralph loop iterations. Default: 10

Environment:
  RALPH_PROJECT_ROOT Override the project root used for prd.json/progress.txt
EOF
}

resolve_script_dir() {
  local source_path="${BASH_SOURCE[0]}"

  while [[ -L "$source_path" ]]; do
    local source_dir
    source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    source_path="$(readlink "$source_path")"

    if [[ "$source_path" != /* ]]; then
      source_path="$source_dir/$source_path"
    fi
  done

  cd -P "$(dirname "$source_path")" && pwd
}

detect_project_root() {
  if [[ -n "${RALPH_PROJECT_ROOT:-}" ]]; then
    echo "$RALPH_PROJECT_ROOT"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    local git_root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$git_root" ]]; then
      echo "$git_root"
      return 0
    fi
  fi

  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/prd.json" || -d "$dir/.git" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  echo "$PWD"
}

resolve_prd_file() {
  local project_root="$1"

  if [[ -f "$project_root/prd.json" ]]; then
    echo "$project_root/prd.json"
    return 0
  fi

  if [[ -f "$project_root/tasks/prd.json" ]]; then
    echo "$project_root/tasks/prd.json"
    return 0
  fi

  return 1
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

infer_ticket_key() {
  local prd_file="$1"
  local candidate

  candidate="$(
    jq -r '
      [
        .ticketId,
        .taskId,
        .issueKey,
        .jiraId,
        .description,
        (.userStories[]?.title),
        (.userStories[]?.description)
      ]
      | map(select(type == "string" and length > 0))
      | .[]
    ' "$prd_file" 2>/dev/null \
    | grep -Eo '[A-Z]+-[0-9]+' \
    | head -n 1
  )"

  if [[ -n "$candidate" ]]; then
    echo "$candidate"
  fi
}

infer_branch_type() {
  local prd_file="$1"
  local raw_type

  raw_type="$(
    jq -r '
      .branchType // .type // .workType // .taskType // .kind // .category // .branchName // .description // ""
    ' "$prd_file" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]'
  )"

  case "$raw_type" in
    hotfix*|fix/*|fix\ *|bugfix*|bug/*)
      echo "hotfix"
      ;;
    chore*)
      echo "chore"
      ;;
    docs*|doc*)
      echo "docs"
      ;;
    refactor*)
      echo "refactor"
      ;;
    test*)
      echo "test"
      ;;
    feat/*|feature/*|feature*|feat*)
      echo "feat"
      ;;
    *)
      echo "feat"
      ;;
  esac
}

infer_branch_slug() {
  local prd_file="$1"
  local raw_slug
  local prd_dir
  local task_slug_file

  prd_dir="$(dirname "$prd_file")"
  task_slug_file="$(
    find "$prd_dir" -maxdepth 1 -type f -name 'prd-*.md' -print 2>/dev/null \
      | head -n 1
  )"

  if [[ -n "$task_slug_file" ]]; then
    raw_slug="$(basename "$task_slug_file" .md | sed 's/^prd-//')"
  else
    raw_slug="$(
      jq -r '
        (
          .branchName
          | select(type == "string" and length > 0)
          | split("/")
          | if length >= 3 then .[2:] | join("/")
            elif length == 2 then .[1]
            else empty
            end
        ) //
        .branchSlug //
        .slug //
        .storySlug //
        .taskSlug //
        .description //
        (.userStories[]? | select(.passes == false) | .title) //
        .project //
        "task"
      ' "$prd_file" 2>/dev/null \
        | head -n 1
    )"
  fi

  slugify "$raw_slug"
}

normalize_branch_name() {
  local prd_file="$1"
  local current_branch branch_type ticket_key branch_slug story_id_branch_pattern desired_branch

  current_branch="$(jq -r '.branchName // empty' "$prd_file" 2>/dev/null || true)"
  story_id_branch_pattern='^(feat|feature|hotfix|fix|bugfix|chore|docs|refactor|test)/US-[0-9]+(/.*)?$'

  branch_type="$(infer_branch_type "$prd_file")"
  ticket_key="$(infer_ticket_key "$prd_file")"
  branch_slug="$(infer_branch_slug "$prd_file")"

  if [[ -n "$ticket_key" && -n "$branch_slug" ]]; then
    desired_branch="$branch_type/$ticket_key/$branch_slug"
  elif [[ -n "$ticket_key" ]]; then
    desired_branch="$branch_type/$ticket_key"
  elif [[ -n "$branch_slug" ]]; then
    desired_branch="$branch_type/$branch_slug"
  else
    desired_branch="$branch_type/task"
  fi

  if [[ -n "$current_branch" && ! "$current_branch" =~ ^ralph(/|$) && ! "$current_branch" =~ $story_id_branch_pattern && "$current_branch" == "$desired_branch" ]]; then
    echo "$current_branch"
    return 0
  fi

  echo "$desired_branch"
}

persist_branch_name() {
  local prd_file="$1"
  local branch_name="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  jq --arg branch_name "$branch_name" '.branchName = $branch_name' "$prd_file" > "$tmp_file"
  mv "$tmp_file" "$prd_file"
}

resolve_git_identity_from_history() {
  local project_root="$1"
  local preferred_name="$2"
  local recent_identity
  local history_ref

  if [[ -z "$preferred_name" ]]; then
    return 0
  fi

  history_ref="$(
    git -C "$project_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
      || true
  )"

  if [[ -z "$history_ref" ]]; then
    if git -C "$project_root" show-ref --verify --quiet refs/remotes/origin/main; then
      history_ref="origin/main"
    elif git -C "$project_root" show-ref --verify --quiet refs/heads/main; then
      history_ref="main"
    elif git -C "$project_root" show-ref --verify --quiet refs/heads/master; then
      history_ref="master"
    else
      history_ref="HEAD"
    fi
  fi

  recent_identity="$(
    git -C "$project_root" log "$history_ref" --format='%an%x09%ae' 2>/dev/null \
      | awk -F '\t' -v preferred_name="$preferred_name" '
          $1 == preferred_name && $2 !~ /local$/ { print $0; exit }
        '
  )"

  if [[ -n "$recent_identity" ]]; then
    printf '%s\n' "$recent_identity"
  fi
}

# Parse arguments
TOOL="amp"  # Default to amp for backwards compatibility
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      print_usage
      exit 0
      ;;
    --claude)
      TOOL="claude"
      shift
      ;;
    --amp)
      TOOL="amp"
      shift
      ;;
    --tool)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --tool requires a value."
        print_usage
        exit 1
      fi
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Error: Unknown argument '$1'."
        print_usage
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  exit 1
fi

SCRIPT_DIR="$(resolve_script_dir)"
PROJECT_ROOT="$(detect_project_root)"
PRD_FILE="$(resolve_prd_file "$PROJECT_ROOT" || true)"
PROGRESS_FILE="$PROJECT_ROOT/progress.txt"
STATE_DIR="$PROJECT_ROOT/.ralph"
ARCHIVE_DIR="$STATE_DIR/archive"
LAST_BRANCH_FILE="$STATE_DIR/.last-branch"
CLAUDE_PROMPT_FILE="$SCRIPT_DIR/CLAUDE.md"
AMP_PROMPT_FILE="$SCRIPT_DIR/prompt.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "claude" ]] && ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "amp" ]] && ! command -v amp >/dev/null 2>&1; then
  echo "Error: amp is required but was not found in PATH."
  exit 1
fi

if [[ -z "$PRD_FILE" || ! -f "$PRD_FILE" ]]; then
  echo "Error: Could not find prd.json in project root or tasks/: $PROJECT_ROOT"
  echo "Run Ralph from inside a project that has prd.json or tasks/prd.json, or set RALPH_PROJECT_ROOT."
  exit 1
fi

NORMALIZED_BRANCH_NAME="$(normalize_branch_name "$PRD_FILE")"
if [[ -n "$NORMALIZED_BRANCH_NAME" ]]; then
  persist_branch_name "$PRD_FILE" "$NORMALIZED_BRANCH_NAME"
fi

if command -v git >/dev/null 2>&1; then
  GIT_LOCAL_USER_NAME="$(git -C "$PROJECT_ROOT" config --local user.name 2>/dev/null || true)"
  GIT_LOCAL_USER_EMAIL="$(git -C "$PROJECT_ROOT" config --local user.email 2>/dev/null || true)"
  GIT_FALLBACK_USER_NAME="${GIT_LOCAL_USER_NAME:-$(git -C "$PROJECT_ROOT" config user.name 2>/dev/null || true)}"

  if [[ -z "$GIT_LOCAL_USER_EMAIL" ]]; then
    GIT_HISTORY_IDENTITY="$(resolve_git_identity_from_history "$PROJECT_ROOT" "$GIT_FALLBACK_USER_NAME")"
    if [[ -n "$GIT_HISTORY_IDENTITY" ]]; then
      GIT_LOCAL_USER_NAME="${GIT_HISTORY_IDENTITY%%	*}"
      GIT_LOCAL_USER_EMAIL="${GIT_HISTORY_IDENTITY#*	}"
    fi
  fi

  if [[ -n "$GIT_LOCAL_USER_NAME" ]]; then
    export GIT_AUTHOR_NAME="$GIT_LOCAL_USER_NAME"
    export GIT_COMMITTER_NAME="$GIT_LOCAL_USER_NAME"
  fi

  if [[ -n "$GIT_LOCAL_USER_EMAIL" ]]; then
    export GIT_AUTHOR_EMAIL="$GIT_LOCAL_USER_EMAIL"
    export GIT_COMMITTER_EMAIL="$GIT_LOCAL_USER_EMAIL"
  fi
fi

if [[ ! -f "$CLAUDE_PROMPT_FILE" ]]; then
  echo "Error: Missing Claude prompt file: $CLAUDE_PROMPT_FILE"
  exit 1
fi

mkdir -p "$STATE_DIR"
cd "$PROJECT_ROOT"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|/|-|g')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
echo "Project root: $PROJECT_ROOT"
echo "PRD file: $PRD_FILE"
echo "Target branch: $(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
  echo "Commit email: $GIT_AUTHOR_EMAIL"
fi

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # Run the selected tool with the ralph prompt
  if [[ "$TOOL" == "amp" ]]; then
    if [[ ! -f "$AMP_PROMPT_FILE" ]]; then
      echo "Error: Missing amp prompt file: $AMP_PROMPT_FILE"
      exit 1
    fi
    OUTPUT=$(amp --dangerously-allow-all < "$AMP_PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  else
    # Claude Code: use --dangerously-skip-permissions for autonomous operation, --print for output
    OUTPUT=$(claude --model opus --dangerously-skip-permissions --print < "$CLAUDE_PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  fi
  
  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi
  
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
