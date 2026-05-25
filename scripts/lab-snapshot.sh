#!/usr/bin/env bash
#
# lab-snapshot.sh - create and restore coordinated libvirt snapshots
#
# Usage:
#   ./scripts/lab-snapshot.sh create <name> [--yes]
#   ./scripts/lab-snapshot.sh list
#   ./scripts/lab-snapshot.sh restore <name> [--yes]
#   ./scripts/lab-snapshot.sh delete <name> [--yes]
#
# Snapshots are created while VMs are shut off. This avoids live snapshot
# complexity and gives predictable restore semantics for malware-lab use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_DIR="$LAB_ROOT/snapshots"

CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
MGMT_NET="${LAB_MGMT_NET:-lab-mgmt}"
DETO_NET="${LAB_DETO_NET:-lab-detonation}"
WAN_NET="${LAB_WAN_NET:-lab-wan}"
SHUTDOWN_TIMEOUT="${LAB_SNAPSHOT_SHUTDOWN_TIMEOUT:-180}"

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

COMMAND="${1:-}"
SNAPSHOT_NAME="${2:-}"
ASSUME_YES=false
DRY_RUN=false

[[ -n "$COMMAND" ]] || { usage; exit 1; }
shift || true
if [[ "$COMMAND" != "list" ]]; then
    [[ -n "${1:-}" ]] || { usage; exit 1; }
    SNAPSHOT_NAME="$1"
    shift || true
fi

for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Okänt argument: $arg" ;;
    esac
done

case "$COMMAND" in
    create|list|restore|delete) ;;
    -h|--help) usage; exit 0 ;;
    *) die "Okänt kommando: $COMMAND" ;;
esac

if [[ "$COMMAND" != "list" ]]; then
    [[ "$SNAPSHOT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Snapshot-namn får bara innehålla A-Z, a-z, 0-9, punkt, underscore och bindestreck."
fi

MANIFEST="$SNAPSHOT_DIR/${SNAPSHOT_NAME}.json"

virsh_cmd() {
    virsh --connect "$CONNECT_URI" "$@"
}

require_tools() {
    command -v virsh >/dev/null 2>&1 || die "virsh saknas."
    command -v jq >/dev/null 2>&1 || die "jq saknas."
}

domain_state() {
    virsh_cmd domstate "$1" 2>/dev/null | tr -d '\r' || printf 'unknown'
}

domain_is_running() {
    [[ "$(domain_state "$1")" == "running" ]]
}

all_domains() {
    virsh_cmd list --all --name | sed '/^$/d' | sort
}

domain_lab_ifaces() {
    local domain="$1"
    virsh_cmd domiflist "$domain" --inactive 2>/dev/null \
        | awk -v mgmt="$MGMT_NET" -v deto="$DETO_NET" -v wan="$WAN_NET" '
            $3 == mgmt || $3 == deto || $3 == wan { print $3, tolower($5) }
        '
}

lab_domains() {
    local domain
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        if domain_lab_ifaces "$domain" | grep -q .; then
            printf '%s\n' "$domain"
        fi
    done < <(all_domains)
}

snapshot_exists() {
    local domain="$1" name="$2"
    virsh_cmd snapshot-info "$domain" --snapshotname "$name" >/dev/null 2>&1
}

confirm() {
    local message="$1"
    $ASSUME_YES && return 0
    $DRY_RUN && return 0
    if [[ ! -t 0 ]]; then
        die "Interaktiv bekräftelse saknas. Kör med --yes om du vill fortsätta."
    fi

    local reply
    read -r -p "$message [y/N] " reply
    case "$reply" in
        [Yy]*) ;;
        *) die "Avbrutet." ;;
    esac
}

