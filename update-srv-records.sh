#!/bin/bash
#
# update-srv-records.sh - publish active WireGuard peer endpoints in DNS
#
# SYNOPSIS
#     update-srv-records.sh [--once] [--dry-run] [--help]
#
# DESCRIPTION
#     Runs as a long-lived loop. Every INTERVAL seconds it:
#
#       1. Reads all peers from every WireGuard interface (`wg show all dump`)
#          and keeps those whose latest handshake is at most HANDSHAKE_MAX_AGE
#          seconds old ("active" peers).
#       2. Queries the DNS server for the records currently published for
#          the service.
#       3. Works out the difference and sends one dynamic update (nsupdate)
#          that adds or corrects records for active peers and removes the
#          records of peers that are no longer active.
#
#     If nothing changed, no update is sent.
#
# DNS LAYOUT
#     Each peer is identified by <label>, the base32 encoding of its raw
#     32-byte public key (56 characters including the trailing "====" padding,
#     which is why updates are sent with "check-names no").
#
#       _wireguard._udp.DOMAIN.          PTR  <label>._wireguard._udp.DOMAIN.
#       <label>._wireguard._udp.DOMAIN.  SRV  0 0 <port> <label>._wireguard._udp.DOMAIN.
#       <label>._wireguard._udp.DOMAIN.  A    <endpoint address, if IPv4>
#       <label>._wireguard._udp.DOMAIN.  AAAA <endpoint address, if IPv6>
#
#     The PTR set is the list of active peers (DNS-SD style); the SRV record
#     gives each peer's current endpoint port and the A or AAAA record its
#     address. A peer has one endpoint, so it has an A record or an AAAA
#     record, never both; when its endpoint changes address family the old
#     record is removed.
#
# OPTIONS
#     --once      Run a single cycle and exit instead of looping.
#     --dry-run   Print the nsupdate batch to stdout instead of sending it.
#     --help      Show this header and exit.
#
# CONFIGURATION
#     Defaults below can be overridden through the environment:
#
#       WG_DNS_DOMAIN          zone the records live in
#       WG_DNS_UPDATE_KEY      TSIG key file passed to nsupdate -k
#       WG_DNS_SERVER          server queried by dig for the current records
#       WG_DNS_TTL             TTL of the records, in seconds
#       WG_HANDSHAKE_MAX_AGE   handshake age (seconds) below which a peer is active
#       WG_DNS_INTERVAL        seconds to sleep between cycles
#
#     Updates are always sent to the local name server (nsupdate -l),
#     regardless of WG_DNS_SERVER. The script is meant to run on the host
#     that is primary for the zone.
#
# REQUIREMENTS
#     bash 4+, wg (wireguard-tools), dig and nsupdate (BIND utilities),
#     base64 and base32 (coreutils). Must run as a user allowed to run
#     `wg show` (normally root) and to read the update key.
#
# LIMITATIONS
#     Link-local IPv6 endpoints that carry a zone (fe80::1%eth0) cannot be
#     expressed in DNS; such peers are skipped with a warning.
#
# EXIT STATUS
#     Loops forever by default. With --once: 0 on success, 1 if the cycle
#     could not complete. 2 on usage error or missing dependency.

# No `set -e`: a failed cycle is logged and retried on the next pass.
shopt -s nocasematch        # DNS names compare case-insensitively
export LC_ALL=C

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DOMAIN=${WG_DNS_DOMAIN:-wireguard.example.com}
UPDATE_KEY=${WG_DNS_UPDATE_KEY:-/etc/bind/wg-update-key.key}
DNS_SERVER=${WG_DNS_SERVER:-localhost}
TTL=${WG_DNS_TTL:-10}
HANDSHAKE_MAX_AGE=${WG_HANDSHAKE_MAX_AGE:-200}
INTERVAL=${WG_DNS_INTERVAL:-90}

# Name that owns the PTR list; peer records live one label below it.
SERVICE="_wireguard._udp.$DOMAIN"

ONCE=0
DRY_RUN=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf '%s %s: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${0##*/}" "$*" >&2
}

usage() {
    # Print the header comment block of this file (everything up to the
    # first non-comment line), without the leading "# ".
    sed -n '3,/^[^#]/{/^#/!q;s/^# \{0,1\}//;p;}' "$0"
}

