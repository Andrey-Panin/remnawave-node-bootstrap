#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# Reuse the installer's redacted read-only validation helpers. main() is guarded
# and is not executed when install.sh is sourced.
# shellcheck source=install.sh
source "${SCRIPT_DIR}/install.sh"

HEALTHY=1

status_info() { printf '[INFO] %s\n' "$*"; }
status_ok() { printf '[ OK ] %s\n' "$*"; }
status_warn() { printf '[WARN] %s\n' "$*" >&2; }
status_fail() { printf '[FAIL] %s\n' "$*" >&2; HEALTHY=0; }

(( EUID == 0 )) || die 'Run as root: sudo bash status.sh'
[[ -f "$BOOTSTRAP_CONFIG" && ! -L "$BOOTSTRAP_CONFIG" ]] || die "${BOOTSTRAP_CONFIG} not found or unsafe"
[[ "$(read_setting MANAGED_BY "$BOOTSTRAP_CONFIG")" == "$MANAGED_BY" ]] || die 'Bootstrap ownership marker is missing'
[[ "$(read_setting CONFIG_SCHEMA_VERSION "$BOOTSTRAP_CONFIG")" == "$CONFIG_SCHEMA_VERSION" ]] || die 'Unsupported bootstrap schema'

NODE_PORT="$(read_setting NODE_PORT "$BOOTSTRAP_CONFIG")"
HY2_PORT="$(read_setting HY2_PORT "$BOOTSTRAP_CONFIG")"
PANEL_IP="$(read_setting PANEL_IP "$BOOTSTRAP_CONFIG")"
FIREWALL_MODE="$(read_setting FIREWALL_MODE "$BOOTSTRAP_CONFIG")"
EXPECTED_IMAGE="$(read_setting NODE_IMAGE "$BOOTSTRAP_CONFIG")"
EXPECTED_UFW_HASH="$(read_setting UFW_POLICY_HASH "$BOOTSTRAP_CONFIG")"
EXPECTED_EFFECTIVE_FIREWALL_HASH="$(read_setting EFFECTIVE_FIREWALL_HASH "$BOOTSTRAP_CONFIG")"
EXPECTED_FIREWALL_HASH_SCHEMA="$(read_setting FIREWALL_HASH_SCHEMA "$BOOTSTRAP_CONFIG")"
[[ -n "$EXPECTED_FIREWALL_HASH_SCHEMA" ]] || EXPECTED_FIREWALL_HASH_SCHEMA='1'
CONFIG_INSTALLER_VERSION="$(read_setting INSTALLER_VERSION "$BOOTSTRAP_CONFIG")"

validate_ipv4 "$PANEL_IP" || die 'Stored Panel IPv4 is invalid'
validate_port "$NODE_PORT" || die 'Stored Node port is invalid'
validate_port "$HY2_PORT" || die 'Stored Hysteria2 port is invalid'
case "$FIREWALL_MODE" in
    ufw)
        [[ "$EXPECTED_FIREWALL_HASH_SCHEMA" == '1' || "$EXPECTED_FIREWALL_HASH_SCHEMA" == '2' ]] || \
            die 'Managed firewall-hash schema is unsupported'
        [[ "$EXPECTED_UFW_HASH" =~ ^[a-f0-9]{64}$ && "$EXPECTED_EFFECTIVE_FIREWALL_HASH" =~ ^[a-f0-9]{64}$ ]] || \
            die 'Managed firewall hashes are missing or invalid'
        ;;
    external)
        [[ "$EXPECTED_UFW_HASH" == 'external' && "$EXPECTED_EFFECTIVE_FIREWALL_HASH" == 'external' ]] || \
            die 'External firewall metadata is invalid'
        ;;
    *) die "Unknown firewall mode: ${FIREWALL_MODE}" ;;
esac

status_info "Panel address: ${PANEL_IP}"
status_info "Node API port: ${NODE_PORT}/tcp"
status_info "Hysteria2 port: ${HY2_PORT}/udp"
status_info "Firewall mode: ${FIREWALL_MODE}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    status_fail 'Local Docker daemon is unavailable'
elif ! docker inspect remnanode >/dev/null 2>&1; then
    status_fail 'Container remnanode does not exist'
