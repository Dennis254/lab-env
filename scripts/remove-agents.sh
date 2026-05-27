#!/usr/bin/env bash
#
# remove-agents.sh - remove agent profile installation from lab targets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/configure-agents.sh" --action remove "$@"