# Queue one nsupdate command for the current cycle.
queue() {
    UPDATES+=("$1")
}

# The functions below share these arrays, which run_cycle declares local
# and which are visible to them through bash's dynamic scoping:
#
#   ACTIVE_PEERS[label] = "address port"   peers with a recent handshake
#   DNS_PTR[label]      = PTR target       peers currently listed in DNS
#   DNS_SRV[label]      = port             port currently published
#   DNS_A[label]        = address          IPv4 address currently published
#   DNS_AAAA[label]     = address          IPv6 address currently published
#   UPDATES[]           = nsupdate commands to send

# ---------------------------------------------------------------------------
# Step 1: collect active peers from WireGuard
# ---------------------------------------------------------------------------
#
# `wg show all dump` prints, tab-separated:
#
#   interface line:  iface  private-key  public-key  listen-port  fwmark
#   peer lines:      iface  public-key  preshared-key  endpoint  allowed-ips
#                    latest-handshake  rx  tx  persistent-keepalive
#
# The first line seen for each interface is the interface line and is
# skipped. Endpoints are printed as "a.b.c.d:port" for IPv4 and
# "[address]:port" for IPv6. Returns non-zero if wg itself fails, so that a broken `wg` is not
# mistaken for "no active peers" (which would delete every record).
collect_active_peers() {
    local dump now iface="" pubkey endpoint handshake label address port
    local -a f

    dump=$(wg show all dump) || return 1
    now=$(date +%s)

    while read -ra f; do
        (( ${#f[@]} )) || continue
        if [[ "${f[0]}" != "$iface" ]]; then
            iface=${f[0]}           # interface line: holds no peer data
            continue
        fi

        pubkey=${f[1]}
        endpoint=${f[3]}
        handshake=${f[5]}

        [[ $handshake =~ ^[0-9]+$ ]] || continue
        (( now - handshake <= HANDSHAKE_MAX_AGE )) || continue

        if [[ $endpoint =~ ^([0-9]+(\.[0-9]+){3}):([0-9]+)$ ]]; then
            address=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[3]}
        elif [[ $endpoint =~ ^\[([0-9a-f:.]+)\]:([0-9]+)$ ]]; then
            address=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[2]}
        else
            # Includes zoned link-local addresses such as [fe80::1%eth0]:51820.
            log "skipping peer $pubkey: cannot publish endpoint '$endpoint'"
            continue
        fi

        label=$(printf '%s' "$pubkey" | base64 -d | base32)
        ACTIVE_PEERS[$label]="$address $port"
    done <<< "$dump"
}

# ---------------------------------------------------------------------------
# Step 2: read the records currently in DNS
# ---------------------------------------------------------------------------
#
# One dig batch asks for the PTR list plus the SRV, A and AAAA records of
# every active peer. Answer lines look like:
#
#   name  ttl  IN  PTR   target
#   name  ttl  IN  SRV   priority weight port target
#   name  ttl  IN  A     address
#   name  ttl  IN  AAAA  address
#
# Labels are upper-cased so they match the base32 labels from step 1 even
# if the server returns them in a different case. Returns non-zero if dig
# fails, so an unreachable server is not mistaken for an empty zone.
query_dns() {
    local answers label
    local -a f

    answers=$(
        {
            printf '%s PTR\n' "$SERVICE"
            for label in "${!ACTIVE_PEERS[@]}"; do
                printf '%s.%s SRV\n' "$label" "$SERVICE"
                printf '%s.%s A\n' "$label" "$SERVICE"
                printf '%s.%s AAAA\n' "$label" "$SERVICE"
            done
        } | dig "@$DNS_SERVER" +noall +answer -f -
    ) || return 1

    while read -ra f; do
        case ${f[3]:-} in
            PTR) label=${f[4]%%.*} ;;
            SRV|A|AAAA) label=${f[0]%%.*} ;;
            *) continue ;;
        esac
        label=${label^^}
        [[ -n $label ]] || continue

        case ${f[3]} in
            PTR)  DNS_PTR[$label]=${f[4]} ;;
            SRV)  DNS_SRV[$label]=${f[6]} ;;
            A)    DNS_A[$label]=${f[4]} ;;
            AAAA) DNS_AAAA[$label]=${f[4]} ;;
        esac
    done <<< "$answers"
}

