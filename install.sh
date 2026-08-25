#!/usr/bin/env bash
set -Eeuo pipefail
set +x
IFS=$'\n\t'
umask 077

# Root execution must not inherit user-controlled Docker, APT, curl, Git, or
# Python configuration. The installer always talks to the local Docker socket.
export PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export DOCKER_HOST='unix:///var/run/docker.sock'
unset DOCKER_CONTEXT DOCKER_CONFIG COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_ENV_FILES
unset PYTHONHOME PYTHONPATH CURL_HOME CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
unset GNUPGHOME APT_CONFIG GIT_CONFIG_COUNT

readonly INSTALLER_VERSION='1.0.1'
readonly CONFIG_SCHEMA_VERSION='1'
readonly MANAGED_BY='remnawave-node-bootstrap'
readonly INSTALL_DIR='/opt/remnanode'
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly BOOTSTRAP_CONFIG="${INSTALL_DIR}/bootstrap.conf"
readonly BACKUP_ROOT="${INSTALL_DIR}/backups"
readonly LOCK_DIR='/run/remnawave-node-bootstrap'
readonly LOCK_FILE="${LOCK_DIR}/installer.lock"
readonly NODE_IMAGE='remnawave/node:3.3.2@sha256:50708731676b87b239f3dff8c40f2c62ff88fbbba216bacfb0f683dcaf467763'
readonly DOCKER_GPG_FINGERPRINT='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
readonly ROLLBACK_FAILURE_EXIT=70

PANEL_IP=''
NODE_PORT='2222'
HY2_PORT='10443'
PANEL_IP_SET=0
NODE_PORT_SET=0
HY2_PORT_SET=0
FIREWALL_MODE_SET=0
FIREWALL_MODE='ufw'
SECRET_KEY=''

HAD_MANAGED_INSTALL=0
PREVIOUS_PANEL_IP=''
PREVIOUS_NODE_PORT=''
PREVIOUS_HY2_PORT=''
PREVIOUS_FIREWALL_MODE=''
PREVIOUS_UFW_POLICY_HASH=''
PREVIOUS_EFFECTIVE_FIREWALL_HASH=''
PREVIOUS_CONTAINER_PRESENT=0
PREVIOUS_CONTAINER_RUNNING=0
PREVIOUS_TCP_LISTENER_STATE='absent'
PREVIOUS_HY2_LISTENER_STATE='absent'
UFW_PREVIOUS_ACTIVE=0
UFW_MUTATED=0
CURRENT_UFW_POLICY_HASH=''
CURRENT_EFFECTIVE_FIREWALL_HASH=''
SNAPSHOT_UFW_POLICY_HASH=''
SNAPSHOT_EFFECTIVE_FIREWALL_HASH=''
SNAPSHOT_CONTAINER_PRESENT=0
SNAPSHOT_CONTAINER_RUNNING=0
SNAPSHOT_CONTAINER_IMAGE=''
SNAPSHOT_CONTAINER_MARKER=''
SNAPSHOT_DOCKER_INVENTORY_HASH=''
SNAPSHOT_MANAGED_MANIFEST_HASH=''
SNAPSHOT_UFW_MANIFEST_HASH=''

BACKUP_DIR=''
BACKUP_COMPLETE=0
MANAGED_MUTATIONS_STARTED=0
SUCCESS=0
declare -a ROLLBACK_ERRORS=()
declare -a TEMPORARY_FILES=()

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [options]

Options:
  --panel-ip IPV4          Remnawave Panel public IPv4
  --node-port PORT         Node API TCP port (default: 2222)
  --hy2-port PORT          Hysteria2 UDP port (default: 10443)
  --external-firewall      Do not install or modify UFW; acknowledge that an
                           external/provider firewall enforces the same policy
  -h, --help               Show this help

SECRET_KEY is intentionally accepted only through a hidden interactive prompt.
It is never accepted through argv or an environment variable.
EOF
}

validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    (( value >= 1 && value <= 65535 ))
}

validate_ipv4() {
    local value="$1"
    local a b c d extra octet
    IFS=. read -r a b c d extra <<<"$value"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
    [[ "$value" != '0.0.0.0' && "$value" != '255.255.255.255' ]]
}

read_setting() {
    local key="$1"
    local file="$2"
    awk -F= -v wanted="$key" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$file"
}

prompt_value() {
    local variable_name="$1"
    local prompt="$2"
    local default_value="$3"
    local value=''
    printf '%s [%s]: ' "$prompt" "$default_value" >/dev/tty
    read -r value </dev/tty
    printf -v "$variable_name" '%s' "${value:-$default_value}"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --panel-ip)
                (($# >= 2)) || die '--panel-ip requires a value'
                PANEL_IP="$2"
                PANEL_IP_SET=1
                shift 2
                ;;
            --node-port)
                (($# >= 2)) || die '--node-port requires a value'
                NODE_PORT="$2"
                NODE_PORT_SET=1
                shift 2
                ;;
            --hy2-port)
                (($# >= 2)) || die '--hy2-port requires a value'
                HY2_PORT="$2"
                HY2_PORT_SET=1
                shift 2
                ;;
            --external-firewall)
                FIREWALL_MODE='external'
                FIREWALL_MODE_SET=1
                shift
                ;;
            --no-ufw)
                die '--no-ufw was replaced by the explicit --external-firewall acknowledgement'
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

require_root_and_tty() {
    (( EUID == 0 )) || die 'Run as root: sudo bash install.sh'
    [[ -r /dev/tty && -w /dev/tty ]] || die 'An interactive TTY is required'
}

acquire_installer_lock() {
    # /run is commonly world-writable/sticky. Create atomically and never
    # chmod/chown an already-existing path that could be a symlink.
    if ! mkdir -m 0700 -- "$LOCK_DIR" 2>/dev/null; then
        [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || die "Unsafe lock directory: ${LOCK_DIR}"
    fi
    [[ "$(stat -c '%u:%g:%a' -- "$LOCK_DIR")" == '0:0:700' ]] || \
        die "${LOCK_DIR} must be root:root mode 0700"

    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || die "Unsafe lock file: ${LOCK_FILE}"
        [[ "$(stat -c '%u:%g:%a' -- "$LOCK_FILE")" == '0:0:600' ]] || \
            die "${LOCK_FILE} must be root:root mode 0600"
    else
        ( umask 077; : >"$LOCK_FILE" )
        [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || die 'Unable to create a safe lock file'
        chown root:root "$LOCK_FILE"
        chmod 0600 "$LOCK_FILE"
    fi
    exec 9<>"$LOCK_FILE"
    flock -n 9 || die "Another installer process holds ${LOCK_FILE}"
}

detect_platform() {
    [[ -r /etc/os-release ]] || die '/etc/os-release not found'
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04|ubuntu:24.04) ;;
        *) die "Supported systems: Ubuntu 22.04/24.04; got ${ID:-unknown} ${VERSION_ID:-unknown}" ;;
    esac
    case "$(uname -m)" in
        x86_64|aarch64|arm64) ;;
        *) die 'Supported architectures: amd64 and arm64' ;;
    esac
}

assert_root_regular_file() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || die "Expected a regular managed file: ${path}"
    [[ "$(stat -c '%u:%g' -- "$path")" == '0:0' ]] || die "Managed file is not root-owned: ${path}"
}

docker_daemon_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

preflight_installation_identity() {
    if [[ -L "$INSTALL_DIR" || ( -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ) ]]; then
        die "Unsafe installation path: ${INSTALL_DIR}"
    fi
    if [[ ! -e "$INSTALL_DIR" ]]; then
        if docker_daemon_available && docker inspect remnanode >/dev/null 2>&1; then
            die 'An unmanaged container named remnanode already exists'
        fi
        return 0
    fi

    [[ "$(stat -c '%u:%g:%a' -- "$INSTALL_DIR")" == '0:0:700' ]] || die "${INSTALL_DIR} must be root:root mode 0700"
    if [[ -e "$BACKUP_ROOT" || -L "$BACKUP_ROOT" ]]; then
        [[ -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" ]] || die "Unsafe backup path: ${BACKUP_ROOT}"
        [[ "$(stat -c '%u:%g:%a' -- "$BACKUP_ROOT")" == '0:0:700' ]] || die "${BACKUP_ROOT} must be root:root mode 0700"
    fi

    local path managed_file_count=0
    for path in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG"; do
        [[ -e "$path" || -L "$path" ]] && ((managed_file_count += 1))
    done
    if (( managed_file_count == 0 )); then
        while IFS= read -r -d '' path; do
            [[ "$(basename -- "$path")" == 'backups' ]] || \
                die "Unknown content in installation directory: ${path}"
        done < <(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print0)
        return 0
    fi
    (( managed_file_count == 3 )) || die 'Partial managed installation detected; refusing takeover'

    for path in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG"; do
        assert_root_regular_file "$path"
    done
    while IFS= read -r -d '' path; do
        case "$(basename -- "$path")" in
            docker-compose.yml|.env|bootstrap.conf|backups) ;;
            *) die "Unknown content in managed directory: ${path}" ;;
        esac
    done < <(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print0)

    [[ "$(read_setting MANAGED_BY "$BOOTSTRAP_CONFIG")" == "$MANAGED_BY" ]] || \
        die 'Existing installation has no trusted bootstrap marker; refusing takeover'
    [[ "$(read_setting CONFIG_SCHEMA_VERSION "$BOOTSTRAP_CONFIG")" == "$CONFIG_SCHEMA_VERSION" ]] || \
        die 'Existing bootstrap schema is unsupported'
    [[ "$(stat -c '%a' -- "$ENV_FILE")" == '600' ]] || die "${ENV_FILE} must be mode 0600"

    local previous_image
    previous_image="$(read_setting NODE_IMAGE "$BOOTSTRAP_CONFIG")"
    [[ -n "$previous_image" ]] || die 'Existing bootstrap config has no NODE_IMAGE'
    grep -Fq "image: ${previous_image}" "$COMPOSE_FILE" || die 'Compose image does not match bootstrap metadata'
    grep -Eq '^[[:space:]]*container_name:[[:space:]]*remnanode[[:space:]]*$' "$COMPOSE_FILE" || \
        die 'Compose file does not own container remnanode'

    HAD_MANAGED_INSTALL=1
    PREVIOUS_PANEL_IP="$(read_setting PANEL_IP "$BOOTSTRAP_CONFIG")"
    PREVIOUS_NODE_PORT="$(read_setting NODE_PORT "$BOOTSTRAP_CONFIG")"
    PREVIOUS_HY2_PORT="$(read_setting HY2_PORT "$BOOTSTRAP_CONFIG")"
    PREVIOUS_FIREWALL_MODE="$(read_setting FIREWALL_MODE "$BOOTSTRAP_CONFIG")"
    PREVIOUS_UFW_POLICY_HASH="$(read_setting UFW_POLICY_HASH "$BOOTSTRAP_CONFIG")"
    PREVIOUS_EFFECTIVE_FIREWALL_HASH="$(read_setting EFFECTIVE_FIREWALL_HASH "$BOOTSTRAP_CONFIG")"
    validate_ipv4 "$PREVIOUS_PANEL_IP" || die 'Stored Panel IPv4 is invalid'
    validate_port "$PREVIOUS_NODE_PORT" || die 'Stored Node port is invalid'
    validate_port "$PREVIOUS_HY2_PORT" || die 'Stored Hysteria2 port is invalid'
    [[ "$PREVIOUS_FIREWALL_MODE" == 'ufw' || "$PREVIOUS_FIREWALL_MODE" == 'external' ]] || \
        die 'Stored firewall mode is invalid'
    if [[ "$PREVIOUS_FIREWALL_MODE" == 'ufw' ]]; then
        [[ "$PREVIOUS_EFFECTIVE_FIREWALL_HASH" =~ ^[a-f0-9]{64}$ ]] || \
            die 'Managed config has no valid effective-firewall hash'
    else
        [[ "$PREVIOUS_EFFECTIVE_FIREWALL_HASH" == 'external' ]] || \
            die 'External firewall metadata is invalid'
    fi

    docker_daemon_available || die 'Existing managed install requires a reachable local Docker daemon'
    docker inspect remnanode >/dev/null 2>&1 || die 'Managed container remnanode is missing'
    PREVIOUS_CONTAINER_PRESENT=1
    if [[ "$(docker inspect --format '{{.State.Running}}' remnanode)" == 'true' ]]; then
        PREVIOUS_CONTAINER_RUNNING=1
    fi
}

