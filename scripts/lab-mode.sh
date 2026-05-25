#!/usr/bin/env bash
#
# lab-mode.sh - switch lab VMs between dev and detonation network modes
#
# Usage:
#   ./scripts/lab-mode.sh status
#   ./scripts/lab-mode.sh dev [--yes]
#   ./scripts/lab-mode.sh detonation [--yes]
#
# Mode semantics:
#   dev         mgmt up, wan up, detonation up
#   detonation  mgmt down, wan up, detonation up
#
# The script changes libvirt interface link-state rather than detaching
# devices. That keeps the domain device model stable for Terraform while still
# removing the mgmt network path from the guest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONNECT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
MGMT_NET="${LAB_MGMT_NET:-lab-mgmt}"
DETO_NET="${LAB_DETO_NET:-lab-detonation}"
WAN_NET="${LAB_WAN_NET:-lab-wan}"

c_reset=$'\e[0m'; c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'
c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'
info()  { printf '%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s  ✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
die()   { err "$*"; exit 1; }

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

MODE="${1:-}"
ASSUME_YES=false
DRY_RUN=false

[[ -n "$MODE" ]] || { usage; exit 1; }
shift || true

for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Okänt argument: $arg" ;;
    esac
done

case "$MODE" in
    status|dev|detonation) ;;
    -h|--help) usage; exit 0 ;;
    *) die "Okänt läge: $MODE (välj status, dev eller detonation)" ;;
esac

virsh_cmd() {
    virsh --connect "$CONNECT_URI" "$@"
}

require_tools() {
    command -v virsh >/dev/null 2>&1 || die "virsh saknas."
}

network_xml() {
    virsh_cmd net-dumpxml "$1" 2>/dev/null || true
}

require_networks() {
    local mgmt_xml deto_xml wan_xml
    mgmt_xml="$(network_xml "$MGMT_NET")"
    deto_xml="$(network_xml "$DETO_NET")"
    wan_xml="$(network_xml "$WAN_NET")"
    [[ -n "$mgmt_xml" ]] || die "Hittar inte libvirt-nätverket $MGMT_NET."
    [[ -n "$deto_xml" ]] || die "Hittar inte libvirt-nätverket $DETO_NET."
    [[ -n "$wan_xml" ]] || die "Hittar inte libvirt-nätverket $WAN_NET."

    if grep -q '<forward' <<< "$deto_xml"; then
        die "$DETO_NET har <forward> i libvirt-XML och är inte isolerat."
    fi
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

link_state() {
    local domain="$1" mac="$2" scope="${3:-live}" out
    if [[ "$scope" == "config" ]]; then
        out="$(virsh_cmd domif-getlink "$domain" "$mac" --config 2>/dev/null || true)"
    else
        if ! domain_is_running "$domain"; then
            printf 'n/a'
            return 0
        fi
        out="$(virsh_cmd domif-getlink "$domain" "$mac" 2>/dev/null || true)"
    fi
    awk '{print $2}' <<< "$out"
}

status() {
    local found=false domain state net mac live config
    printf '%-12s %-12s %-15s %-18s %-8s %-8s\n' "VM" "STATE" "NETWORK" "MAC" "LIVE" "CONFIG"
    printf '%-12s %-12s %-15s %-18s %-8s %-8s\n' "--" "-----" "-------" "---" "----" "------"

    while IFS= read -r domain; do
        found=true
        state="$(domain_state "$domain")"
        while read -r net mac; do
            [[ -n "${net:-}" && -n "${mac:-}" ]] || continue
            live="$(link_state "$domain" "$mac" live)"
            config="$(link_state "$domain" "$mac" config)"
            printf '%-12s %-12s %-15s %-18s %-8s %-8s\n' "$domain" "$state" "$net" "$mac" "$live" "$config"
        done < <(domain_lab_ifaces "$domain")
    done < <(lab_domains)

    $found || warn "Inga libvirt-domäner med $MGMT_NET/$DETO_NET hittades."
}

confirm_change() {
    local target="$1"
    $ASSUME_YES && return 0
    $DRY_RUN && return 0
    if [[ ! -t 0 ]]; then
        die "Interaktiv bekräftelse saknas. Kör med --yes om du vill byta till $target."
    fi

    local reply
    read -r -p "Byt labbet till '$target'? [y/N] " reply
    case "$reply" in
        [Yy]*) ;;
        *) die "Avbrutet." ;;
    esac
}

set_link() {
    local domain="$1" mac="$2" desired="$3" running=false
    domain_is_running "$domain" && running=true

    if $DRY_RUN; then
        printf 'DRY-RUN virsh --connect %q domif-setlink %q %q %q\n' "$CONNECT_URI" "$domain" "$mac" "$desired"
        printf 'DRY-RUN virsh --connect %q domif-setlink %q %q %q --config\n' "$CONNECT_URI" "$domain" "$mac" "$desired"
        return 0
    fi

    if $running; then
        virsh_cmd domif-setlink "$domain" "$mac" "$desired" >/dev/null
    fi
    virsh_cmd domif-setlink "$domain" "$mac" "$desired" --config >/dev/null
}

apply_mode() {
    local target="$1" domain net mac desired found=false
    confirm_change "$target"
    require_networks

    if [[ "$target" == "detonation" && "$DRY_RUN" == "false" ]]; then
        "$LAB_ROOT/scripts/lab-dns.sh" detonation
    fi

    info "Sätter lab-mode: $target"
    while IFS= read -r domain; do
        found=true
        while read -r net mac; do
            [[ -n "${net:-}" && -n "${mac:-}" ]] || continue
            case "$target:$net" in
                dev:"$MGMT_NET") desired="up" ;;
                dev:"$WAN_NET") desired="up" ;;
                dev:"$DETO_NET") desired="up" ;;
                detonation:"$MGMT_NET") desired="down" ;;
                detonation:"$WAN_NET") desired="up" ;;
                detonation:"$DETO_NET") desired="up" ;;
                *) continue ;;
            esac
            info "$domain $net ($mac) -> $desired"
            set_link "$domain" "$mac" "$desired"
        done < <(domain_lab_ifaces "$domain")
    done < <(lab_domains)

    $found || die "Inga labb-VMer hittades."

    if [[ "$target" == "detonation" ]]; then
        ok "$DETO_NET saknar libvirt-forward, mgmt-länkar är down och $WAN_NET är up."
    else
        ok "Mgmt-, WAN- och detonationslänkar är satta up."
    fi

    if [[ "$target" == "dev" && "$DRY_RUN" == "false" ]]; then
        "$LAB_ROOT/scripts/lab-dns.sh" dev
    fi
}

require_tools

case "$MODE" in
    status)
        require_networks
        status
        ;;
    dev|detonation)
        apply_mode "$MODE"
        echo
        status
        ;;
esac
