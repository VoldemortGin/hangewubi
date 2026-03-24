#!/bin/bash

# Ensure PATH includes Homebrew and cargo paths for launchd
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.cargo/bin:$PATH"

cd "$(dirname "$0")"

# Fetch without exiting on failure
git fetch origin main 2>&1 || { echo "git fetch failed"; exit 0; }

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

# Nothing new — exit silently
if [ "$LOCAL" = "$REMOTE" ]; then
    exit 0
fi

# New commits detected — log everything from here
mkdir -p ci-logs
LOGFILE="ci-logs/$(date '+%Y-%m-%d_%H%M%S').log"

{
    echo "=== CI Build Started: $(date) ==="
    echo "Local:  $LOCAL"
    echo "Remote: $REMOTE"
    echo ""

    git pull origin main
    echo ""

    # Exit on error for the build
    set -e
    echo "=== Running build-all.sh ==="
    bash build-all.sh
    echo ""
    echo "=== CI Build Finished: $(date) ==="
} &> "$LOGFILE"
