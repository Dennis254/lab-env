#!/usr/bin/env bash
set -euo pipefail
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf 'Dry-run: Wazuh agent integration placeholder.\n'
    exit 0
fi
printf 'Wazuh agent integration is planned but not implemented yet.\n' >&2
exit 2