check_unresolved_transactions() {
    [[ -d "$BACKUP_ROOT" ]] || return 0
    local state_file state line_count
    while IFS= read -r -d '' state_file; do
        [[ -f "$state_file" && ! -L "$state_file" && "$(stat -c '%u:%g:%a' -- "$state_file")" == '0:0:600' ]] || \
            die "Unsafe prior transaction marker: ${state_file}"
        line_count="$(wc -l <"$state_file")"
        [[ "$line_count" -eq 1 ]] || die "Corrupted prior transaction marker: ${state_file}"
        state="$(<"$state_file")"
        case "$state" in
            APPLYING|ROLLBACK_INCOMPLETE)
                die "Unresolved prior transaction: ${state_file}. Reconcile it before rerunning."
                ;;
            PREPARED|COMPLETE|ROLLED_BACK) ;;
            *) die "Unknown prior transaction state in ${state_file}" ;;
        esac
    done < <(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -name transaction.state -print0 2>/dev/null)
}

collect_inputs() {
    if (( HAD_MANAGED_INSTALL == 1 )); then
        (( PANEL_IP_SET == 1 )) || PANEL_IP="$PREVIOUS_PANEL_IP"
        (( NODE_PORT_SET == 1 )) || NODE_PORT="$PREVIOUS_NODE_PORT"
        (( HY2_PORT_SET == 1 )) || HY2_PORT="$PREVIOUS_HY2_PORT"
        if (( FIREWALL_MODE_SET == 0 )); then
            FIREWALL_MODE="$PREVIOUS_FIREWALL_MODE"
        elif [[ "$FIREWALL_MODE" != "$PREVIOUS_FIREWALL_MODE" ]]; then
            die 'Automatic firewall-mode migration is intentionally unsupported; reconcile firewall rules manually first'
        fi
    fi

    if [[ -z "$PANEL_IP" ]]; then
        printf 'Remnawave Panel public IPv4: ' >/dev/tty
        read -r PANEL_IP </dev/tty
    fi
    validate_ipv4 "$PANEL_IP" || die "Invalid Panel IPv4: ${PANEL_IP}"
    if (( NODE_PORT_SET == 0 && HAD_MANAGED_INSTALL == 0 )); then
        prompt_value NODE_PORT 'Node API TCP port' "$NODE_PORT"
    fi
    if (( HY2_PORT_SET == 0 && HAD_MANAGED_INSTALL == 0 )); then
        prompt_value HY2_PORT 'Hysteria2 UDP port' "$HY2_PORT"
    fi
    validate_port "$NODE_PORT" || die "Invalid Node API port: ${NODE_PORT}"
    validate_port "$HY2_PORT" || die "Invalid Hysteria2 port: ${HY2_PORT}"
    [[ "$NODE_PORT" != "$HY2_PORT" ]] || die 'Node TCP and Hysteria2 UDP ports must be distinct for unambiguous operations'

    if (( HAD_MANAGED_INSTALL == 1 )); then
        SECRET_KEY="$(read_setting SECRET_KEY "$ENV_FILE")"
        local keep=''
        printf 'Keep the existing root-only SECRET_KEY? [Y/n]: ' >/dev/tty
        read -r keep </dev/tty
        case "${keep:-Y}" in
            Y|y|YES|Yes|yes) ;;
            *) SECRET_KEY='' ;;
        esac
    fi
    if [[ -z "$SECRET_KEY" ]]; then
        printf 'Paste SECRET_KEY from the Remnawave Node card (input hidden): ' >/dev/tty
        read -r -s SECRET_KEY </dev/tty
        printf '\n' >/dev/tty
    fi
    [[ "$SECRET_KEY" =~ ^[A-Za-z0-9+/=_-]{128,}$ ]] || \
        die 'SECRET_KEY has an unexpected format; copy it again from the Node creation card'
}

show_plan_and_confirm() {
    local operation='fresh install'
    (( HAD_MANAGED_INSTALL == 1 )) && operation='managed reconfiguration'
    printf '\nDeployment plan\n'
    printf '  Operation:       %s\n' "$operation"
    printf '  Panel IPv4:      %s\n' "$PANEL_IP"
    printf '  Node API:        TCP/%s (Panel only)\n' "$NODE_PORT"
    printf '  Hysteria2:       UDP/%s (public data plane)\n' "$HY2_PORT"
    printf '  Firewall:        %s\n' "$FIREWALL_MODE"
    printf '  Container image: Remnawave Node 3.3.2, pinned OCI digest\n'
    printf '  Secret:          hidden; stored root-only in %s\n' "$ENV_FILE"
    printf '  Packages:        Docker/UFW prerequisites may be installed and are not removed by rollback\n'
    if [[ "$FIREWALL_MODE" == 'external' ]]; then
        warn "External firewall mode: before publishing, allow UDP/${HY2_PORT} publicly and TCP/${NODE_PORT} only from ${PANEL_IP}."
    fi
    local confirmation=''
    printf '\nType APPLY to execute this plan: ' >/dev/tty
    read -r confirmation </dev/tty
    [[ "$confirmation" == 'APPLY' ]] || die 'Plan cancelled; no managed changes were made'
}

write_transaction_state() {
    local state="$1"
    [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || return 1
    case "$state" in
        PREPARED|APPLYING|COMPLETE|ROLLBACK_INCOMPLETE|ROLLED_BACK) ;;
        *) return 1 ;;
    esac
    local temporary=''
    temporary="$(mktemp "${BACKUP_DIR}/transaction.state.new.XXXXXX")" || return 1
    if ! printf '%s\n' "$state" >"$temporary" || ! chmod 0600 "$temporary" || ! sync "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -fT -- "$temporary" "${BACKUP_DIR}/transaction.state"; then
        rm -f -- "$temporary"
        return 1
    fi
    sync "$BACKUP_DIR" || return 1
}

prepare_backup() {
    if [[ ! -e "$INSTALL_DIR" ]]; then
        mkdir -m 0700 -- "$INSTALL_DIR"
        chown root:root "$INSTALL_DIR"
    fi
    if [[ ! -e "$BACKUP_ROOT" ]]; then
        mkdir -m 0700 -- "$BACKUP_ROOT"
        chown root:root "$BACKUP_ROOT"
    fi

    local stamp file name file_mode file_uid file_gid file_size file_hash
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    BACKUP_DIR="$(mktemp -d "${BACKUP_ROOT}/${stamp}.XXXXXX")"
    chown root:root "$BACKUP_DIR"
    chmod 0700 "$BACKUP_DIR"

    {
        printf 'installer_version=%s\n' "$INSTALLER_VERSION"
        printf 'had_managed_install=%s\n' "$HAD_MANAGED_INSTALL"
        printf 'previous_container_present=%s\n' "$PREVIOUS_CONTAINER_PRESENT"
        printf 'previous_container_running=%s\n' "$PREVIOUS_CONTAINER_RUNNING"
    } >"${BACKUP_DIR}/metadata"
    chmod 0600 "${BACKUP_DIR}/metadata"
    : >"${BACKUP_DIR}/managed-files.manifest"

    for file in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG"; do
        if [[ -f "$file" ]]; then
            name="$(basename -- "$file")"
            cp -a -- "$file" "${BACKUP_DIR}/${name}"
            cmp -s -- "$file" "${BACKUP_DIR}/${name}" || die "Backup verification failed for ${file}"
            file_mode="$(stat -c '%a' -- "${BACKUP_DIR}/${name}")"
            file_uid="$(stat -c '%u' -- "${BACKUP_DIR}/${name}")"
            file_gid="$(stat -c '%g' -- "${BACKUP_DIR}/${name}")"
            file_size="$(stat -c '%s' -- "${BACKUP_DIR}/${name}")"
            file_hash="$(sha256sum -- "${BACKUP_DIR}/${name}" | awk '{print $1}')"
            printf 'present\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$name" "$file_mode" "$file_uid" "$file_gid" "$file_size" "$file_hash" \
                >>"${BACKUP_DIR}/managed-files.manifest"
        else
            name="$(basename -- "$file")"
            printf 'missing\t%s\t%s\t-\t-\t-\t-\t-\n' "$file" "$name" \
                >>"${BACKUP_DIR}/managed-files.manifest"
        fi
    done
    chmod 0600 "${BACKUP_DIR}/managed-files.manifest"
    SNAPSHOT_MANAGED_MANIFEST_HASH="$(sha256sum -- "${BACKUP_DIR}/managed-files.manifest" | awk '{print $1}')"
    if docker_daemon_available && docker inspect remnanode >/dev/null 2>&1; then
        docker inspect --format 'image={{.Config.Image}} state={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}} started={{.State.StartedAt}}' \
            remnanode >"${BACKUP_DIR}/container-summary.txt"
    else
        printf 'absent\n' >"${BACKUP_DIR}/container-summary.txt"
    fi
    chmod 0600 "${BACKUP_DIR}/container-summary.txt"
}

