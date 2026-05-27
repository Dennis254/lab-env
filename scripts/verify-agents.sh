#!/usr/bin/env bash
#
# verify-agents.sh - verify agent profile installation on lab targets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/configure-agents.sh" --action verify "$@"