else
    STATE="$(docker inspect --format '{{.State.Status}}' remnanode)"
    IMAGE="$(docker inspect --format '{{.Config.Image}}' remnanode)"
    RESTARTS="$(docker inspect --format '{{.RestartCount}}' remnanode)"
    FIRST_MARKER="$(docker inspect --format '{{.State.StartedAt}} {{.RestartCount}}' remnanode)"
    sleep 2
    SECOND_MARKER="$(docker inspect --format '{{.State.StartedAt}} {{.RestartCount}}' remnanode 2>/dev/null || true)"
    status_info "Container: ${STATE}; restarts=${RESTARTS}"
    status_info "Image: ${IMAGE}"
    [[ "$STATE" == 'running' ]] || status_fail 'Container is not running'
    [[ "$IMAGE" == "$EXPECTED_IMAGE" ]] || status_fail 'Container image differs from the pinned managed image'
    [[ "$FIRST_MARKER" == "$SECOND_MARKER" ]] || status_fail 'Container restarted during the stability window'

    if listener_owned_by_remnanode tcp "$NODE_PORT"; then
        status_ok "Node API TCP/${NODE_PORT} is owned by remnanode"
    elif has_listener tcp "$NODE_PORT"; then
        status_fail "Node API TCP/${NODE_PORT} is owned by another process"
    else
        status_fail "Node API TCP/${NODE_PORT} is absent"
    fi

    if listener_owned_by_remnanode udp "$HY2_PORT"; then
        status_ok "Hysteria2 UDP/${HY2_PORT} is owned by remnanode"
    elif has_listener udp "$HY2_PORT"; then
        status_fail "Hysteria2 UDP/${HY2_PORT} is owned by another process"
    else
        status_fail "Hysteria2 UDP/${HY2_PORT} is absent; finish the Node and activate the matching inbound in Panel"
    fi
fi

case "$FIREWALL_MODE" in
    ufw)
        if ! command -v ufw >/dev/null 2>&1; then
            status_fail 'Managed UFW is not installed'
        else
            UFW_STATUS="$(LC_ALL=C ufw status verbose 2>/dev/null || true)"
            if ! head -n 1 <<<"$UFW_STATUS" | grep -q '^Status: active$'; then
                status_fail 'Managed UFW is not active'
            elif ! grep -q '^Default: deny (incoming), allow (outgoing)' <<<"$UFW_STATUS"; then
                status_fail 'Managed UFW default policy drifted'
            else
                if ! CURRENT_HASH="$(compute_ufw_policy_hash 2>/dev/null)"; then
                    CURRENT_HASH=''
                    status_fail 'Managed UFW policy could not be inspected'
                elif [[ "$CURRENT_HASH" != "$EXPECTED_UFW_HASH" ]]; then
                    status_fail 'Managed UFW policy hash drifted'
                fi
                case "$EXPECTED_FIREWALL_HASH_SCHEMA" in
                    1)
                        if [[ "$CONFIG_INSTALLER_VERSION" == '1.0.6' || "$CONFIG_INSTALLER_VERSION" == '1.0.7' ]]; then
                            if ! CURRENT_EFFECTIVE_HASH="$(compute_legacy_effective_firewall_hash 2>/dev/null)"; then
                                CURRENT_EFFECTIVE_HASH=''
                            fi
                        else
                            CURRENT_EFFECTIVE_HASH=''
                        fi
                        ;;
                    2)
                        if ! CURRENT_EFFECTIVE_HASH="$(compute_effective_firewall_hash 2>/dev/null)"; then
                            CURRENT_EFFECTIVE_HASH=''
                        fi
                        ;;
                esac
                [[ -n "$CURRENT_EFFECTIVE_HASH" && "$CURRENT_EFFECTIVE_HASH" == "$EXPECTED_EFFECTIVE_FIREWALL_HASH" ]] || \
                    status_fail 'Effective firewall rules drifted or could not be inspected'
                UNSAFE=''
                UFW_VERIFIER_RC=0
                if UNSAFE="$(find_unsafe_ufw_rule "$UFW_STATUS" "$NODE_PORT" "$PANEL_IP")"; then
                    status_fail "Unsafe UFW rule covers Node API TCP/${NODE_PORT}: ${UNSAFE}"
                else
                    UFW_VERIFIER_RC=$?
                    if (( UFW_VERIFIER_RC == 1 )); then
                        if (( HEALTHY == 1 )); then
                            status_ok 'UFW policy is active, unchanged, and Panel-restricted'
                        fi
                    else
                        status_fail 'UFW rule safety could not be verified'
                    fi
                fi
            fi
        fi
        ;;
    external)
        status_warn 'External firewall policy cannot be verified locally by this tool'
        ;;
    *) status_fail "Unknown firewall mode: ${FIREWALL_MODE}" ;;
esac

if (( HEALTHY == 1 )); then
    status_ok 'Node bootstrap health checks passed'
    exit 0
fi
exit 1