manifest_record_for_path() {
    local manifest="$1"
    local expected_path="$2"
    awk -F '\t' -v expected="$expected_path" '
        $2 == expected {record=$0; count += 1}
        END {if (count != 1) exit 3; print record}
    ' "$manifest"
}

file_matches_metadata() {
    local path="$1"
    local expected_mode="$2"
    local expected_uid="$3"
    local expected_gid="$4"
    local expected_size="$5"
    local expected_hash="$6"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ "$expected_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    [[ "$expected_size" =~ ^[0-9]+$ ]] || return 1
    [[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$(stat -c '%a' -- "$path")" == "$expected_mode" ]] || return 1
    [[ "$(stat -c '%u' -- "$path")" == "$expected_uid" ]] || return 1
    [[ "$(stat -c '%g' -- "$path")" == "$expected_gid" ]] || return 1
    [[ "$(stat -c '%s' -- "$path")" == "$expected_size" ]] || return 1
    [[ "$(sha256sum -- "$path" | awk '{print $1}')" == "$expected_hash" ]]
}

verify_managed_backup_integrity() {
    local manifest="${BACKUP_DIR}/managed-files.manifest"
    [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" && "$(stat -c '%u:%g:%a' -- "$BACKUP_DIR")" == '0:0:700' ]] || return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    [[ "$(stat -c '%u:%g:%a' -- "$manifest")" == '0:0:600' ]] || return 1
    [[ -n "$SNAPSHOT_MANAGED_MANIFEST_HASH" && \
        "$(sha256sum -- "$manifest" | awk '{print $1}')" == "$SNAPSHOT_MANAGED_MANIFEST_HASH" ]] || return 1
    [[ "$(wc -l <"$manifest")" -eq 3 ]] || return 1
    local destination expected_name record presence backup_name mode uid gid size hash
    for destination in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG"; do
        expected_name="$(basename -- "$destination")"
        record="$(manifest_record_for_path "$manifest" "$destination")" || return 1
        IFS=$'\t' read -r presence _ backup_name mode uid gid size hash <<<"$record"
        [[ "$backup_name" == "$expected_name" ]] || return 1
        case "$presence" in
            present)
                file_matches_metadata "${BACKUP_DIR}/${backup_name}" "$mode" "$uid" "$gid" "$size" "$hash" || return 1
                ;;
            missing)
                [[ "$mode" == '-' && "$uid" == '-' && "$gid" == '-' && "$size" == '-' && "$hash" == '-' ]] || return 1
                [[ ! -e "${BACKUP_DIR}/${backup_name}" && ! -L "${BACKUP_DIR}/${backup_name}" ]] || return 1
                ;;
            *) return 1 ;;
        esac
    done
}

verify_live_managed_snapshot() {
    local manifest="${BACKUP_DIR}/managed-files.manifest"
    local destination record presence backup_name mode uid gid size hash
    for destination in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG"; do
        record="$(manifest_record_for_path "$manifest" "$destination")" || return 1
        IFS=$'\t' read -r presence _ backup_name mode uid gid size hash <<<"$record"
        case "$presence" in
            present) file_matches_metadata "$destination" "$mode" "$uid" "$gid" "$size" "$hash" || return 1 ;;
            missing) [[ ! -e "$destination" && ! -L "$destination" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
}

install_base_packages() {
    info 'Installing required OS packages'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    local packages=(ca-certificates curl gnupg python3 iproute2 util-linux)
    [[ "$FIREWALL_MODE" == 'ufw' ]] && packages+=(ufw iptables nftables)
    apt-get install -y -qq "${packages[@]}"
}

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        info 'Docker and Compose plugin already installed'
        systemctl enable --now docker >/dev/null
        docker info >/dev/null
        return 0
    fi

    info 'Installing Docker Engine from the signed Docker APT repository'
    # shellcheck disable=SC1091
    source /etc/os-release
    local repository_os="$ID"
    local codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "$codename" ]] || die 'Unable to determine distribution codename'

    install -d -m 0755 /etc/apt/keyrings
    local key_tmp gpg_home
    key_tmp="$(mktemp /run/docker-gpg.XXXXXX)"
    gpg_home="$(mktemp -d /run/docker-gpg-home.XXXXXX)"
    chmod 0700 "$gpg_home"
    TEMPORARY_FILES+=("$key_tmp" "$gpg_home")
    if ! curl --disable --noproxy '*' --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --silent --show-error --location \
        "https://download.docker.com/linux/${repository_os}/gpg" -o "$key_tmp"; then
        rm -f -- "$key_tmp"
        die 'Unable to download Docker repository signing key'
    fi

    local -a primary_fingerprints=()
    mapfile -t primary_fingerprints < <(
        gpg --batch --no-options --homedir "$gpg_home" --show-keys --with-colons "$key_tmp" 2>/dev/null |
            awk -F: '$1 == "pub" {want=1; next} want && $1 == "fpr" {print $10; want=0}'
    )
    if (( ${#primary_fingerprints[@]} != 1 )) || [[ "${primary_fingerprints[0]:-}" != "$DOCKER_GPG_FINGERPRINT" ]]; then
        rm -f -- "$key_tmp"
        die 'Docker signing-key bundle must contain exactly the expected primary key'
    fi
    if ! gpg --batch --no-options --homedir "$gpg_home" --dearmor --yes --output /etc/apt/keyrings/docker.gpg "$key_tmp"; then
        rm -f -- "$key_tmp"
        die 'Unable to install Docker repository signing key'
    fi
    rm -f -- "$key_tmp"
    [[ "$gpg_home" == /run/docker-gpg-home.* && -d "$gpg_home" && ! -L "$gpg_home" ]] || \
        die 'Refusing to remove an unexpected temporary GPG directory'
    rm -rf -- "$gpg_home"
    chmod 0644 /etc/apt/keyrings/docker.gpg

    local architecture
    architecture="$(dpkg --print-architecture)"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$architecture" "$repository_os" "$codename" >/etc/apt/sources.list.d/docker.list
    chmod 0644 /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker >/dev/null
    docker compose version >/dev/null
    docker info >/dev/null
}

verify_container_identity_after_docker_start() {
    if docker inspect remnanode >/dev/null 2>&1; then
        (( HAD_MANAGED_INSTALL == 1 )) || die 'An unmanaged dormant container named remnanode was found after Docker started'
        local configured_image expected_image working_dir
        configured_image="$(docker inspect --format '{{.Config.Image}}' remnanode)"
        expected_image="$(read_setting NODE_IMAGE "$BOOTSTRAP_CONFIG")"
        working_dir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' remnanode)"
        [[ "$configured_image" == "$expected_image" ]] || die 'Existing remnanode image does not match its managed compose file'
        [[ "$working_dir" == "$INSTALL_DIR" ]] || die 'Existing remnanode was not created by this managed Compose project'
    elif (( HAD_MANAGED_INSTALL == 1 )); then
        die 'Managed remnanode container disappeared before apply'
    fi
}

docker_inventory_snapshot() {
    docker ps --all --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}' | LC_ALL=C sort
}

compute_docker_inventory_hash() {
    docker_inventory_snapshot | sha256sum | awk '{print $1}'
}

assert_dedicated_docker_inventory() {
    local inventory foreign
    inventory="$(docker_inventory_snapshot)"
    if (( HAD_MANAGED_INSTALL == 0 )); then
        [[ -z "$inventory" ]] || \
            die 'This VPS already has Docker containers; use a dedicated clean VPS for Remnawave Node'
        return 0
    fi
    foreign="$(awk -F '\t' '$2 != "remnanode" {print}' <<<"$inventory")"
    [[ -z "$foreign" ]] || \
        die 'Foreign Docker containers detected; this bootstrap requires a dedicated Node VPS'
    [[ "$(awk -F '\t' '$2 == "remnanode" {count += 1} END {print count + 0}' <<<"$inventory")" -eq 1 ]] || \
        die 'Managed Docker inventory does not contain exactly one remnanode container'
}

ufw_policy_files() {
    printf '%s\n' \
        /etc/default/ufw \
        /etc/ufw/ufw.conf \
        /etc/ufw/sysctl.conf \
        /etc/ufw/user.rules \
        /etc/ufw/user6.rules \
        /etc/ufw/before.rules \
        /etc/ufw/before6.rules \
        /etc/ufw/after.rules \
        /etc/ufw/after6.rules \
        /etc/ufw/before.init \
        /etc/ufw/after.init
}

compute_ufw_policy_hash() {
    local path
    {
        while IFS= read -r path; do
            if [[ -f "$path" && ! -L "$path" ]]; then
                printf 'present %s %s ' "$path" "$(stat -c '%u:%g:%a' -- "$path")"
                sha256sum -- "$path" | awk '{print $1}'
            else
                printf 'missing %s\n' "$path"
            fi
        done < <(ufw_policy_files)
    } | sha256sum | awk '{print $1}'
}

compute_ufw_backup_policy_hash() {
    local manifest="${BACKUP_DIR}/ufw-files.manifest"
    local path record presence backup_name mode uid gid size hash
    {
        while IFS= read -r path; do
            record="$(manifest_record_for_path "$manifest" "$path")" || return 1
            IFS=$'\t' read -r presence _ backup_name mode uid gid size hash <<<"$record"
            case "$presence" in
                present) printf 'present %s %s:%s:%s %s\n' "$path" "$uid" "$gid" "$mode" "$hash" ;;
                missing) printf 'missing %s\n' "$path" ;;
                *) return 1 ;;
            esac
        done < <(ufw_policy_files)
    } | sha256sum | awk '{print $1}'
}

