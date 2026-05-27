#!/usr/bin/env bash
#
# Backward-compatible wrapper. Prefer scripts/splunk/test-flow.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/splunk/test-flow.sh" "$@"
