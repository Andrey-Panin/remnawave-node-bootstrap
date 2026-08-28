#!/usr/bin/env bash
set -Eeuo pipefail

# Intentionally simple Remnawave Node installer.
# It never reads, configures, verifies, or restores the host firewall.

readonly SIMPLE_INSTALLER_VERSION='1.0.0'
readonly NODE_IMAGE='remnawave/node:3.3.2@sha256:50708731676b87b239f3dff8c40f2c62ff88fbbba216bacfb0f683dcaf467763'
readonly INSTALL_DIR='/opt/remnanode'
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly INFO_FILE="${INSTALL_DIR}/bootstrap.conf"

PANEL_IP='89.110.92.101'
NODE_PORT='2222'
HY2_PORT='10443'
SECRET_KEY=''

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash install-simple.sh [options]

Options:
  --panel-ip IPV4   Remnawave Panel IPv4 (default: 89.110.92.101)
  --node-port PORT  Node API TCP port (default: 2222)
  --hy2-port PORT   Hysteria2 UDP port configured later in Panel (default: 10443)
  -h, --help        Show this help

This installer does not read or modify UFW, nftables, or iptables.
SECRET_KEY is requested interactively and is not accepted through argv.
EOF
}

validate_ipv4() {
    local value="$1" octet
    local -a octets=()
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$value"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

parse_args() {
    while (($#)); do
        case "$1" in
            --panel-ip)
                (($# >= 2)) || die '--panel-ip requires a value'
                PANEL_IP="$2"
                shift 2
                ;;
            --node-port)
                (($# >= 2)) || die '--node-port requires a value'
                NODE_PORT="$2"
                shift 2
                ;;
            --hy2-port)
                (($# >= 2)) || die '--hy2-port requires a value'
                HY2_PORT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

require_environment() {
    (( EUID == 0 )) || die 'Run this installer through sudo or as root'
    [[ -r /etc/os-release ]] || die 'Unable to identify the operating system'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == 'ubuntu' ]] || die 'Only Ubuntu is supported'
    validate_ipv4 "$PANEL_IP" || die "Invalid Panel IPv4: ${PANEL_IP}"
    validate_port "$NODE_PORT" || die "Invalid Node port: ${NODE_PORT}"
    validate_port "$HY2_PORT" || die "Invalid Hysteria2 port: ${HY2_PORT}"
    [[ "$NODE_PORT" != "$HY2_PORT" ]] || die 'Node TCP and Hysteria2 UDP ports must differ'
    [[ -r /dev/tty && -w /dev/tty ]] || die 'An interactive terminal is required for SECRET_KEY'
}

read_secret() {
    printf 'SECRET_KEY from the Remnawave Node card: ' >/dev/tty
    IFS= read -r -s SECRET_KEY </dev/tty
    printf '\n' >/dev/tty
    [[ -n "$SECRET_KEY" ]] || die 'SECRET_KEY cannot be empty'
}

install_docker() {
    info 'Installing Docker prerequisites'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl

    if ! command -v docker >/dev/null 2>&1; then
        local docker_installer
        docker_installer="$(mktemp /tmp/get-docker.XXXXXX.sh)"
        curl -fsSL https://get.docker.com -o "$docker_installer"
        sh "$docker_installer"
        rm -f -- "$docker_installer"
    fi

    systemctl enable --now docker >/dev/null

    if ! docker compose version >/dev/null 2>&1; then
        if ! apt-get install -y -qq docker-compose-v2; then
            apt-get install -y -qq docker-compose-plugin
        fi
    fi
    docker compose version >/dev/null 2>&1 || die 'Docker Compose plugin is unavailable'
}

backup_previous_files() {
    local path backup_dir timestamp
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="${INSTALL_DIR}/simple-backups/${timestamp}"
    for path in "$ENV_FILE" "$COMPOSE_FILE" "$INFO_FILE"; do
        if [[ -f "$path" && ! -L "$path" ]]; then
            install -d -m 0700 "$backup_dir"
            cp -a -- "$path" "$backup_dir/"
        fi
    done
    if [[ -d "$backup_dir" ]]; then
        info "Previous files copied to ${backup_dir}"
    fi
}

write_config() {
    local env_tmp compose_tmp info_tmp
    umask 077
    install -d -m 0700 "$INSTALL_DIR"
    backup_previous_files

    env_tmp="$(mktemp "${INSTALL_DIR}/.env.new.XXXXXX")"
    compose_tmp="$(mktemp "${INSTALL_DIR}/docker-compose.yml.new.XXXXXX")"
    info_tmp="$(mktemp "${INSTALL_DIR}/bootstrap.conf.new.XXXXXX")"

    printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$SECRET_KEY" >"$env_tmp"
    chmod 0600 "$env_tmp"

    cat >"$compose_tmp" <<EOF
services:
  remnanode:
    image: ${NODE_IMAGE}
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - .env
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
EOF
    chmod 0644 "$compose_tmp"

    cat >"$info_tmp" <<EOF
MANAGED_BY=remnawave-node-simple
INSTALLER_VERSION=${SIMPLE_INSTALLER_VERSION}
NODE_IMAGE=${NODE_IMAGE}
PANEL_IP=${PANEL_IP}
NODE_PORT=${NODE_PORT}
HY2_PORT=${HY2_PORT}
FIREWALL_MODE=unmanaged
EOF
    chmod 0644 "$info_tmp"

    mv -f -- "$env_tmp" "$ENV_FILE"
    mv -f -- "$compose_tmp" "$COMPOSE_FILE"
    mv -f -- "$info_tmp" "$INFO_FILE"
    chown root:root "$ENV_FILE" "$COMPOSE_FILE" "$INFO_FILE"
}

start_node() {
    info 'Replacing only the remnanode container'
    docker rm -f remnanode >/dev/null 2>&1 || true
    docker pull "$NODE_IMAGE"
    docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" config --quiet
    docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" up -d --force-recreate

    local deadline=$((SECONDS + 45))
    while (( SECONDS < deadline )); do
        if [[ "$(docker inspect --format '{{.State.Running}}' remnanode 2>/dev/null || true)" == 'true' ]] && \
            ss -H -lnt "sport = :${NODE_PORT}" 2>/dev/null | grep -q .; then
            ok "Remnawave Node is running and listens on TCP/${NODE_PORT}"
            return 0
        fi
        sleep 2
    done

    docker ps -a --filter name='^/remnanode$'
    docker logs --tail 50 remnanode 2>&1 || true
    die 'Node did not start within 45 seconds'
}

main() {
    parse_args "$@"
    require_environment

    printf 'Simple Remnawave Node install\n'
    printf '  Panel:      %s\n' "$PANEL_IP"
    printf '  Node API:   TCP/%s\n' "$NODE_PORT"
    printf '  Hysteria2:  UDP/%s (configure the inbound in Panel)\n' "$HY2_PORT"
    printf '  Firewall:   untouched by this script\n\n'

    read_secret
    install_docker
    write_config
    start_node
    SECRET_KEY=''
    unset SECRET_KEY

    printf '\n'
    ok 'Installation complete'
    printf 'Next: finish the Node in Panel %s and select a Hysteria2 inbound on UDP/%s.\n' "$PANEL_IP" "$HY2_PORT"
    printf 'Check logs: sudo docker logs --tail 100 remnanode\n'
    printf 'This script did not call ufw, nft, iptables, or ip6tables.\n'
}

main "$@"