effective_firewall_snapshot() {
    local command_name output
    local -a save_commands=(iptables-save ip6tables-save)
    [[ -s /proc/net/ip_tables_names ]] && save_commands+=(iptables-legacy-save)
    [[ -s /proc/net/ip6_tables_names ]] && save_commands+=(ip6tables-legacy-save)
    for command_name in "${save_commands[@]}"; do
        printf '### %s\n' "$command_name"
        if command -v "$command_name" >/dev/null 2>&1; then
            output="$($command_name)" || return 1
            sed -E '/^# (Generated by|Completed on) /d' <<<"$output"
        else
            printf 'missing\n'
        fi
    done
    printf '### nft stateless ruleset\n'
    if command -v nft >/dev/null 2>&1; then
        output="$(nft --stateless list ruleset 2>/dev/null)" || return 1
        printf '%s\n' "$output"
    else
        printf 'missing\n'
    fi
}

compute_effective_firewall_hash() {
    effective_firewall_snapshot | sha256sum | awk '{print $1}'
}

snapshot_firewall_and_complete_backup() {
    local path backup_name file_mode file_uid file_gid file_size file_hash
    mkdir -m 0700 -- "${BACKUP_DIR}/ufw-files"
    : >"${BACKUP_DIR}/ufw-files.manifest"
    while IFS= read -r path; do
        backup_name="$(printf '%s' "$path" | sed 's#^/##; s#/#__#g')"
        if [[ -f "$path" && ! -L "$path" ]]; then
            cp -a -- "$path" "${BACKUP_DIR}/ufw-files/${backup_name}"
            cmp -s -- "$path" "${BACKUP_DIR}/ufw-files/${backup_name}" || die "Firewall backup verification failed: ${path}"
            file_mode="$(stat -c '%a' -- "${BACKUP_DIR}/ufw-files/${backup_name}")"
            file_uid="$(stat -c '%u' -- "${BACKUP_DIR}/ufw-files/${backup_name}")"
            file_gid="$(stat -c '%g' -- "${BACKUP_DIR}/ufw-files/${backup_name}")"
            file_size="$(stat -c '%s' -- "${BACKUP_DIR}/ufw-files/${backup_name}")"
            file_hash="$(sha256sum -- "${BACKUP_DIR}/ufw-files/${backup_name}" | awk '{print $1}')"
            printf 'present\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$path" "$backup_name" "$file_mode" "$file_uid" "$file_gid" "$file_size" "$file_hash" \
                >>"${BACKUP_DIR}/ufw-files.manifest"
        elif [[ -e "$path" || -L "$path" ]]; then
            die "Unsafe firewall policy path: ${path}"
        else
            printf 'missing\t%s\t-\t-\t-\t-\t-\t-\n' "$path" >>"${BACKUP_DIR}/ufw-files.manifest"
        fi
    done < <(ufw_policy_files)
    chmod 0600 "${BACKUP_DIR}/ufw-files.manifest"
    SNAPSHOT_UFW_MANIFEST_HASH="$(sha256sum -- "${BACKUP_DIR}/ufw-files.manifest" | awk '{print $1}')"

    UFW_PREVIOUS_ACTIVE=0
    if command -v ufw >/dev/null 2>&1; then
        LC_ALL=C ufw status verbose >"${BACKUP_DIR}/ufw-status.txt" 2>&1 || die 'Unable to snapshot UFW status'
        LC_ALL=C ufw show added >"${BACKUP_DIR}/ufw-added.txt" 2>&1 || die 'Unable to snapshot UFW rules'
        if head -n 1 "${BACKUP_DIR}/ufw-status.txt" | grep -q '^Status: active$'; then
            UFW_PREVIOUS_ACTIVE=1
        fi
    else
        printf 'ufw absent\n' >"${BACKUP_DIR}/ufw-status.txt"
        printf 'ufw absent\n' >"${BACKUP_DIR}/ufw-added.txt"
    fi
    chmod 0600 "${BACKUP_DIR}/ufw-status.txt" "${BACKUP_DIR}/ufw-added.txt"
    printf 'ufw_previous_active=%s\n' "$UFW_PREVIOUS_ACTIVE" >>"${BACKUP_DIR}/metadata"
    verify_live_ufw_snapshot || die 'Live firewall files changed while their backup was being created'
    SNAPSHOT_UFW_POLICY_HASH="$(compute_ufw_backup_policy_hash)" || \
        die 'Unable to derive the firewall policy hash from its backup manifest'
    printf 'ufw_policy_hash=%s\n' "$SNAPSHOT_UFW_POLICY_HASH" >>"${BACKUP_DIR}/metadata"
    SNAPSHOT_EFFECTIVE_FIREWALL_HASH="$(compute_effective_firewall_hash)" || \
        die 'Unable to snapshot the effective firewall ruleset'
    printf 'effective_firewall_hash=%s\n' "$SNAPSHOT_EFFECTIVE_FIREWALL_HASH" >>"${BACKUP_DIR}/metadata"

    verify_backup_integrity || die 'Completed backup failed its integrity manifest verification'
    local sync_path
    for sync_path in \
        "${BACKUP_DIR}/metadata" \
        "${BACKUP_DIR}/managed-files.manifest" \
        "${BACKUP_DIR}/ufw-files.manifest" \
        "${BACKUP_DIR}/runtime-baseline.txt" \
        "${BACKUP_DIR}/container-summary.txt"; do
        sync "$sync_path"
    done
    sync -f "$BACKUP_DIR"
    write_transaction_state PREPARED
    BACKUP_COMPLETE=1
}

verify_ufw_backup_integrity() {
    local manifest="${BACKUP_DIR}/ufw-files.manifest"
    [[ -d "${BACKUP_DIR}/ufw-files" && ! -L "${BACKUP_DIR}/ufw-files" && \
        "$(stat -c '%u:%g:%a' -- "${BACKUP_DIR}/ufw-files")" == '0:0:700' ]] || return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    [[ "$(stat -c '%u:%g:%a' -- "$manifest")" == '0:0:600' ]] || return 1
    [[ -n "$SNAPSHOT_UFW_MANIFEST_HASH" && \
        "$(sha256sum -- "$manifest" | awk '{print $1}')" == "$SNAPSHOT_UFW_MANIFEST_HASH" ]] || return 1
    [[ "$(wc -l <"$manifest")" -eq 11 ]] || return 1
    local path record presence backup_name mode uid gid size hash expected_name
    while IFS= read -r path; do
        record="$(manifest_record_for_path "$manifest" "$path")" || return 1
        IFS=$'\t' read -r presence _ backup_name mode uid gid size hash <<<"$record"
        expected_name="$(printf '%s' "$path" | sed 's#^/##; s#/#__#g')"
        case "$presence" in
            present)
                [[ "$backup_name" == "$expected_name" ]] || return 1
                file_matches_metadata "${BACKUP_DIR}/ufw-files/${backup_name}" "$mode" "$uid" "$gid" "$size" "$hash" || return 1
                ;;
            missing)
                [[ "$backup_name" == '-' && "$mode" == '-' && "$uid" == '-' && "$gid" == '-' && "$size" == '-' && "$hash" == '-' ]] || return 1
                [[ ! -e "${BACKUP_DIR}/ufw-files/${expected_name}" && ! -L "${BACKUP_DIR}/ufw-files/${expected_name}" ]] || return 1
                ;;
            *) return 1 ;;
        esac
    done < <(ufw_policy_files)
}

verify_live_ufw_snapshot() {
    local manifest="${BACKUP_DIR}/ufw-files.manifest"
    local path record presence backup_name mode uid gid size hash
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    while IFS= read -r path; do
        record="$(manifest_record_for_path "$manifest" "$path")" || return 1
        IFS=$'\t' read -r presence _ backup_name mode uid gid size hash <<<"$record"
        case "$presence" in
            present)
                file_matches_metadata "$path" "$mode" "$uid" "$gid" "$size" "$hash" || return 1
                ;;
            missing)
                [[ ! -e "$path" && ! -L "$path" ]] || return 1
                ;;
            *) return 1 ;;
        esac
    done < <(ufw_policy_files)
}

verify_backup_integrity() {
    verify_managed_backup_integrity && verify_ufw_backup_integrity
}

container_pids() {
    docker top remnanode -eo pid 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ {print $1}'
}

listener_lines() {
    local protocol="$1"
    local port="$2"
    case "$protocol" in
        tcp) ss -H -lntp 2>/dev/null ;;
        udp) ss -H -lnup 2>/dev/null ;;
        *) return 2 ;;
    esac | awk -v suffix=":${port}" '$4 ~ suffix "$" {print}'
}

has_listener() {
    [[ -n "$(listener_lines "$1" "$2")" ]]
}

listener_owned_by_remnanode() {
    local protocol="$1"
    local port="$2"
    local known_pids lines line listener_pids pid
    known_pids="$(container_pids)"
    [[ -n "$known_pids" ]] || return 1
    lines="$(listener_lines "$protocol" "$port")"
    [[ -n "$lines" ]] || return 1
    while IFS= read -r line; do
        [[ -n "$line" ]] || return 1
        listener_pids="$(grep -oE 'pid=[0-9]+' <<<"$line" | cut -d= -f2 | sort -u || true)"
        [[ -n "$listener_pids" ]] || return 1
        while IFS= read -r pid; do
            grep -qxF "$pid" <<<"$known_pids" || return 1
        done <<<"$listener_pids"
    done <<<"$lines"
    return 0
}

