#!/usr/bin/env bash
set -Eeuo pipefail
set +x
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# Reuse the installer's root-safe environment and verified file helpers. main()
# is guarded and is not executed when install.sh is sourced.
# shellcheck source=install.sh
source "${SCRIPT_DIR}/install.sh"

RECOVERY_BACKUP=''
RECOVERY_ATTEMPT_DIR=''
RECOVERY_SOURCE_VERSION=''
RECOVERY_MUTATIONS_STARTED=0
RECOVERY_SUCCESS=0
RECOVERY_INITIAL_CONTAINER_PRESENT=0
RECOVERY_INITIAL_CONTAINER_RUNNING=0

require_recovery_runtime() {
    local command_name
    for command_name in \
        docker ufw nft python3 sha256sum find sort xargs readlink stat cmp sync \
        iptables-save ip6tables-save iptables-restore ip6tables-restore; do
        command -v "$command_name" >/dev/null 2>&1 || die "Required recovery command is missing: ${command_name}"
    done
    docker info >/dev/null 2>&1 || die 'The local Docker daemon is not reachable'
    docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is unavailable'
}

recovery_usage() {
    cat <<'EOF'
Usage: sudo bash recover.sh [--backup /opt/remnanode/backups/TIMESTAMP.SUFFIX]

Safely reconciles one fresh-install transaction left in APPLYING or
ROLLBACK_INCOMPLETE. It does not recover an upgrade of a previous node.
EOF
}

