#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude --root .] [max_iterations]

set -e

PROMPT="prompt.md"
MODEL="github-copilot/claude-opus-4.6"
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --model=*)
      MODEL="${1#*=}"
      shift
      ;;
    --prompt)
      PROMPT="$2"
      shift 2
      ;;
    --prompt=*)
      PROMPT="${1#*=}"
      shift
      ;;

    --help|-h)
      echo "Usage: $0 [--model "one of 'opencode models'" --prompt prompt.md] [max_iterations]"
      exit 0
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

echo "Starting looop - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  looop $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  OUTPUT=$(opencode run -m "$MODEL" < "$PROMPT" 2>&1 | tee /dev/stderr) || true

  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "looop completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  echo "looop $i complete. Continuing..."
  sleep 2
done

echo ""
echo "looop reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check progress file for status."
exit 1