check_listener_collisions() {
    if has_listener tcp "$NODE_PORT"; then
        if (( HAD_MANAGED_INSTALL == 1 )) && [[ "$NODE_PORT" == "$PREVIOUS_NODE_PORT" ]] && \
            listener_owned_by_remnanode tcp "$NODE_PORT"; then
            info "TCP/${NODE_PORT} is owned by the existing managed remnanode"
        else
            die "TCP/${NODE_PORT} is owned by another process"
        fi
    fi
    if has_listener udp "$HY2_PORT"; then
        if (( HAD_MANAGED_INSTALL == 1 )) && [[ "$HY2_PORT" == "$PREVIOUS_HY2_PORT" ]] && \
            listener_owned_by_remnanode udp "$HY2_PORT"; then
            info "UDP/${HY2_PORT} is owned by the existing managed remnanode"
        else
            die "UDP/${HY2_PORT} is owned by another process; it will not be exposed"
        fi
    fi
}

classify_listener_state() {
    local protocol="$1"
    local port="$2"
    if ! has_listener "$protocol" "$port"; then
        printf 'absent\n'
    elif listener_owned_by_remnanode "$protocol" "$port"; then
        printf 'owned\n'
    else
        return 2
    fi
}

listener_state_matches() {
    local expected="$1"
    local protocol="$2"
    local port="$3"
    case "$expected" in
        owned) listener_owned_by_remnanode "$protocol" "$port" ;;
        absent) ! has_listener "$protocol" "$port" ;;
        ignore) return 0 ;;
        *) return 2 ;;
    esac
}

snapshot_runtime_baseline() {
    SNAPSHOT_CONTAINER_PRESENT=0
    SNAPSHOT_CONTAINER_RUNNING=0
    SNAPSHOT_CONTAINER_IMAGE=''
    SNAPSHOT_CONTAINER_MARKER=''
    PREVIOUS_TCP_LISTENER_STATE='absent'
    PREVIOUS_HY2_LISTENER_STATE='absent'
    SNAPSHOT_DOCKER_INVENTORY_HASH="$(compute_docker_inventory_hash)" || \
        die 'Unable to snapshot Docker inventory'

    if docker inspect remnanode >/dev/null 2>&1; then
        SNAPSHOT_CONTAINER_PRESENT=1
        SNAPSHOT_CONTAINER_IMAGE="$(docker inspect --format '{{.Config.Image}}' remnanode)"
        if [[ "$(docker inspect --format '{{.State.Running}}' remnanode)" == 'true' ]]; then
            SNAPSHOT_CONTAINER_RUNNING=1
            SNAPSHOT_CONTAINER_MARKER="$(docker inspect --format '{{.State.StartedAt}} {{.RestartCount}}' remnanode)"
        fi
    fi
    (( SNAPSHOT_CONTAINER_PRESENT == PREVIOUS_CONTAINER_PRESENT )) || \
        die 'Container presence drifted before the runtime snapshot'
    (( SNAPSHOT_CONTAINER_RUNNING == PREVIOUS_CONTAINER_RUNNING )) || \
        die 'Container running state drifted before the runtime snapshot'

    if (( HAD_MANAGED_INSTALL == 1 )); then
        local expected_image
        expected_image="$(read_setting NODE_IMAGE "$BOOTSTRAP_CONFIG")"
        [[ "$SNAPSHOT_CONTAINER_IMAGE" == "$expected_image" ]] || \
            die 'Container image drifted before the runtime snapshot'
        PREVIOUS_TCP_LISTENER_STATE="$(classify_listener_state tcp "$PREVIOUS_NODE_PORT")" || \
            die "TCP/${PREVIOUS_NODE_PORT} has mixed or foreign ownership"
        PREVIOUS_HY2_LISTENER_STATE="$(classify_listener_state udp "$PREVIOUS_HY2_PORT")" || \
            die "UDP/${PREVIOUS_HY2_PORT} has mixed or foreign ownership"
        if (( PREVIOUS_CONTAINER_RUNNING == 0 )); then
            [[ "$PREVIOUS_TCP_LISTENER_STATE" == 'absent' && "$PREVIOUS_HY2_LISTENER_STATE" == 'absent' ]] || \
                die 'A stopped managed container cannot own listeners'
        else
            [[ "$PREVIOUS_TCP_LISTENER_STATE" == 'owned' ]] || \
                die 'Running managed node does not exclusively own its Node API listener'
            sleep 2
            [[ "$(docker inspect --format '{{.State.StartedAt}} {{.RestartCount}}' remnanode 2>/dev/null || true)" == \
                "$SNAPSHOT_CONTAINER_MARKER" ]] || die 'Managed container is not stable before apply'
            listener_state_matches "$PREVIOUS_TCP_LISTENER_STATE" tcp "$PREVIOUS_NODE_PORT" || \
                die 'Node API listener drifted during the runtime snapshot'
            listener_state_matches "$PREVIOUS_HY2_LISTENER_STATE" udp "$PREVIOUS_HY2_PORT" || \
                die 'Hysteria2 listener drifted during the runtime snapshot'
        fi
    fi

    {
        printf 'container_present=%s\n' "$SNAPSHOT_CONTAINER_PRESENT"
        printf 'container_running=%s\n' "$SNAPSHOT_CONTAINER_RUNNING"
        printf 'container_image=%s\n' "$SNAPSHOT_CONTAINER_IMAGE"
        printf 'container_marker=%s\n' "$SNAPSHOT_CONTAINER_MARKER"
        printf 'previous_tcp_listener=%s\n' "$PREVIOUS_TCP_LISTENER_STATE"
        printf 'previous_hy2_listener=%s\n' "$PREVIOUS_HY2_LISTENER_STATE"
        printf 'docker_inventory_hash=%s\n' "$SNAPSHOT_DOCKER_INVENTORY_HASH"
    } >"${BACKUP_DIR}/runtime-baseline.txt"
    chmod 0600 "${BACKUP_DIR}/runtime-baseline.txt"
}

runtime_snapshot_is_current() {
    local present=0 running=0 image='' marker=''
    if docker inspect remnanode >/dev/null 2>&1; then
        present=1
        image="$(docker inspect --format '{{.Config.Image}}' remnanode)"
        if [[ "$(docker inspect --format '{{.State.Running}}' remnanode)" == 'true' ]]; then
            running=1
            marker="$(docker inspect --format '{{.State.StartedAt}} {{.RestartCount}}' remnanode)"
        fi
    fi
    (( present == SNAPSHOT_CONTAINER_PRESENT && running == SNAPSHOT_CONTAINER_RUNNING )) || return 1
    [[ "$image" == "$SNAPSHOT_CONTAINER_IMAGE" && "$marker" == "$SNAPSHOT_CONTAINER_MARKER" ]] || return 1
    [[ "$(compute_docker_inventory_hash)" == "$SNAPSHOT_DOCKER_INVENTORY_HASH" ]] || return 1
    if (( HAD_MANAGED_INSTALL == 1 )); then
        listener_state_matches "$PREVIOUS_TCP_LISTENER_STATE" tcp "$PREVIOUS_NODE_PORT" || return 1
        listener_state_matches "$PREVIOUS_HY2_LISTENER_STATE" udp "$PREVIOUS_HY2_PORT" || return 1
    fi
}

verify_pre_apply_drift() {
    verify_backup_integrity || die 'Backup integrity verification failed before apply'
    verify_live_managed_snapshot || die 'Managed files changed after their backup; refusing apply'
    runtime_snapshot_is_current || die 'Container or listener state changed after its snapshot; refusing apply'
    verify_live_ufw_snapshot || die 'Firewall policy files changed after their backup; refusing apply'
    [[ "$(compute_ufw_policy_hash)" == "$SNAPSHOT_UFW_POLICY_HASH" ]] || \
        die 'Firewall policy files changed after their snapshot; refusing apply'
    [[ "$(compute_effective_firewall_hash)" == "$SNAPSHOT_EFFECTIVE_FIREWALL_HASH" ]] || \
        die 'Effective firewall rules changed after their snapshot; refusing apply'
    local active_now=0
    if command -v ufw >/dev/null 2>&1 && \
        LC_ALL=C ufw status 2>/dev/null | head -n 1 | grep -q '^Status: active$'; then
        active_now=1
    fi
    (( active_now == UFW_PREVIOUS_ACTIVE )) || die 'UFW active state changed after its snapshot; refusing apply'
    check_listener_collisions
}

find_unsafe_ufw_rule() {
    local status_text="$1"
    local port="$2"
    local panel_ip="$3"
    local output rc
    if output="$(UFW_STATUS_TEXT="$status_text" python3 -I - "$port" "$panel_ip" 2>/dev/null <<'PY'
import ipaddress
import os
import re
import subprocess
import sys

port = int(sys.argv[1])
panel_ip = sys.argv[2]
line_pattern = re.compile(
    r"^(?P<destination>.+?)\s{2,}(?P<action>ALLOW|LIMIT|DENY|REJECT)"
    r"(?:\s+IN)?\s{2,}(?P<source>.+?)\s*$"
)
port_pattern = re.compile(r"^(\d+)(?::(\d+))?(?:/(tcp|udp))?$")


def port_spec_covers(value: str) -> bool:
    match = port_pattern.fullmatch(value.strip())
    if not match or match.group(3) == "udp":
        return False
    start = int(match.group(1))
    end = int(match.group(2) or start)
    return start <= port <= end


def profile_covers(profile: str) -> bool:
    result = subprocess.run(
        ["ufw", "app", "info", profile],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode != 0:
        return True
    values = re.findall(r"\b\d+(?::\d+)?(?:/(?:tcp|udp))?\b", result.stdout)
    return not values or any(port_spec_covers(value) for value in values)


def source_contains_panel(source: str, is_v6: bool) -> bool:
    if is_v6:
        return False
    if source == "Anywhere":
        return True
    try:
        return ipaddress.ip_address(panel_ip) in ipaddress.ip_network(source, strict=False)
    except ValueError:
        return True


for raw_line in os.environ.get("UFW_STATUS_TEXT", "").splitlines():
    stripped = raw_line.strip()
    match = line_pattern.match(stripped)
    if not match:
        if re.search(r"\b(?:ALLOW|LIMIT|DENY|REJECT)\b", stripped):
            raise SystemExit(11)
        continue
    action = match.group("action")
    is_v6 = "(v6)" in match.group("destination") or "(v6)" in match.group("source")
    destination = re.sub(r"\s+\(v6\)$", "", match.group("destination"))
    destination = destination.split(" on ", 1)[0].strip()
    source = match.group("source").split(" #", 1)[0].strip()
    source = re.sub(r"\s+\(v6\)$", "", source)

    if destination == "Anywhere":
        covers = True
    elif port_pattern.fullmatch(destination):
        covers = port_spec_covers(destination)
    else:
        covers = profile_covers(destination)
    if not covers:
        continue

    if action == "ALLOW":
        unsafe = is_v6 or source not in {panel_ip, f"{panel_ip}/32"}
    elif action == "LIMIT":
        unsafe = True
    else:
        unsafe = source_contains_panel(source, is_v6)

    if unsafe:
        print(raw_line.strip())
        raise SystemExit(0)
raise SystemExit(10)
PY
    )"; then
        printf '%s\n' "$output"
        return 0
    else
        rc=$?
    fi
    case "$rc" in
        10) return 1 ;;
        *) return 2 ;;
    esac
}