parse_recovery_args() {
    while (($#)); do
        case "$1" in
            --backup)
                (($# >= 2)) || die '--backup requires a value'
                RECOVERY_BACKUP="$2"
                shift 2
                ;;
            -h|--help)
                recovery_usage
                exit 0
                ;;
            *) die "Unknown recovery option: $1" ;;
        esac
    done
}

select_recovery_backup() {
    [[ -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" && "$(stat -c '%u:%g:%a' -- "$BACKUP_ROOT")" == '0:0:700' ]] || \
        die "Unsafe backup root: ${BACKUP_ROOT}"

    local -a unresolved=()
    local marker state candidate resolved
    while IFS= read -r -d '' marker; do
        [[ -f "$marker" && ! -L "$marker" && "$(stat -c '%u:%g:%a' -- "$marker")" == '0:0:600' ]] || \
            die "Unsafe transaction marker: ${marker}"
        state="$(<"$marker")"
        [[ "$state" == 'APPLYING' || "$state" == 'ROLLBACK_INCOMPLETE' ]] && unresolved+=("$(dirname -- "$marker")")
    done < <(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -name transaction.state -print0)

    if [[ -n "$RECOVERY_BACKUP" ]]; then
        candidate="$RECOVERY_BACKUP"
        resolved="$(readlink -f -- "$candidate")" || die "Recovery backup does not resolve: ${candidate}"
        [[ "$(dirname -- "$resolved")" == "$BACKUP_ROOT" ]] || die 'Recovery backup must be an immediate child of the managed backup root'
        BACKUP_DIR="$resolved"
        local found=0
        for candidate in "${unresolved[@]}"; do
            [[ "$candidate" == "$BACKUP_DIR" ]] && found=1
        done
        (( found == 1 )) || die 'Selected backup is not an unresolved transaction'
    else
        (( ${#unresolved[@]} == 1 )) || \
            die "Expected exactly one unresolved transaction; found ${#unresolved[@]}. Use --backup explicitly."
        BACKUP_DIR="${unresolved[0]}"
    fi

    [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" && "$(stat -c '%u:%g:%a' -- "$BACKUP_DIR")" == '0:0:700' ]] || \
        die "Unsafe transaction backup: ${BACKUP_DIR}"
}

load_and_verify_legacy_transaction() {
    local metadata="${BACKUP_DIR}/metadata"
    [[ -f "$metadata" && ! -L "$metadata" && "$(stat -c '%u:%g:%a' -- "$metadata")" == '0:0:600' ]] || \
        die 'Transaction metadata is missing or unsafe'

    local had_install previous_present previous_running
    RECOVERY_SOURCE_VERSION="$(read_setting installer_version "$metadata")"
    had_install="$(read_setting had_managed_install "$metadata")"
    previous_present="$(read_setting previous_container_present "$metadata")"
    previous_running="$(read_setting previous_container_running "$metadata")"
    UFW_PREVIOUS_ACTIVE="$(read_setting ufw_previous_active "$metadata")"
    SNAPSHOT_UFW_POLICY_HASH="$(read_setting ufw_policy_hash "$metadata")"
    SNAPSHOT_EFFECTIVE_FIREWALL_HASH="$(read_setting effective_firewall_hash "$metadata")"

    [[ "$RECOVERY_SOURCE_VERSION" == '1.0.5' || "$RECOVERY_SOURCE_VERSION" == '1.0.6' ]] || \
        die "Recovery supports transaction versions 1.0.5/1.0.6; got ${RECOVERY_SOURCE_VERSION:-missing}"
    [[ "$had_install" == '0' && "$previous_present" == '0' && "$previous_running" == '0' ]] || \
        die 'This recovery tool intentionally supports only a failed fresh install with no previous node'
    [[ "$UFW_PREVIOUS_ACTIVE" == '0' ]] || die 'The failed fresh install did not start from inactive UFW'
    [[ "$SNAPSHOT_UFW_POLICY_HASH" =~ ^[a-f0-9]{64}$ && "$SNAPSHOT_EFFECTIVE_FIREWALL_HASH" =~ ^[a-f0-9]{64}$ ]] || \
        die 'Transaction firewall hashes are missing or invalid'

    SNAPSHOT_MANAGED_MANIFEST_HASH="$(sha256sum -- "${BACKUP_DIR}/managed-files.manifest" | awk '{print $1}')"
    SNAPSHOT_UFW_MANIFEST_HASH="$(sha256sum -- "${BACKUP_DIR}/ufw-files.manifest" | awk '{print $1}')"
    verify_managed_backup_integrity || die 'Managed-file backup integrity verification failed'
    verify_ufw_backup_integrity || die 'UFW-file backup integrity verification failed'
    [[ "$(compute_ufw_backup_policy_hash)" == "$SNAPSHOT_UFW_POLICY_HASH" ]] || \
        die 'UFW backup policy does not match transaction metadata'
    if [[ "$RECOVERY_SOURCE_VERSION" == '1.0.6' ]]; then
        SNAPSHOT_FIREWALL_V4_HASH="$(read_setting firewall_restore_v4_hash "$metadata")"
        SNAPSHOT_FIREWALL_V6_HASH="$(read_setting firewall_restore_v6_hash "$metadata")"
        SNAPSHOT_HOST_FIREWALL_EVIDENCE_HASH="$(read_setting firewall_host_evidence_hash "$metadata")"
        SNAPSHOT_RAW_FIREWALL_EVIDENCE_HASH="$(read_setting firewall_raw_evidence_hash "$metadata")"
        verify_firewall_backup_integrity || die 'Firewall restore images/evidence failed integrity verification'
    fi

    local destination record presence
    for destination in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG"; do
        record="$(manifest_record_for_path "${BACKUP_DIR}/managed-files.manifest" "$destination")" || \
            die "Missing managed manifest entry for ${destination}"
        IFS=$'\t' read -r presence _ <<<"$record"
        [[ "$presence" == 'missing' ]] || die 'Fresh-install recovery found a pre-existing managed file in the transaction backup'
    done
}

capture_paths() {
    local manifest="$1"
    local directory="$2"
    shift 2
    mkdir -m 0700 -- "$directory"
    : >"$manifest"
    local path name mode uid gid size hash
    for path in "$@"; do
        name="$(printf '%s' "$path" | sed 's#^/##; s#/#__#g')"
        if [[ -f "$path" && ! -L "$path" ]]; then
            cp -a -- "$path" "${directory}/${name}"
            cmp -s -- "$path" "${directory}/${name}" || return 1
            mode="$(stat -c '%a' -- "${directory}/${name}")"
            uid="$(stat -c '%u' -- "${directory}/${name}")"
            gid="$(stat -c '%g' -- "${directory}/${name}")"
            size="$(stat -c '%s' -- "${directory}/${name}")"
            hash="$(sha256sum -- "${directory}/${name}" | awk '{print $1}')"
            printf 'present\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$name" "$mode" "$uid" "$gid" "$size" "$hash" >>"$manifest"
        elif [[ -e "$path" || -L "$path" ]]; then
            return 1
        else
            printf 'missing\t%s\t%s\t-\t-\t-\t-\t-\n' "$path" "$name" >>"$manifest"
        fi
    done
    chmod 0600 "$manifest"
}

restore_captured_paths() {
    local manifest="$1"
    local directory="$2"
    local presence path name mode uid gid size hash
    while IFS=$'\t' read -r presence path name mode uid gid size hash; do
        case "$presence" in
            present)
                restore_file_atomically "${directory}/${name}" "$path" "$mode" "$uid" "$gid" "$size" "$hash" || return 1
                ;;
            missing)
                if [[ -e "$path" || -L "$path" ]]; then
                    rm -f -- "$path" || return 1
                    sync "$(dirname -- "$path")" || return 1
                fi
                ;;
            *) return 1 ;;
        esac
    done <"$manifest"
}

create_recovery_attempt() {
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    RECOVERY_ATTEMPT_DIR="$(mktemp -d "${BACKUP_DIR}/recovery-attempt-${stamp}.XXXXXX")"
    chmod 0700 "$RECOVERY_ATTEMPT_DIR"

    local -a managed_paths=("$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG")
    local -a ufw_paths=()
    mapfile -t ufw_paths < <(ufw_policy_files)
    capture_paths "${RECOVERY_ATTEMPT_DIR}/managed.manifest" "${RECOVERY_ATTEMPT_DIR}/managed" "${managed_paths[@]}" || \
        die 'Unable to capture current managed files before recovery'
    capture_paths "${RECOVERY_ATTEMPT_DIR}/ufw.manifest" "${RECOVERY_ATTEMPT_DIR}/ufw" "${ufw_paths[@]}" || \
        die 'Unable to capture current UFW files before recovery'

    iptables-save >"${RECOVERY_ATTEMPT_DIR}/current-v4.restore"
    ip6tables-save >"${RECOVERY_ATTEMPT_DIR}/current-v6.restore"
    raw_effective_firewall_snapshot >"${RECOVERY_ATTEMPT_DIR}/current-firewall.txt"
    LC_ALL=C ufw status verbose >"${RECOVERY_ATTEMPT_DIR}/current-ufw-status.txt"
    LC_ALL=C ufw show added >"${RECOVERY_ATTEMPT_DIR}/current-ufw-added.txt"
    cp -a -- "${BACKUP_DIR}/transaction.state" "${RECOVERY_ATTEMPT_DIR}/transaction.state"

    if docker inspect remnanode >/dev/null 2>&1; then
        RECOVERY_INITIAL_CONTAINER_PRESENT=1
        [[ "$(docker inspect --format '{{.State.Running}}' remnanode)" == 'true' ]] && RECOVERY_INITIAL_CONTAINER_RUNNING=1
        docker inspect --format 'image={{.Config.Image}} state={{.State.Status}} running={{.State.Running}}' \
            remnanode >"${RECOVERY_ATTEMPT_DIR}/container-summary.txt"
    else
        printf 'absent\n' >"${RECOVERY_ATTEMPT_DIR}/container-summary.txt"
    fi
    (( RECOVERY_INITIAL_CONTAINER_RUNNING == 0 )) || die 'Fail-closed recovery requires remnanode to be stopped before it starts'

    if [[ "$RECOVERY_SOURCE_VERSION" == '1.0.6' ]]; then
        cp -a -- "${BACKUP_DIR}/firewall-restore-v4.txt" "${RECOVERY_ATTEMPT_DIR}/target-v4.restore"
        cp -a -- "${BACKUP_DIR}/firewall-restore-v6.txt" "${RECOVERY_ATTEMPT_DIR}/target-v6.restore"
    else
        filter_inactive_ufw_iptables_save <"${RECOVERY_ATTEMPT_DIR}/current-v4.restore" >"${RECOVERY_ATTEMPT_DIR}/target-v4.restore"
        filter_inactive_ufw_iptables_save <"${RECOVERY_ATTEMPT_DIR}/current-v6.restore" >"${RECOVERY_ATTEMPT_DIR}/target-v6.restore"
    fi
    iptables-restore --wait 5 --test <"${RECOVERY_ATTEMPT_DIR}/target-v4.restore" || die 'Candidate IPv4 recovery image failed validation'
    ip6tables-restore --wait 5 --test <"${RECOVERY_ATTEMPT_DIR}/target-v6.restore" || die 'Candidate IPv6 recovery image failed validation'

    {
        printf 'container_present=%s\n' "$RECOVERY_INITIAL_CONTAINER_PRESENT"
        printf 'container_running=%s\n' "$RECOVERY_INITIAL_CONTAINER_RUNNING"
        printf 'current_host_firewall_hash=%s\n' "$(compute_effective_firewall_hash)"
    } >"${RECOVERY_ATTEMPT_DIR}/attempt-metadata"
    find "$RECOVERY_ATTEMPT_DIR" -type f -exec chmod 0600 {} +
    find "$RECOVERY_ATTEMPT_DIR" -type f ! -name attempt.sha256 -print0 | sort -z | \
        xargs -0 sha256sum >"${RECOVERY_ATTEMPT_DIR}/attempt.sha256"
    chmod 0600 "${RECOVERY_ATTEMPT_DIR}/attempt.sha256"
    sha256sum --check --status "${RECOVERY_ATTEMPT_DIR}/attempt.sha256" || die 'Recovery-attempt snapshot failed verification'
    sync -f "$RECOVERY_ATTEMPT_DIR"
}

stop_failed_fresh_container() {
    if ! docker inspect remnanode >/dev/null 2>&1; then
        return 0
    fi
    [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || return 1
    docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" down >/dev/null
    ! docker inspect remnanode >/dev/null 2>&1
}

restore_source_ufw_files() {
    restore_captured_paths "${BACKUP_DIR}/ufw-files.manifest" "${BACKUP_DIR}/ufw-files"
}

restore_source_managed_files() {
    restore_captured_paths "${BACKUP_DIR}/managed-files.manifest" "$BACKUP_DIR"
}

verify_recovered_source_state() {
    [[ "$(LC_ALL=C ufw status | head -n 1)" == 'Status: inactive' ]] || return 1
    [[ "$(compute_ufw_policy_hash)" == "$SNAPSHOT_UFW_POLICY_HASH" ]] || return 1
    [[ "$(compute_effective_firewall_hash)" == "$SNAPSHOT_EFFECTIVE_FIREWALL_HASH" ]] || return 1
    verify_live_ufw_snapshot || return 1
    verify_live_managed_snapshot || return 1
    ! docker inspect remnanode >/dev/null 2>&1 || return 1
    ! has_listener tcp "$NODE_PORT" || return 1
    ! has_listener udp "$HY2_PORT" || return 1
}

restore_recovery_attempt() {
    [[ -n "$RECOVERY_ATTEMPT_DIR" && -d "$RECOVERY_ATTEMPT_DIR" && ! -L "$RECOVERY_ATTEMPT_DIR" ]] || return 1
    sha256sum --check --status "${RECOVERY_ATTEMPT_DIR}/attempt.sha256" || return 1

    if docker inspect remnanode >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]]; then
        docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" down >/dev/null 2>&1 || return 1
    fi
    restore_captured_paths "${RECOVERY_ATTEMPT_DIR}/managed.manifest" "${RECOVERY_ATTEMPT_DIR}/managed" || return 1
    restore_captured_paths "${RECOVERY_ATTEMPT_DIR}/ufw.manifest" "${RECOVERY_ATTEMPT_DIR}/ufw" || return 1
    iptables-restore --wait 5 <"${RECOVERY_ATTEMPT_DIR}/current-v4.restore" || return 1
    ip6tables-restore --wait 5 <"${RECOVERY_ATTEMPT_DIR}/current-v6.restore" || return 1
    cp -a -- "${RECOVERY_ATTEMPT_DIR}/transaction.state" "${BACKUP_DIR}/transaction.state" || return 1
    chmod 0600 "${BACKUP_DIR}/transaction.state"

    if (( RECOVERY_INITIAL_CONTAINER_PRESENT == 1 )); then
        [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || return 1
        if (( RECOVERY_INITIAL_CONTAINER_RUNNING == 1 )); then
            docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || return 1
        else
            docker compose --project-directory "$INSTALL_DIR" -f "$COMPOSE_FILE" up --no-start >/dev/null 2>&1 || return 1
        fi
    elif docker inspect remnanode >/dev/null 2>&1; then
        return 1
    fi
    local expected_host_hash
    expected_host_hash="$(read_setting current_host_firewall_hash "${RECOVERY_ATTEMPT_DIR}/attempt-metadata")"
    [[ "$expected_host_hash" =~ ^[a-f0-9]{64}$ && \
        "$(compute_effective_firewall_hash)" == "$expected_host_hash" ]] || return 1
    sync -f "$INSTALL_DIR"
}

recovery_on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 && RECOVERY_SUCCESS == 0 && RECOVERY_MUTATIONS_STARTED == 1 )); then
        warn 'Recovery failed; restoring the exact pre-recovery attempt state'
        if restore_recovery_attempt; then
            warn "Pre-recovery state restored; unresolved marker retained. Evidence: ${RECOVERY_ATTEMPT_DIR}"
        else
            warn "Pre-recovery state could not be proven; preserve ${RECOVERY_ATTEMPT_DIR} and keep the node stopped"
            rc="$ROLLBACK_FAILURE_EXIT"
        fi
    fi
    exit "$rc"
}

recovery_main() {
    parse_recovery_args "$@"
    require_root_and_tty
    acquire_installer_lock
    detect_platform
    require_recovery_runtime
    select_recovery_backup
    load_and_verify_legacy_transaction

    if [[ -f "$BOOTSTRAP_CONFIG" && ! -L "$BOOTSTRAP_CONFIG" ]]; then
        NODE_PORT="$(read_setting NODE_PORT "$BOOTSTRAP_CONFIG")"
        HY2_PORT="$(read_setting HY2_PORT "$BOOTSTRAP_CONFIG")"
    fi
    validate_port "$NODE_PORT" || die 'Failed transaction contains an invalid Node port'
    validate_port "$HY2_PORT" || die 'Failed transaction contains an invalid Hysteria2 port'

    printf '\nRecovery plan\n'
    printf '  Transaction:       %s\n' "$BACKUP_DIR"
    printf '  Previous UFW:      inactive\n'
    printf '  Previous node:     absent\n'
    printf '  Action:            remove only failed managed files/container and restore the verified firewall baseline\n'
    printf '  Failure behavior:  restore the pre-recovery attempt and retain the unresolved marker\n'
    printf '\nType RECOVER to execute this plan: ' >/dev/tty
    local confirmation=''
    read -r confirmation </dev/tty
    [[ "$confirmation" == 'RECOVER' ]] || die 'Recovery cancelled; no changes were made'

    create_recovery_attempt
    RECOVERY_MUTATIONS_STARTED=1
    stop_failed_fresh_container || die 'Unable to remove the stopped failed-install container safely'
    restore_source_ufw_files || die 'Unable to restore transaction UFW files'
    iptables-restore --wait 5 <"${RECOVERY_ATTEMPT_DIR}/target-v4.restore" || die 'Unable to apply the recovered IPv4 firewall image'
    ip6tables-restore --wait 5 <"${RECOVERY_ATTEMPT_DIR}/target-v6.restore" || die 'Unable to apply the recovered IPv6 firewall image'
    restore_source_managed_files || die 'Unable to restore the original managed-file state'
    verify_recovered_source_state || die 'Recovered state does not match the transaction baseline'
    write_transaction_state ROLLED_BACK || die 'Recovered state is correct but the completion marker could not be written'
    sync -f "$INSTALL_DIR"

    RECOVERY_SUCCESS=1
    ok 'Unresolved transaction reconciled and marked ROLLED_BACK'
    info "Recovery evidence: ${RECOVERY_ATTEMPT_DIR}"
    printf 'You may now rerun the fixed installer.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap recovery_on_exit EXIT
    recovery_main "$@"
fi