wait_for_state() {
    local domain="$1" wanted="$2" timeout="$3" elapsed=0 state
    while (( elapsed < timeout )); do
        state="$(domain_state "$domain")"
        [[ "$state" == "$wanted" ]] && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

shutdown_domain() {
    local domain="$1"
    domain_is_running "$domain" || return 0

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q shutdown %q\n' "$CONNECT_URI" "$domain"
        return 0
    fi

    info "Stänger ner $domain"
    virsh_cmd shutdown "$domain" >/dev/null || true
    if ! wait_for_state "$domain" "shut off" "$SHUTDOWN_TIMEOUT"; then
        warn "$domain stängde inte ner inom ${SHUTDOWN_TIMEOUT}s - tvingar avstängning"
        virsh_cmd destroy "$domain" >/dev/null
        wait_for_state "$domain" "shut off" 30 || die "$domain kunde inte stängas av."
    fi
}

destroy_domain() {
    local domain="$1"
    domain_is_running "$domain" || return 0

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q destroy %q\n' "$CONNECT_URI" "$domain"
        return 0
    fi

    info "Stoppar $domain inför restore"
    virsh_cmd destroy "$domain" >/dev/null
    wait_for_state "$domain" "shut off" 30 || die "$domain kunde inte stoppas."
}

start_domain() {
    local domain="$1"
    domain_is_running "$domain" && return 0

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q start %q\n' "$CONNECT_URI" "$domain"
        return 0
    fi

    info "Startar $domain"
    virsh_cmd start "$domain" >/dev/null
}

write_manifest() {
    local created_at="$1"
    shift
    local domains=("$@")
    mkdir -p "$SNAPSHOT_DIR"

    {
        printf '{\n'
        printf '  "name": "%s",\n' "$SNAPSHOT_NAME"
        printf '  "created_at": "%s",\n' "$created_at"
        printf '  "libvirt_uri": "%s",\n' "$CONNECT_URI"
        printf '  "domains": [\n'
        local i domain was_running comma
        for i in "${!domains[@]}"; do
            domain="${domains[$i]%%:*}"
            was_running="${domains[$i]#*:}"
            comma=","
            [[ "$i" == "$((${#domains[@]} - 1))" ]] && comma=""
            printf '    {"name": "%s", "was_running": %s}%s\n' "$domain" "$was_running" "$comma"
        done
        printf '  ]\n'
        printf '}\n'
    } > "$MANIFEST"
}

manifest_domains() {
    jq -r '.domains[].name' "$MANIFEST"
}

manifest_was_running() {
    local domain="$1"
    jq -r --arg domain "$domain" '.domains[] | select(.name == $domain) | .was_running' "$MANIFEST"
}

cmd_list() {
    mkdir -p "$SNAPSHOT_DIR"
    local manifest name created count
    printf '%-24s %-25s %-8s\n' "SNAPSHOT" "CREATED" "DOMAINS"
    printf '%-24s %-25s %-8s\n' "--------" "-------" "-------"
    for manifest in "$SNAPSHOT_DIR"/*.json; do
        [[ -f "$manifest" ]] || continue
        name="$(jq -r '.name' "$manifest")"
        created="$(jq -r '.created_at' "$manifest")"
        count="$(jq -r '.domains | length' "$manifest")"
        printf '%-24s %-25s %-8s\n' "$name" "$created" "$count"
    done
}

cmd_create() {
    [[ ! -f "$MANIFEST" ]] || die "Manifest finns redan: $MANIFEST"
    confirm "Skapa snapshot '$SNAPSHOT_NAME' för alla labb-VMer?"

    local domain domains=() domain_entries=() state created_at
    mapfile -t domains < <(lab_domains)
    [[ ${#domains[@]} -gt 0 ]] || die "Inga labb-VMer hittades."

    for domain in "${domains[@]}"; do
        if snapshot_exists "$domain" "$SNAPSHOT_NAME"; then
            die "$domain har redan snapshot '$SNAPSHOT_NAME'."
        fi
    done

    for domain in "${domains[@]}"; do
        state="$(domain_state "$domain")"
        if [[ "$state" == "running" ]]; then
            domain_entries+=("$domain:true")
        else
            domain_entries+=("$domain:false")
        fi
        shutdown_domain "$domain"
    done

    created_at="$(date -Is)"
    for domain in "${domains[@]}"; do
        info "Skapar snapshot '$SNAPSHOT_NAME' på $domain"
        if $DRY_RUN; then
            printf 'DRY-RUN virsh --connect %q snapshot-create-as %q --name %q --description %q\n' \
                "$CONNECT_URI" "$domain" "$SNAPSHOT_NAME" "lab snapshot $SNAPSHOT_NAME ($created_at)"
        else
            virsh_cmd snapshot-create-as "$domain" \
                --name "$SNAPSHOT_NAME" \
                --description "lab snapshot $SNAPSHOT_NAME ($created_at)" >/dev/null
        fi
    done

    if ! $DRY_RUN; then
        write_manifest "$created_at" "${domain_entries[@]}"
        ok "Manifest: $MANIFEST"
    fi

    for domain_entry in "${domain_entries[@]}"; do
        domain="${domain_entry%%:*}"
        [[ "${domain_entry#*:}" == "true" ]] && start_domain "$domain"
    done

    ok "Snapshot '$SNAPSHOT_NAME' skapad."
}

cmd_restore() {
    [[ -f "$MANIFEST" ]] || die "Hittar inte manifest: $MANIFEST"
    confirm "Återställ snapshot '$SNAPSHOT_NAME'? Körande VMer stoppas hårt inför restore."

    local domain was_running
    while IFS= read -r domain; do
        snapshot_exists "$domain" "$SNAPSHOT_NAME" || die "$domain saknar snapshot '$SNAPSHOT_NAME'."
    done < <(manifest_domains)

    while IFS= read -r domain; do
        destroy_domain "$domain"
    done < <(manifest_domains)

    while IFS= read -r domain; do
        info "Återställer $domain till '$SNAPSHOT_NAME'"
        if $DRY_RUN; then
            printf 'DRY-RUN virsh --connect %q snapshot-revert %q %q --force\n' "$CONNECT_URI" "$domain" "$SNAPSHOT_NAME"
        else
            virsh_cmd snapshot-revert "$domain" "$SNAPSHOT_NAME" --force >/dev/null
        fi
    done < <(manifest_domains)

    while IFS= read -r domain; do
        was_running="$(manifest_was_running "$domain")"
        [[ "$was_running" == "true" ]] && start_domain "$domain"
    done < <(manifest_domains)

    ok "Snapshot '$SNAPSHOT_NAME' återställd."
}

cmd_delete() {
    [[ -f "$MANIFEST" ]] || die "Hittar inte manifest: $MANIFEST"
    confirm "Ta bort snapshot '$SNAPSHOT_NAME' från alla labb-VMer?"

    local domain
    while IFS= read -r domain; do
        if snapshot_exists "$domain" "$SNAPSHOT_NAME"; then
            info "Tar bort snapshot '$SNAPSHOT_NAME' från $domain"
            if $DRY_RUN; then
                printf 'DRY-RUN virsh --connect %q snapshot-delete %q %q\n' "$CONNECT_URI" "$domain" "$SNAPSHOT_NAME"
            else
                virsh_cmd snapshot-delete "$domain" "$SNAPSHOT_NAME" >/dev/null
            fi
        else
            warn "$domain saknar snapshot '$SNAPSHOT_NAME' - hoppar över"
        fi
    done < <(manifest_domains)

    if ! $DRY_RUN; then
        rm -f "$MANIFEST"
    fi
    ok "Snapshot '$SNAPSHOT_NAME' borttagen."
}

require_tools

case "$COMMAND" in
    list) cmd_list ;;
    create) cmd_create ;;
    restore) cmd_restore ;;
    delete) cmd_delete ;;
esac