assert_pristine_ufw_conffiles() {
    local conffiles path expected_hash current_hash template
    conffiles="$(dpkg-query -W -f='${Conffiles}\n' ufw 2>/dev/null)" || \
        die 'Unable to inspect the installed UFW package metadata'
    for path in /etc/default/ufw /etc/ufw/sysctl.conf; do
        expected_hash="$(awk -v target="$path" '$1 == target {print $2; exit}' <<<"$conffiles")"
        [[ "$expected_hash" =~ ^[a-f0-9]{32}$ ]] || \
            die "UFW package has no verifiable pristine checksum for ${path}; use --external-firewall"
        [[ -f "$path" && ! -L "$path" ]] || \
            die "UFW conffile is missing or unsafe: ${path}"
        current_hash="$(md5sum -- "$path" | awk '{print $1}')"
        [[ "$current_hash" == "$expected_hash" ]] || \
            die "UFW conffile was customized before bootstrap: ${path}; use --external-firewall"
    done

    for path in \
        /etc/ufw/ufw.conf \
        /etc/ufw/before.rules \
        /etc/ufw/before6.rules \
        /etc/ufw/user.rules \
        /etc/ufw/user6.rules \
        /etc/ufw/after.rules \
        /etc/ufw/after6.rules; do
        case "$path" in
            /etc/ufw/ufw.conf) template='/usr/share/ufw/ufw.conf' ;;
            *) template="/usr/share/ufw/iptables/$(basename -- "$path")" ;;
        esac
        [[ -f "$path" && ! -L "$path" && -f "$template" && ! -L "$template" ]] || \
            die "UFW pristine template is missing or unsafe for ${path}; use --external-firewall"
        [[ "$(stat -c '%u:%g' -- "$path")" == '0:0' ]] || \
            die "UFW policy file is not root-owned: ${path}"
        cmp -s -- "$path" "$template" || \
            die "UFW policy was customized before bootstrap: ${path}; use --external-firewall"
    done
    for path in /etc/ufw/before.init /etc/ufw/after.init; do
        template="/usr/share/ufw/$(basename -- "$path")"
        [[ -f "$path" && ! -L "$path" && ! -x "$path" && -f "$template" && ! -L "$template" ]] || \
            die "Custom or executable UFW hook detected: ${path}; use --external-firewall"
        [[ "$(stat -c '%u:%g' -- "$path")" == '0:0' ]] || \
            die "UFW hook is not root-owned: ${path}"
        cmp -s -- "$path" "$template" || \
            die "UFW hook was customized before bootstrap: ${path}; use --external-firewall"
    done
}

assert_clean_effective_input_rules() {
    local command_name output nft_rules
    if ! command -v iptables-save >/dev/null 2>&1 || ! command -v ip6tables-save >/dev/null 2>&1; then
        die 'iptables-save backends are unavailable; use --external-firewall'
    fi
    local -a save_commands=(iptables-save ip6tables-save)
    [[ -s /proc/net/ip_tables_names ]] && save_commands+=(iptables-legacy-save)
    [[ -s /proc/net/ip6_tables_names ]] && save_commands+=(ip6tables-legacy-save)
    for command_name in "${save_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || continue
        output="$($command_name)" || die "Unable to inspect ${command_name} rules"
        if ! IPTABLES_SAVE_TEXT="$output" python3 -I - <<'PY'
import os
import re

builtins = {
    "filter": {"INPUT", "FORWARD", "OUTPUT"},
    "nat": {"PREROUTING", "INPUT", "OUTPUT", "POSTROUTING"},
    "mangle": {"PREROUTING", "INPUT", "FORWARD", "OUTPUT", "POSTROUTING"},
    "raw": {"PREROUTING", "OUTPUT"},
    "security": {"INPUT", "FORWARD", "OUTPUT"},
}
table = None
for raw in os.environ.get("IPTABLES_SAVE_TEXT", "").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("*"):
        table = line[1:]
        if table not in builtins:
            raise SystemExit(2)
        continue
    if line == "COMMIT":
        if table is None:
            raise SystemExit(2)
        table = None
        continue
    match = re.fullmatch(r":(\S+)\s+(\S+)\s+\[[0-9]+:[0-9]+\]", line)
    if match and table is not None:
        chain, policy = match.groups()
        if chain not in builtins[table] or policy != "ACCEPT":
            raise SystemExit(2)
        continue
    # Any append, custom chain, counter, NAT, mangle, or otherwise unknown
    # statement means this is not a pristine dedicated host.
    raise SystemExit(2)
if table is not None:
    raise SystemExit(2)
PY
        then
            die "Pre-existing ${command_name} firewall rules detected; use --external-firewall"
        fi
    done

    if command -v nft >/dev/null 2>&1; then
        nft_rules="$(nft --stateless list ruleset 2>/dev/null)" || \
            die 'Unable to inspect the nftables ruleset'
        if ! NFT_RULESET="$nft_rules" python3 -I - <<'PY'
import os
import re

text = os.environ.get("NFT_RULESET", "")
text = re.sub(r"(?m)^\s*#.*$", "", text)
text = re.sub(r"table\s+\S+\s+\S+\s*\{", "", text)
text = re.sub(r"chain\s+\S+\s*\{", "", text)
text = re.sub(
    r"type\s+(?:filter|nat|route)\s+hook\s+"
    r"(?:prerouting|input|forward|output|postrouting|ingress)\s+"
    r"priority\s+[^;]+;",
    "",
    text,
)
text = re.sub(r"policy\s+accept\s*;", "", text)
text = text.replace("}", "")
if text.strip():
    raise SystemExit(2)
PY
        then
            die 'Pre-existing native nftables rules detected; use --external-firewall'
        fi
    fi
}

preflight_firewall() {
    [[ "$FIREWALL_MODE" == 'ufw' ]] || return 0
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        die 'firewalld is active; use --external-firewall after configuring it yourself'
    fi
    if systemctl is-active --quiet nftables 2>/dev/null || \
        systemctl is-active --quiet netfilter-persistent 2>/dev/null; then
        die 'Another firewall service is active; use --external-firewall after configuring it yourself'
    fi
    command -v ufw >/dev/null 2>&1 || die 'UFW package installation failed'

    local status added current_hash current_effective_hash
    status="$(LC_ALL=C ufw status verbose)"
    added="$(LC_ALL=C ufw show added)"
    if (( HAD_MANAGED_INSTALL == 1 )); then
        [[ "$PREVIOUS_FIREWALL_MODE" == 'ufw' ]] || die 'Firewall mode drift detected'
        head -n 1 <<<"$status" | grep -q '^Status: active$' || die 'Managed UFW is no longer active'
        [[ -n "$PREVIOUS_UFW_POLICY_HASH" ]] || die 'Managed config has no UFW policy hash'
        current_hash="$(compute_ufw_policy_hash)"
        [[ "$current_hash" == "$PREVIOUS_UFW_POLICY_HASH" ]] || \
            die 'UFW policy changed outside this installer; use --external-firewall after manual reconciliation'
        current_effective_hash="$(compute_effective_firewall_hash)" || \
            die 'Unable to inspect the managed effective firewall ruleset'
        [[ "$current_effective_hash" == "$PREVIOUS_EFFECTIVE_FIREWALL_HASH" ]] || \
            die 'Effective firewall rules changed outside this installer; use --external-firewall after manual reconciliation'
    else
        head -n 1 <<<"$status" | grep -q '^Status: inactive$' || \
            die 'An active pre-existing UFW policy is not imported automatically; configure it yourself and use --external-firewall'
        ! grep -q '^ufw ' <<<"$added" || \
            die 'Inactive UFW has latent rules; reconcile them and use --external-firewall'
        assert_pristine_ufw_conffiles
        assert_clean_effective_input_rules
    fi
}

write_bootstrap_config_to() {
    local destination="$1"
    local policy_hash="$2"
    {
        printf 'MANAGED_BY=%s\n' "$MANAGED_BY"
        printf 'CONFIG_SCHEMA_VERSION=%s\n' "$CONFIG_SCHEMA_VERSION"
        printf 'INSTALLER_VERSION=%s\n' "$INSTALLER_VERSION"
        printf 'NODE_IMAGE=%s\n' "$NODE_IMAGE"
        printf 'PANEL_IP=%s\n' "$PANEL_IP"
        printf 'NODE_PORT=%s\n' "$NODE_PORT"
        printf 'HY2_PORT=%s\n' "$HY2_PORT"
        printf 'FIREWALL_MODE=%s\n' "$FIREWALL_MODE"
        printf 'UFW_POLICY_HASH=%s\n' "$policy_hash"
        printf 'EFFECTIVE_FIREWALL_HASH=%s\n' "$CURRENT_EFFECTIVE_FIREWALL_HASH"
    } >"$destination"
    chmod 0644 "$destination"
}