# ---------------------------------------------------------------------------
# Step 3: work out what has to change
# ---------------------------------------------------------------------------

# Add or correct the records of every active peer.
queue_active_peers() {
    local label fqdn address port want_a want_aaaa

    for label in "${!ACTIVE_PEERS[@]}"; do
        fqdn="$label.$SERVICE"
        address=${ACTIVE_PEERS[$label]% *}
        port=${ACTIVE_PEERS[$label]#* }

        # The endpoint is IPv6 if it contains a colon, IPv4 otherwise. The
        # record type that does not apply is wanted empty, i.e. absent.
        want_a="" want_aaaa=""
        if [[ $address == *:* ]]; then want_aaaa=$address; else want_a=$address; fi

        # PTR: only ever added here; removal happens in queue_stale_peers.
        if [[ "${DNS_PTR[$label]:-}" != "$fqdn." ]]; then
            queue "update add $SERVICE $TTL IN PTR $fqdn."
        fi

        # A / AAAA: replace when the endpoint address changed, and remove
        # the record of the other family if the peer switched families.
        # Addresses are compared as text; wg and dig both print IPv6
        # addresses in the standard compressed form.
        if [[ "${DNS_A[$label]:-}" != "$want_a" ]]; then
            [[ -n ${DNS_A[$label]:-} ]] && queue "update delete $fqdn IN A"
            [[ -n $want_a ]] && queue "update add $fqdn $TTL IN A $want_a"
        fi
        if [[ "${DNS_AAAA[$label]:-}" != "$want_aaaa" ]]; then
            [[ -n ${DNS_AAAA[$label]:-} ]] && queue "update delete $fqdn IN AAAA"
            [[ -n $want_aaaa ]] && queue "update add $fqdn $TTL IN AAAA $want_aaaa"
        fi

        # SRV: replace when the endpoint port changed.
        if [[ "${DNS_SRV[$label]:-}" != "$port" ]]; then
            [[ -n ${DNS_SRV[$label]:-} ]] && queue "update delete $fqdn IN SRV"
            queue "update add $fqdn $TTL IN SRV 0 0 $port $fqdn"
        fi
    done
}

# Remove every record of peers that are listed in DNS but no longer active.
queue_stale_peers() {
    local label fqdn

    for label in "${!DNS_PTR[@]}"; do
        [[ -n ${ACTIVE_PEERS[$label]:-} ]] && continue
        fqdn="$label.$SERVICE"
        queue "update delete $fqdn IN A"
        queue "update delete $fqdn IN AAAA"
        queue "update delete $fqdn IN SRV"
        queue "update delete $SERVICE IN PTR $fqdn."
    done
}

# ---------------------------------------------------------------------------
# Step 4: send the update
# ---------------------------------------------------------------------------
#
# All changes go out as a single nsupdate transaction. "check-names no" is
# needed because the base32 labels contain "=" padding.
apply_updates() {
    (( ${#UPDATES[@]} )) || return 0

    if (( DRY_RUN )); then
        printf '%s\n' "check-names no" "${UPDATES[@]}" "send"
        return 0
    fi

    printf '%s\n' "check-names no" "${UPDATES[@]}" "send" |
        nsupdate -k "$UPDATE_KEY" -l
}

# ---------------------------------------------------------------------------
# One full pass
# ---------------------------------------------------------------------------

run_cycle() {
    local -A ACTIVE_PEERS=() DNS_PTR=() DNS_SRV=() DNS_A=() DNS_AAAA=()
    local -a UPDATES=()

    collect_active_peers || { log "wg show failed; skipping this cycle"; return 1; }
    query_dns            || { log "DNS query to $DNS_SERVER failed; skipping this cycle"; return 1; }
    queue_active_peers
    queue_stale_peers
    apply_updates        || { log "nsupdate failed; will retry next cycle"; return 1; }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

while (( $# )); do
    case $1 in
        --once)    ONCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         echo "${0##*/}: unknown option '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

for cmd in wg dig nsupdate base64 base32; do
    command -v "$cmd" >/dev/null || { log "required command not found: $cmd"; exit 2; }
done

if (( ONCE )); then
    run_cycle
    exit $?
fi

while true; do
    run_cycle
    sleep "$INTERVAL"
done
