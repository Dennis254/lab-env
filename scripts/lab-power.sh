#!/usr/bin/env bash
#
# lab-power.sh - start, stop and inspect all lab VMs
#
# Usage:
#   ./scripts/lab-power.sh status
#   ./scripts/lab-power.sh start [--yes]
#   ./scripts/lab-power.sh shutdown [--yes]
#   ./scripts/lab-power.sh stop [--yes]
#   ./scripts/lab-power.sh reboot [--yes]
#
# shutdown asks the guest OS to shut down. stop maps to virsh destroy and is
# intended for lab reset situations where graceful shutdown is not important.

set -euo pipefail

CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
MGMT_NET="${LAB_MGMT_NET:-lab-mgmt}"
DETO_NET="${LAB_DETO_NET:-lab-detonation}"
WAN_NET="${LAB_WAN_NET:-lab-wan}"
SHUTDOWN_TIMEOUT="${LAB_POWER_SHUTDOWN_TIMEOUT:-180}"

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

COMMAND="${1:-}"
ASSUME_YES=false
DRY_RUN=false
FAILURES=()

[[ -n "$COMMAND" ]] || { usage; exit 1; }
shift || true

for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Okänt argument: $arg" ;;
    esac
done

case "$COMMAND" in
    status|start|shutdown|stop|reboot) ;;
    -h|--help) usage; exit 0 ;;
    *) die "Okänt kommando: $COMMAND (välj status, start, shutdown, stop eller reboot)" ;;
esac

virsh_cmd() {
    virsh --connect "$CONNECT_URI" "$@"
}

require_tools() {
    command -v virsh >/dev/null 2>&1 || die "virsh saknas."
    virsh_cmd uri >/dev/null 2>&1 || die "Kan inte ansluta till libvirt via $CONNECT_URI."
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

record_failure() {
    local domain="$1" message="$2"
    warn "$domain: $message"
    FAILURES+=("$domain: $message")
}

cmd_status() {
    local found=false domain state
    printf '%-16s %-12s\n' "VM" "STATE"
    printf '%-16s %-12s\n' "--" "-----"
    while IFS= read -r domain; do
        found=true
        state="$(domain_state "$domain")"
        printf '%-16s %-12s\n' "$domain" "$state"
    done < <(lab_domains)

    $found || warn "Inga libvirt-domäner med $MGMT_NET/$DETO_NET/$WAN_NET hittades."
}

start_domain() {
    local domain="$1" state
    state="$(domain_state "$domain")"
    if [[ "$state" == "running" ]]; then
        ok "$domain är redan igång"
        return 0
    fi

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q start %q\n' "$CONNECT_URI" "$domain"
        return 0
    fi

    info "Startar $domain"
    if ! virsh_cmd start "$domain" >/dev/null; then
        record_failure "$domain" "kunde inte startas"
        return 1
    fi
    ok "$domain startad"
}

shutdown_domain() {
    local domain="$1"
    if ! domain_is_running "$domain"; then
        ok "$domain är redan avstängd"
        return 0
    fi

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q shutdown %q\n' "$CONNECT_URI" "$domain"
        return 0
    fi

    info "Stänger ner $domain"
    if ! virsh_cmd shutdown "$domain" >/dev/null; then
        record_failure "$domain" "shutdown-kommandot misslyckades"
        return 1
    fi
    if ! wait_for_state "$domain" "shut off" "$SHUTDOWN_TIMEOUT"; then
        record_failure "$domain" "stängde inte ner inom ${SHUTDOWN_TIMEOUT}s"
        return 1
    fi
    ok "$domain avstängd"
}

stop_domain() {
    local domain="$1"
    if ! domain_is_running "$domain"; then
        ok "$domain är redan avstängd"
        return 0
    fi

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q destroy %q\n' "$CONNECT_URI" "$domain"
        return 0
    fi

    info "Stoppar $domain hårt"
    if ! virsh_cmd destroy "$domain" >/dev/null; then
        record_failure "$domain" "kunde inte stoppas hårt"
        return 1
    fi
    if ! wait_for_state "$domain" "shut off" 30; then
        record_failure "$domain" "är fortfarande inte avstängd"
        return 1
    fi
    ok "$domain stoppad"
}

reboot_domain() {
    local domain="$1"
    if ! domain_is_running "$domain"; then
        ok "$domain är avstängd - startar den"
        start_domain "$domain"
        return $?
    fi

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q reboot %q\n' "$CONNECT_URI" "$domain"
        return 0
    fi

    info "Startar om $domain"
    if ! virsh_cmd reboot "$domain" >/dev/null; then
        record_failure "$domain" "reboot-kommandot misslyckades"
        return 1
    fi
    ok "$domain reboot skickad"
}

apply_to_domains() {
    local action="$1" found=false domain
    while IFS= read -r domain; do
        found=true
        case "$action" in
            start) start_domain "$domain" || true ;;
            shutdown) shutdown_domain "$domain" || true ;;
            stop) stop_domain "$domain" || true ;;
            reboot) reboot_domain "$domain" || true ;;
        esac
    done < <(lab_domains)

    $found || die "Inga labb-VMer hittades."

    if ((${#FAILURES[@]} > 0)); then
        err "Klart med fel:"
        printf '  - %s\n' "${FAILURES[@]}" >&2
        return 1
    fi
}

require_tools

case "$COMMAND" in
    status)
        cmd_status
        ;;
    start)
        confirm "Starta alla labb-VMer?"
        apply_to_domains start
        ;;
    shutdown)
        confirm "Stäng av alla labb-VMer med guest shutdown?"
        apply_to_domains shutdown
        ;;
    stop)
        confirm "Stoppa alla labb-VMer hårt med virsh destroy?"
        apply_to_domains stop
        ;;
    reboot)
        confirm "Starta om alla labb-VMer?"
        apply_to_domains reboot
        ;;
esac
