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
        docker ufw nft python3 sha256sum find sort xargs readlink stat cmp sync unshare \
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

    [[ "$RECOVERY_SOURCE_VERSION" == '1.0.5' || "$RECOVERY_SOURCE_VERSION" == '1.0.6' || \
        "$RECOVERY_SOURCE_VERSION" == '1.0.7' || "$RECOVERY_SOURCE_VERSION" == '1.0.8' ]] || \
        die "Recovery supports transaction versions 1.0.5-1.0.8; got ${RECOVERY_SOURCE_VERSION:-missing}"
    [[ "$had_install" == '0' && "$previous_present" == '0' && "$previous_running" == '0' ]] || \
        die 'This recovery tool intentionally supports only a failed fresh install with no previous node'
    [[ "$UFW_PREVIOUS_ACTIVE" == '0' ]] || die 'The failed fresh install did not start from inactive UFW'
    [[ "$SNAPSHOT_UFW_POLICY_HASH" =~ ^[a-f0-9]{64}$ && "$SNAPSHOT_EFFECTIVE_FIREWALL_HASH" =~ ^[a-f0-9]{64}$ ]] || \
        die 'Transaction firewall hashes are missing or invalid'

    SNAPSHOT_MANAGED_MANIFEST_HASH="$(sha256sum -- "${BACKUP_DIR}/managed-files.manifest" | awk '{print $1}')"
    SNAPSHOT_UFW_MANIFEST_HASH="$(sha256sum -- "${BACKUP_DIR}/ufw-files.manifest" | awk '{print $1}')"
    verify_managed_backup_integrity || die 'Managed-file backup integrity verification failed'
    verify_ufw_backup_integrity || die 'UFW-file backup integrity verification failed'
    local backup_ufw_hash
    backup_ufw_hash="$(compute_ufw_backup_policy_hash)" || \
        die 'Unable to hash the protected UFW backup policy'
    [[ "$backup_ufw_hash" == "$SNAPSHOT_UFW_POLICY_HASH" ]] || \
        die 'UFW backup policy does not match transaction metadata'
    if [[ "$RECOVERY_SOURCE_VERSION" == '1.0.6' || "$RECOVERY_SOURCE_VERSION" == '1.0.7' || \
        "$RECOVERY_SOURCE_VERSION" == '1.0.8' ]]; then
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
    local stamp current_effective current_v4 current_v6 current_native
    local target_v4 target_v6 target_native expected_current_native
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    RECOVERY_ATTEMPT_DIR="$(mktemp -d "${BACKUP_DIR}/recovery-attempt-${stamp}.XXXXXX")"
    chmod 0700 "$RECOVERY_ATTEMPT_DIR"

    local recovered_baseline="${BACKUP_DIR}/${RECOVERED_FIREWALL_BASELINE_NAME}"
    local -a managed_paths=("$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_CONFIG" "$recovered_baseline")
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

    if [[ "$RECOVERY_SOURCE_VERSION" == '1.0.6' || "$RECOVERY_SOURCE_VERSION" == '1.0.7' || \
        "$RECOVERY_SOURCE_VERSION" == '1.0.8' ]]; then
        cp -a -- "${BACKUP_DIR}/firewall-restore-v4.txt" "${RECOVERY_ATTEMPT_DIR}/target-v4.restore"
        cp -a -- "${BACKUP_DIR}/firewall-restore-v6.txt" "${RECOVERY_ATTEMPT_DIR}/target-v6.restore"
    else
        filter_inactive_ufw_iptables_save <"${RECOVERY_ATTEMPT_DIR}/current-v4.restore" | \
            normalize_v105_builtin_policies >"${RECOVERY_ATTEMPT_DIR}/target-v4.restore"
        filter_inactive_ufw_iptables_save <"${RECOVERY_ATTEMPT_DIR}/current-v6.restore" | \
            normalize_v105_builtin_policies >"${RECOVERY_ATTEMPT_DIR}/target-v6.restore"
    fi
    iptables-restore --wait 5 --test <"${RECOVERY_ATTEMPT_DIR}/target-v4.restore" || die 'Candidate IPv4 recovery image failed validation'
    ip6tables-restore --wait 5 --test <"${RECOVERY_ATTEMPT_DIR}/target-v6.restore" || die 'Candidate IPv6 recovery image failed validation'
    assert_initial_recovery_runtime_provable || \
        die 'Recovery requires either an empty Docker inventory or exactly one verified stopped remnanode, plus pristine secondary legacy firewall backends'

    current_effective="$(compute_effective_firewall_hash)" || die 'Unable to hash the pre-recovery firewall policy'
    current_v4="$(normalized_iptables_restore_hash "${RECOVERY_ATTEMPT_DIR}/current-v4.restore")" || \
        die 'Unable to hash the pre-recovery IPv4 image'
    current_v6="$(normalized_iptables_restore_hash "${RECOVERY_ATTEMPT_DIR}/current-v6.restore")" || \
        die 'Unable to hash the pre-recovery IPv6 image'
    current_native="$(compute_native_nft_policy_hash)" || die 'Unable to hash the pre-recovery native nftables policy'
    expected_current_native="$(compute_isolated_native_hash \
        "${RECOVERY_ATTEMPT_DIR}/current-v4.restore" \
        "${RECOVERY_ATTEMPT_DIR}/current-v6.restore")" || \
        die 'Unable to reconstruct the current firewall in an isolated network namespace'
    [[ "$current_native" == "$expected_current_native" ]] || \
        die 'Current native nftables policy contains state that the recovery images cannot reproduce'
    target_v4="$(normalized_iptables_restore_hash "${RECOVERY_ATTEMPT_DIR}/target-v4.restore")" || \
        die 'Unable to hash the target IPv4 recovery image'
    target_v6="$(normalized_iptables_restore_hash "${RECOVERY_ATTEMPT_DIR}/target-v6.restore")" || \
        die 'Unable to hash the target IPv6 recovery image'
    if [[ "$RECOVERY_SOURCE_VERSION" == '1.0.5' ]]; then
        assert_v105_docker_only_restore_image "${RECOVERY_ATTEMPT_DIR}/target-v4.restore" ipv4 || \
            die 'v1.0.5 IPv4 recovery target is not a pristine or exact empty-Docker policy'
        assert_v105_docker_only_restore_image "${RECOVERY_ATTEMPT_DIR}/target-v6.restore" ipv6 || \
            die 'v1.0.5 IPv6 recovery target is not a pristine or exact empty-Docker policy'
        target_native="$(compute_isolated_native_hash \
            "${RECOVERY_ATTEMPT_DIR}/target-v4.restore" \
            "${RECOVERY_ATTEMPT_DIR}/target-v6.restore")" || \
            die 'Unable to prove the v1.0.5 target in an isolated network namespace'
    else
        target_native="$(native_nft_policy_hash_from_raw_evidence "${BACKUP_DIR}/firewall-raw-before.txt")" || \
            die 'Unable to derive native nftables policy from the protected transaction evidence'
    fi
    [[ "$current_effective" =~ ^[a-f0-9]{64}$ && "$current_v4" =~ ^[a-f0-9]{64}$ && \
        "$current_v6" =~ ^[a-f0-9]{64}$ && "$current_native" =~ ^[a-f0-9]{64}$ && \
        "$target_v4" =~ ^[a-f0-9]{64}$ && "$target_v6" =~ ^[a-f0-9]{64}$ && \
        "$target_native" =~ ^[a-f0-9]{64}$ ]] || \
        die 'A recovery policy hash is malformed'

    {
        printf 'container_present=%s\n' "$RECOVERY_INITIAL_CONTAINER_PRESENT"
        printf 'container_running=%s\n' "$RECOVERY_INITIAL_CONTAINER_RUNNING"
        printf 'current_host_firewall_hash=%s\n' "$current_effective"
        printf 'current_ipv4_policy_hash=%s\n' "$current_v4"
        printf 'current_ipv6_policy_hash=%s\n' "$current_v6"
        printf 'current_native_nft_policy_hash=%s\n' "$current_native"
        printf 'target_ipv4_policy_hash=%s\n' "$target_v4"
        printf 'target_ipv6_policy_hash=%s\n' "$target_v6"
        printf 'target_native_nft_policy_hash=%s\n' "$target_native"
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

assert_v105_docker_only_restore_image() {
    local restore_file="$1"
    local docker_scaffold_family="$2"
    [[ -f "$restore_file" && ! -L "$restore_file" ]] || return 1
    [[ "$docker_scaffold_family" == 'none' || \
       "$docker_scaffold_family" == 'ipv4' || \
       "$docker_scaffold_family" == 'ipv6' ]] || return 2
    python3 -I -c '
import re
import sys

path, docker_family = sys.argv[1:3]
builtins = {
    "filter": {"INPUT", "FORWARD", "OUTPUT"},
    "nat": {"PREROUTING", "INPUT", "OUTPUT", "POSTROUTING"},
    "mangle": {"PREROUTING", "INPUT", "FORWARD", "OUTPUT", "POSTROUTING"},
    "raw": {"PREROUTING", "OUTPUT"},
    "security": {"INPUT", "FORWARD", "OUTPUT"},
}
docker_filter_chains = {
    "DOCKER", "DOCKER-BRIDGE", "DOCKER-CT", "DOCKER-FORWARD",
    "DOCKER-INTERNAL", "DOCKER-USER",
}
docker_filter_rules_ipv4 = {
    "FORWARD": [
        "-A FORWARD -j DOCKER-USER",
        "-A FORWARD -j DOCKER-FORWARD",
    ],
    "DOCKER": ["-A DOCKER ! -i docker0 -o docker0 -j DROP"],
    "DOCKER-BRIDGE": ["-A DOCKER-BRIDGE -o docker0 -j DOCKER"],
    "DOCKER-CT": [
        "-A DOCKER-CT -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    ],
    "DOCKER-FORWARD": [
        "-A DOCKER-FORWARD -j DOCKER-CT",
        "-A DOCKER-FORWARD -j DOCKER-INTERNAL",
        "-A DOCKER-FORWARD -j DOCKER-BRIDGE",
        "-A DOCKER-FORWARD -i docker0 -j ACCEPT",
    ],
}
docker_nat_rules_ipv4 = {
    "PREROUTING": ["-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER"],
    "OUTPUT": ["-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER"],
    "POSTROUTING": [
        "-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE"
    ],
}
docker_filter_rules_ipv6 = {
    "FORWARD": [
        "-A FORWARD -j DOCKER-USER",
        "-A FORWARD -j DOCKER-FORWARD",
    ],
    "DOCKER-FORWARD": [
        "-A DOCKER-FORWARD -j DOCKER-CT",
        "-A DOCKER-FORWARD -j DOCKER-INTERNAL",
        "-A DOCKER-FORWARD -j DOCKER-BRIDGE",
    ],
}
docker_nat_rules_ipv6 = {
    "PREROUTING": ["-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER"],
    "OUTPUT": ["-A OUTPUT ! -d ::1/128 -m addrtype --dst-type LOCAL -j DOCKER"],
}

tables = {}
current = None
for raw in open(path, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("*"):
        current = line[1:]
        if current not in builtins or current in tables:
            raise SystemExit(2)
        tables[current] = {"chains": {}, "rules": {}}
        continue
    if line == "COMMIT":
        if current is None:
            raise SystemExit(2)
        current = None
        continue
    if current is None:
        raise SystemExit(2)
    chain = re.fullmatch(r":(\S+)\s+(\S+)\s+\[[0-9]+:[0-9]+\]", line)
    if chain:
        name, policy = chain.groups()
        if name in tables[current]["chains"]:
            raise SystemExit(2)
        tables[current]["chains"][name] = policy
    elif line.startswith("-A "):
        rule = re.match(r"-A\s+(\S+)\s+", line)
        if not rule:
            raise SystemExit(2)
        tables[current]["rules"].setdefault(rule.group(1), []).append(line)
    else:
        raise SystemExit(2)
if current is not None:
    raise SystemExit(2)

for table, data in tables.items():
    chains = data["chains"]
    rules = data["rules"]
    if not builtins[table].issubset(chains):
        raise SystemExit(2)
    custom = set(chains) - builtins[table]
    if not custom and not rules:
        if any(chains[name] != "ACCEPT" for name in builtins[table]):
            raise SystemExit(2)
        continue
    if docker_family == "none":
        raise SystemExit(2)
    expected_filter_rules = (
        docker_filter_rules_ipv4 if docker_family == "ipv4"
        else docker_filter_rules_ipv6
    )
    expected_nat_rules = (
        docker_nat_rules_ipv4 if docker_family == "ipv4"
        else docker_nat_rules_ipv6
    )
    if table == "filter" and custom == docker_filter_chains and rules == expected_filter_rules:
        if chains["INPUT"] != "ACCEPT" or chains["OUTPUT"] != "ACCEPT":
            raise SystemExit(2)
        if chains["FORWARD"] not in {"ACCEPT", "DROP"}:
            raise SystemExit(2)
        continue
    if table == "nat" and custom == {"DOCKER"} and rules == expected_nat_rules:
        if any(chains[name] != "ACCEPT" for name in builtins[table]):
            raise SystemExit(2)
        continue
    raise SystemExit(2)
' "$restore_file" "$docker_scaffold_family"
}

assert_pristine_secondary_legacy_backends() {
    local command_name proc_file temporary
    local -a pairs=(
        'iptables:iptables-legacy-save:/proc/net/ip_tables_names'
        'ip6tables:ip6tables-legacy-save:/proc/net/ip6_tables_names'
    )
    local pair frontend
    for pair in "${pairs[@]}"; do
        IFS=: read -r frontend command_name proc_file <<<"$pair"
        iptables_frontend_uses_nf_tables "$frontend" || continue
        [[ -s "$proc_file" ]] || continue
        command -v "$command_name" >/dev/null 2>&1 || return 1
        temporary="$(mktemp)" || return 1
        if ! "$command_name" >"$temporary" || \
            ! assert_v105_docker_only_restore_image "$temporary" none; then
            rm -f -- "$temporary"
            return 1
        fi
        rm -f -- "$temporary" || return 1
    done
}

assert_verified_stopped_remnanode_only() {
    local inventory image working_dir count name
    inventory="$(docker_inventory_snapshot)" || return 1
    count="$(awk 'NF {count += 1} END {print count + 0}' <<<"$inventory")" || return 1
    name="$(awk -F '\t' 'NF {print $2}' <<<"$inventory")" || return 1
    [[ "$count" == '1' && "$name" == 'remnanode' ]] || return 1
    docker inspect remnanode >/dev/null 2>&1 || return 1
    [[ "$(docker inspect --format '{{.State.Running}}' remnanode 2>/dev/null)" == 'false' ]] || return 1
    image="$(docker inspect --format '{{.Config.Image}}' remnanode 2>/dev/null)" || return 1
    working_dir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' remnanode 2>/dev/null)" || return 1
    [[ "$image" == "$NODE_IMAGE" && "$working_dir" == "$INSTALL_DIR" ]]
}

assert_initial_recovery_runtime_provable() {
    if (( RECOVERY_INITIAL_CONTAINER_PRESENT == 1 )); then
        (( RECOVERY_INITIAL_CONTAINER_RUNNING == 0 )) || return 1
        assert_verified_stopped_remnanode_only || return 1
    else
        local inventory
        inventory="$(docker_inventory_snapshot)" || return 1
        [[ -z "$inventory" ]] || return 1
    fi
    assert_pristine_secondary_legacy_backends
}

assert_recovery_runtime_provable() {
    local inventory
    inventory="$(docker_inventory_snapshot)" || return 1
    [[ -z "$inventory" ]] || return 1
    assert_pristine_secondary_legacy_backends
}

assert_rollback_runtime_provable() {
    if (( RECOVERY_INITIAL_CONTAINER_PRESENT == 1 )); then
        assert_verified_stopped_remnanode_only || return 1
    else
        local inventory
        inventory="$(docker_inventory_snapshot)" || return 1
        [[ -z "$inventory" ]] || return 1
    fi
    assert_pristine_secondary_legacy_backends
}

compute_isolated_native_hash() {
    local target_v4="$1"
    local target_v6="$2"
    [[ -f "$target_v4" && ! -L "$target_v4" && \
        -f "$target_v6" && ! -L "$target_v6" ]] || return 1

    # Build the only acceptable native representation from the supplied
    # restore images in a disposable network namespace. This also proves that
    # a current ruleset is completely reproducible before recovery mutates it.
    # Positional parameters expand intentionally in the child bash.
    # shellcheck disable=SC2016
    unshare --net -- bash -c '
        set -Eeuo pipefail
        set +x
        source "$1"
        iptables-restore --wait 5 <"$2"
        ip6tables-restore --wait 5 <"$3"
        compute_native_nft_policy_hash
    ' bash "${SCRIPT_DIR}/install.sh" "$target_v4" "$target_v6"
}

verify_recovered_source_state() {
    local expected_native actual_native inventory actual_ufw
    expected_native="$(read_setting target_native_nft_policy_hash "${RECOVERY_ATTEMPT_DIR}/attempt-metadata")" || return 1
    [[ "$(LC_ALL=C ufw status | head -n 1)" == 'Status: inactive' ]] || return 1
    actual_ufw="$(compute_ufw_policy_hash)" || return 1
    [[ "$actual_ufw" == "$SNAPSHOT_UFW_POLICY_HASH" ]] || return 1
    iptables_restore_image_matches_live "${RECOVERY_ATTEMPT_DIR}/target-v4.restore" iptables-save || return 1
    iptables_restore_image_matches_live "${RECOVERY_ATTEMPT_DIR}/target-v6.restore" ip6tables-save || return 1
    actual_native="$(compute_native_nft_policy_hash)" || return 1
    [[ "$expected_native" =~ ^[a-f0-9]{64}$ && "$actual_native" == "$expected_native" ]] || return 1
    assert_recovery_runtime_provable || return 1
    verify_live_ufw_snapshot || return 1
    verify_live_managed_snapshot || return 1
    inventory="$(docker_inventory_snapshot)" || return 1
    [[ -z "$inventory" ]] || return 1
    ! docker inspect remnanode >/dev/null 2>&1 || return 1
    ! has_listener tcp "$NODE_PORT" || return 1
    ! has_listener udp "$HY2_PORT" || return 1
}

write_recovered_firewall_baseline() {
    local destination="${BACKUP_DIR}/${RECOVERED_FIREWALL_BASELINE_NAME}"
    local temporary effective final_effective ufw_hash ipv4 ipv6 native
    local expected_ipv4 expected_ipv6 expected_native
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" && \
            "$(stat -c '%u:%g:%a' -- "$destination")" == '0:0:600' ]] || return 1
    fi
    expected_ipv4="$(read_setting target_ipv4_policy_hash "${RECOVERY_ATTEMPT_DIR}/attempt-metadata")" || return 1
    expected_ipv6="$(read_setting target_ipv6_policy_hash "${RECOVERY_ATTEMPT_DIR}/attempt-metadata")" || return 1
    expected_native="$(read_setting target_native_nft_policy_hash "${RECOVERY_ATTEMPT_DIR}/attempt-metadata")" || return 1
    [[ "$expected_ipv4" =~ ^[a-f0-9]{64}$ && "$expected_ipv6" =~ ^[a-f0-9]{64}$ && \
        "$expected_native" =~ ^[a-f0-9]{64}$ ]] || return 1
    verify_recovered_source_state || return 1
    effective="$(compute_effective_firewall_hash)" || return 1
    ufw_hash="$(compute_ufw_policy_hash)" || return 1
    ipv4="$(live_iptables_policy_hash iptables-save)" || return 1
    ipv6="$(live_iptables_policy_hash ip6tables-save)" || return 1
    native="$(compute_native_nft_policy_hash)" || return 1
    [[ "$effective" =~ ^[a-f0-9]{64}$ && "$ufw_hash" =~ ^[a-f0-9]{64}$ && \
        "$ipv4" =~ ^[a-f0-9]{64}$ && "$ipv6" =~ ^[a-f0-9]{64}$ && \
        "$native" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$ufw_hash" == "$SNAPSHOT_UFW_POLICY_HASH" && "$ipv4" == "$expected_ipv4" && \
        "$ipv6" == "$expected_ipv6" ]] || return 1
    [[ "$native" == "$expected_native" ]] || return 1
    temporary="$(mktemp "${BACKUP_DIR}/${RECOVERED_FIREWALL_BASELINE_NAME}.new.XXXXXX")" || return 1
    if ! {
        printf 'schema=2\n'
        printf 'recovery_writer_version=%s\n' "$INSTALLER_VERSION"
        printf 'source_transaction_version=%s\n' "$RECOVERY_SOURCE_VERSION"
        printf 'effective_firewall_hash=%s\n' "$effective"
        printf 'ufw_policy_hash=%s\n' "$ufw_hash"
        printf 'ipv4_policy_hash=%s\n' "$expected_ipv4"
        printf 'ipv6_policy_hash=%s\n' "$expected_ipv6"
        printf 'native_nft_policy_hash=%s\n' "$native"
    } >"$temporary" || ! chmod 0600 "$temporary" || ! sync "$temporary" || \
        ! verify_recovered_source_state; then
        rm -f -- "$temporary"
        return 1
    fi
    final_effective="$(compute_effective_firewall_hash)" || {
        rm -f -- "$temporary"
        return 1
    }
    if [[ "$final_effective" != "$effective" ]] || \
        ! mv -fT -- "$temporary" "$destination" || ! sync "$BACKUP_DIR"; then
        rm -f -- "$temporary"
        return 1
    fi
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
    local expected_native actual_native
    iptables_restore_image_matches_live "${RECOVERY_ATTEMPT_DIR}/current-v4.restore" iptables-save || return 1
    iptables_restore_image_matches_live "${RECOVERY_ATTEMPT_DIR}/current-v6.restore" ip6tables-save || return 1
    expected_native="$(read_setting current_native_nft_policy_hash "${RECOVERY_ATTEMPT_DIR}/attempt-metadata")"
    actual_native="$(compute_native_nft_policy_hash)" || return 1
    [[ "$expected_native" =~ ^[a-f0-9]{64}$ && "$actual_native" == "$expected_native" ]] || return 1
    assert_rollback_runtime_provable || return 1
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
    write_recovered_firewall_baseline || die 'Recovered state is correct but its canonical baseline could not be written'
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