write_managed_files() {
    local env_tmp compose_tmp config_tmp
    env_tmp="$(mktemp "${INSTALL_DIR}/.env.new.XXXXXX")"
    compose_tmp="$(mktemp "${INSTALL_DIR}/docker-compose.yml.new.XXXXXX")"
    config_tmp="$(mktemp "${INSTALL_DIR}/bootstrap.conf.new.XXXXXX")"
    TEMPORARY_FILES+=("$env_tmp" "$compose_tmp" "$config_tmp")

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
    write_bootstrap_config_to "$config_tmp" ''

    mv -f -- "$env_tmp" "$ENV_FILE"
    mv -f -- "$compose_tmp" "$COMPOSE_FILE"
    mv -f -- "$config_tmp" "$BOOTSTRAP_CONFIG"
    chown root:root "$ENV_FILE" "$COMPOSE_FILE" "$BOOTSTRAP_CONFIG"
}

rewrite_bootstrap_config_with_policy_hash() {
    local temporary
    temporary="$(mktemp "${INSTALL_DIR}/bootstrap.conf.new.XXXXXX")"
    TEMPORARY_FILES+=("$temporary")
    write_bootstrap_config_to "$temporary" "$CURRENT_UFW_POLICY_HASH"
    mv -f -- "$temporary" "$BOOTSTRAP_CONFIG"
    chown root:root "$BOOTSTRAP_CONFIG"
}

runtime_conditions_match() {
    local node_port="$1"
    local hy2_mode="$2"
    local hy2_port="$3"
    [[ "$(docker inspect --format '{{.State.Running}}' remnanode 2>/dev/null || true)" == 'true' ]] || return 1
    listener_owned_by_remnanode tcp "$node_port" || return 1
    listener_state_matches "$hy2_mode" udp "$hy2_port"
}

wait_for_stable_runtime() {
    local node_port="$1"
    local hy2_mode="$2"
    local hy2_port="$3"
    local timeout_seconds="$4"
    local deadline=$((SECONDS + timeout_seconds)) first_marker second_marker
    while (( SECONDS < deadline )); do
        if runtime_conditions_match "$node_port" "$hy2_mode" "$hy2_port"; then
            first_marker="$(docker inspect --format '{{.State.StartedAt}} {{.RestartCount}}' remnanode)"
            sleep 3
            second_marker="$(docker inspect --format '{{.State.StartedAt}} {{.RestartCount}}' remnanode 2>/dev/null || true)"
            if [[ "$first_marker" == "$second_marker" ]] && runtime_conditions_match "$node_port" "$hy2_mode" "$hy2_port"; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

start_and_verify_node() {
    info 'Pulling the pinned Remnawave Node image'
    docker pull "$NODE_IMAGE" >/dev/null
    docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" config --quiet
    docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" up -d

    if wait_for_stable_runtime "$NODE_PORT" ignore "$HY2_PORT" 60; then
        local configured_image
        configured_image="$(docker inspect --format '{{.Config.Image}}' remnanode)"
        [[ "$configured_image" == "$NODE_IMAGE" ]] || die 'Running container does not use the pinned image'
        ok "Remnawave Node is stable and owns TCP/${NODE_PORT}"
        return 0
    fi
    docker inspect --format 'state={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' remnanode 2>/dev/null || true
    die 'Remnawave Node did not become ready within 60 seconds'
}

sync_success_state() {
    local path docker_root
    for path in "$ENV_FILE" "$COMPOSE_FILE" "$BOOTSTRAP_CONFIG" "$INSTALL_DIR"; do
        sync "$path"
    done
    if (( UFW_MUTATED == 1 )); then
        sync -f /etc/ufw
        sync -f /etc/default
    fi
    docker_root="$(docker info --format '{{.DockerRootDir}}')"
    [[ -n "$docker_root" && -d "$docker_root" && ! -L "$docker_root" ]] || \
        die 'Unable to identify a safe local Docker root for the durability barrier'
    sync -f "$INSTALL_DIR"
    sync -f "$docker_root"
}

detect_ssh_ports() {
    local ports=''
    if command -v sshd >/dev/null 2>&1; then
        ports="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu || true)"
    fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        printf '%s\n%s\n' "$ports" "${SSH_CONNECTION##* }" | awk '/^[0-9]+$/ && !seen[$0]++'
    elif [[ -n "$ports" ]]; then
        printf '%s\n' "$ports"
    else
        printf '22\n'
    fi
}

ufw_run() {
    local output
    if ! output="$(LC_ALL=C ufw "$@" 2>&1)"; then
        die "UFW command failed: ${output}"
    fi
}

ufw_delete_previous_managed_rules() {
    (( HAD_MANAGED_INSTALL == 1 )) || return 0
    local output
    if ! output="$(LC_ALL=C ufw --force delete allow from "$PREVIOUS_PANEL_IP" to any port "$PREVIOUS_NODE_PORT" proto tcp 2>&1)"; then
        die "Unable to replace previous Panel rule: ${output}"
    fi
    if ! output="$(LC_ALL=C ufw --force delete allow "${PREVIOUS_HY2_PORT}/udp" 2>&1)"; then
        die "Unable to replace previous Hysteria2 rule: ${output}"
    fi
}

verify_ufw_policy() {
    local status unsafe_rule='' verifier_rc=0
    status="$(LC_ALL=C ufw status verbose)"
    head -n 1 <<<"$status" | grep -q '^Status: active$' || die 'UFW failed to become active'
    grep -q '^Default: deny (incoming), allow (outgoing)' <<<"$status" || \
        die 'UFW defaults are not deny-incoming/allow-outgoing'
    if unsafe_rule="$(find_unsafe_ufw_rule "$status" "$NODE_PORT" "$PANEL_IP")"; then
        die "Unsafe effective UFW rule for TCP/${NODE_PORT}: ${unsafe_rule}"
    else
        verifier_rc=$?
        (( verifier_rc == 1 )) || die 'Unable to verify UFW rule safety'
    fi
    grep -Eq "^${NODE_PORT}/tcp[[:space:]]+ALLOW IN[[:space:]]+${PANEL_IP}([[:space:]]|$)" <<<"$status" || \
        die 'Exact Panel-only Node API rule is missing'
    grep -Eq "^${HY2_PORT}/udp[[:space:]]+ALLOW IN[[:space:]]+Anywhere([[:space:]]|$)" <<<"$status" || \
        die 'Public Hysteria2 UDP rule is missing'
}

configure_firewall() {
    if [[ "$FIREWALL_MODE" == 'external' ]]; then
        CURRENT_UFW_POLICY_HASH='external'
        CURRENT_EFFECTIVE_FIREWALL_HASH='external'
        warn 'External firewall was not inspected or changed by this installer'
        return 0
    fi
    UFW_MUTATED=1
    ufw_delete_previous_managed_rules

    if (( HAD_MANAGED_INSTALL == 0 )); then
        local ssh_port
        while IFS= read -r ssh_port; do
            validate_port "$ssh_port" || continue
            ufw_run allow "${ssh_port}/tcp" comment 'SSH preserved by Remnawave bootstrap'
        done < <(detect_ssh_ports)
    fi
    ufw_run allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave Panel control'
    ufw_run allow "${HY2_PORT}/udp" comment 'Hysteria2 data plane'
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    if (( UFW_PREVIOUS_ACTIVE == 1 )); then
        ufw reload >/dev/null
    else
        ufw --force enable >/dev/null
    fi
    verify_ufw_policy
    CURRENT_UFW_POLICY_HASH="$(compute_ufw_policy_hash)"
    CURRENT_EFFECTIVE_FIREWALL_HASH="$(compute_effective_firewall_hash)" || \
        die 'Unable to record the effective managed firewall ruleset'
}

record_rollback_error() {
    ROLLBACK_ERRORS+=("$1")
    warn "Rollback: $1"
}

restore_file_atomically() {
    local source="$1"
    local destination="$2"
    local mode="$3"
    local uid="$4"
    local gid="$5"
    local size="$6"
    local hash="$7"
    local parent temporary
    parent="$(dirname -- "$destination")"
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    temporary="$(mktemp "${parent}/.remnawave-restore.XXXXXX")" || return 1
    if ! cp -a -- "$source" "$temporary" || \
        ! file_matches_metadata "$temporary" "$mode" "$uid" "$gid" "$size" "$hash" || \
        ! sync "$temporary" || ! mv -fT -- "$temporary" "$destination" || ! sync "$parent"; then
        rm -f -- "$temporary"
        return 1
    fi
}

restore_firewall_snapshot() {
    (( UFW_MUTATED == 1 )) || return 0
    local presence path backup_name mode uid gid size hash
    while IFS=$'\t' read -r presence path backup_name mode uid gid size hash; do
        case "$presence" in
            present)
                if ! restore_file_atomically \
                    "${BACKUP_DIR}/ufw-files/${backup_name}" "$path" \
                    "$mode" "$uid" "$gid" "$size" "$hash"; then
                    record_rollback_error "restored ${path} does not match its backup"
                fi
                ;;
            missing)
                if [[ -e "$path" || -L "$path" ]]; then
                    if ! rm -f -- "$path"; then
                        record_rollback_error "failed to remove newly created ${path}"
                    elif ! sync "$(dirname -- "$path")"; then
                        record_rollback_error "failed to sync removal of ${path}"
                    fi
                fi
                ;;
            *) record_rollback_error "invalid firewall manifest entry for ${path}" ;;
        esac
    done <"${BACKUP_DIR}/ufw-files.manifest"

    if (( UFW_PREVIOUS_ACTIVE == 1 )); then
        if ! LC_ALL=C ufw --force enable >/dev/null 2>&1; then
            record_rollback_error 'failed to re-enable previous UFW state'
        elif ! LC_ALL=C ufw reload >/dev/null 2>&1; then
            record_rollback_error 'failed to reload restored UFW policy'
        fi
    else
        if ! LC_ALL=C ufw --force disable >/dev/null 2>&1; then
            record_rollback_error 'failed to restore inactive UFW state'
        fi
    fi
    local active_now=0
    LC_ALL=C ufw status 2>/dev/null | head -n 1 | grep -q '^Status: active$' && active_now=1
    if (( active_now != UFW_PREVIOUS_ACTIVE )); then
        record_rollback_error 'UFW active/inactive state differs from backup'
    fi
    if [[ "$(compute_ufw_policy_hash)" != "$SNAPSHOT_UFW_POLICY_HASH" ]]; then
        record_rollback_error 'restored UFW policy files differ from backup'
    fi
    if [[ "$(compute_effective_firewall_hash 2>/dev/null || true)" != "$SNAPSHOT_EFFECTIVE_FIREWALL_HASH" ]]; then
        record_rollback_error 'restored effective firewall rules differ from backup'
    fi
}

