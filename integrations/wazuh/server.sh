#!/usr/bin/env bash
set -euo pipefail
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf 'Dry-run: Wazuh server integration placeholder.\n'
    exit 0
fi
printf 'Wazuh server integration is planned but not implemented yet.\n' >&2
exit 2