stop_current_managed_container() {
    if docker inspect remnanode >/dev/null 2>&1; then
        if [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]]; then
            if ! docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" down >/dev/null 2>&1; then
                record_rollback_error 'failed to stop the current managed container'
            fi
        else
            record_rollback_error 'cannot safely stop remnanode because current compose files are missing'
        fi
    fi
}

restore_managed_files() {
    local destination record presence backup_name mode uid gid size hash
    for destination in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG"; do
        if ! record="$(manifest_record_for_path "${BACKUP_DIR}/managed-files.manifest" "$destination")"; then
            record_rollback_error "missing managed backup manifest entry for ${destination}"
            continue
        fi
        IFS=$'\t' read -r presence _ backup_name mode uid gid size hash <<<"$record"
        if [[ "$presence" == 'present' ]]; then
            if ! restore_file_atomically \
                "${BACKUP_DIR}/${backup_name}" "$destination" \
                "$mode" "$uid" "$gid" "$size" "$hash"; then
                record_rollback_error "restored ${destination} does not match its backup"
            fi
        elif [[ "$presence" == 'missing' && ( -e "$destination" || -L "$destination" ) ]]; then
            if ! rm -f -- "$destination"; then
                record_rollback_error "failed to remove newly created ${destination}"
            elif ! sync "$(dirname -- "$destination")"; then
                record_rollback_error "failed to sync removal of ${destination}"
            fi
        elif [[ "$presence" != 'missing' ]]; then
            record_rollback_error "invalid managed backup manifest entry for ${destination}"
        fi
    done
}

restore_container_state() {
    if (( PREVIOUS_CONTAINER_PRESENT == 1 )); then
        if [[ ! -f "$COMPOSE_FILE" || ! -f "$ENV_FILE" ]]; then
            record_rollback_error 'previous compose files are unavailable; container cannot be restored'
            return 0
        fi
        if (( PREVIOUS_CONTAINER_RUNNING == 1 )); then
            if ! docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" up -d >/dev/null 2>&1; then
                record_rollback_error 'failed to restore the previously running container'
            fi
        else
            if ! docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" up --no-start >/dev/null 2>&1; then
                record_rollback_error 'failed to restore the previously stopped container'
            fi
        fi
    fi

    local present_now=0 running_now=0
    if docker inspect remnanode >/dev/null 2>&1; then
        present_now=1
        [[ "$(docker inspect --format '{{.State.Running}}' remnanode 2>/dev/null || true)" == 'true' ]] && running_now=1
    fi
    (( present_now == PREVIOUS_CONTAINER_PRESENT )) || record_rollback_error 'container presence differs from backup'
    if (( PREVIOUS_CONTAINER_PRESENT == 1 && running_now != PREVIOUS_CONTAINER_RUNNING )); then
        record_rollback_error 'container running/stopped state differs from backup'
    fi
    if (( PREVIOUS_CONTAINER_PRESENT == 1 && present_now == 1 )); then
        local expected_image actual_image
        expected_image="$(read_setting NODE_IMAGE "$BOOTSTRAP_CONFIG" 2>/dev/null || true)"
        actual_image="$(docker inspect --format '{{.Config.Image}}' remnanode 2>/dev/null || true)"
        [[ -n "$expected_image" && "$actual_image" == "$expected_image" ]] || \
            record_rollback_error 'restored container image differs from backup metadata'
    fi
    if (( PREVIOUS_CONTAINER_RUNNING == 1 && running_now == 1 )); then
        if ! wait_for_stable_runtime \
            "$PREVIOUS_NODE_PORT" "$PREVIOUS_HY2_LISTENER_STATE" "$PREVIOUS_HY2_PORT" 60; then
            record_rollback_error 'restored container/listeners did not return to a stable previous state'
        fi
    elif (( PREVIOUS_CONTAINER_RUNNING == 0 )); then
        if (( PREVIOUS_CONTAINER_PRESENT == 1 )); then
            ! has_listener tcp "$PREVIOUS_NODE_PORT" || \
                record_rollback_error 'stopped previous container unexpectedly has its Node API listener'
            ! has_listener udp "$PREVIOUS_HY2_PORT" || \
                record_rollback_error 'stopped previous container unexpectedly has its Hysteria2 listener'
        else
            ! has_listener tcp "$NODE_PORT" || record_rollback_error 'new Node API listener remained after rollback'
            ! has_listener udp "$HY2_PORT" || record_rollback_error 'new Hysteria2 listener remained after rollback'
        fi
    fi
}

sync_restored_state() {
    local path
    for path in "$INSTALL_DIR" "$BACKUP_DIR"; do
        sync "$path" >/dev/null 2>&1 || record_rollback_error "failed to sync ${path}"
    done
    if (( UFW_MUTATED == 1 )) && [[ -d /etc/ufw ]]; then
        sync -f /etc/ufw >/dev/null 2>&1 || record_rollback_error 'failed to sync restored UFW files'
        sync -f /etc/default >/dev/null 2>&1 || record_rollback_error 'failed to sync restored UFW defaults'
    fi
    sync -f "$INSTALL_DIR" >/dev/null 2>&1 || record_rollback_error 'failed to sync the installation filesystem'
}

rollback() {
    warn 'Installation failed; restoring the exact managed state'
    ROLLBACK_ERRORS=()
    if ! write_transaction_state ROLLBACK_INCOMPLETE; then
        warn 'Unable to persist fail-closed rollback marker; no restore actions were attempted'
        return 1
    fi
    if ! verify_backup_integrity; then
        record_rollback_error 'backup integrity verification failed; no restore actions were attempted'
        return 1
    fi
    local firewall_errors_before=${#ROLLBACK_ERRORS[@]}
    restore_firewall_snapshot
    if (( ${#ROLLBACK_ERRORS[@]} > firewall_errors_before )); then
        # Never restart the previous node while its Panel-only firewall ACL is
        # uncertain. Stop the current node and leave the durable unresolved
        # marker and root-only backup for manual reconciliation.
        stop_current_managed_container
        sync_restored_state
        warn 'Firewall rollback could not be proven; node remains stopped and rollback is fail-closed'
        return 1
    fi
    stop_current_managed_container
    restore_managed_files
    restore_container_state
    sync_restored_state

    if (( ${#ROLLBACK_ERRORS[@]} > 0 )); then
        warn "ROLLBACK INCOMPLETE (${#ROLLBACK_ERRORS[@]} error(s)); preserve ${BACKUP_DIR} and reconcile manually"
        return 1
    fi
    if ! write_transaction_state ROLLED_BACK; then
        warn 'Rollback restored runtime state but could not persist its completion marker'
        return 1
    fi
    ok "Rollback complete; evidence retained at ${BACKUP_DIR}"
}

on_exit() {
    local rc=$?
    local final_rc="$rc"
    trap - EXIT
    SECRET_KEY=''
    unset SECRET_KEY
    if (( rc != 0 && SUCCESS == 0 && BACKUP_COMPLETE == 1 && MANAGED_MUTATIONS_STARTED == 1 )); then
        if ! rollback; then
            final_rc="$ROLLBACK_FAILURE_EXIT"
        fi
    fi
    local temporary
    for temporary in "${TEMPORARY_FILES[@]}"; do
        if [[ -n "$temporary" && ( -f "$temporary" || -L "$temporary" ) ]]; then
            rm -f -- "$temporary" || warn "Could not remove temporary file: ${temporary}"
        elif [[ "$temporary" == /run/docker-gpg-home.* && -d "$temporary" && ! -L "$temporary" ]]; then
            rm -rf -- "$temporary" || warn 'Could not remove the temporary GPG directory'
        fi
    done
    exit "$final_rc"
}

main() {
    parse_args "$@"
    require_root_and_tty
    acquire_installer_lock
    detect_platform
    preflight_installation_identity
    check_unresolved_transactions
    collect_inputs
    show_plan_and_confirm

    prepare_backup
    install_base_packages
    preflight_firewall
    install_docker
    verify_container_identity_after_docker_start
    assert_dedicated_docker_inventory
    check_listener_collisions
    snapshot_runtime_baseline
    snapshot_firewall_and_complete_backup

    write_transaction_state APPLYING
    verify_pre_apply_drift
    MANAGED_MUTATIONS_STARTED=1
    write_managed_files
    configure_firewall
    start_and_verify_node
    if [[ "$FIREWALL_MODE" == 'ufw' ]]; then
        verify_ufw_policy
        [[ "$(compute_ufw_policy_hash)" == "$CURRENT_UFW_POLICY_HASH" ]] || \
            die 'Managed UFW files drifted before completion'
        [[ "$(compute_effective_firewall_hash)" == "$CURRENT_EFFECTIVE_FIREWALL_HASH" ]] || \
            die 'Effective firewall rules drifted before completion'
    fi
    rewrite_bootstrap_config_with_policy_hash
    sync_success_state

    write_transaction_state COMPLETE
    SUCCESS=1
    SECRET_KEY=''
    unset SECRET_KEY

    printf '\n'
    ok 'Installation complete'
    info "Root-only transaction backup: ${BACKUP_DIR}"
    printf '\nNext steps in Remnawave Panel:\n'
    printf '  1. Finish the Node card and select a Hysteria2 inbound listening on UDP/%s.\n' "$HY2_PORT"
    printf '  2. Point the new node DNS name at this VPS.\n'
    printf '  3. Create its Host with the same UDP port, valid TLS SNI, and ALPN h3.\n'
    printf '  4. Add that inbound to a squad and run: sudo bash status.sh\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap on_exit EXIT
    main "$@"
fi
