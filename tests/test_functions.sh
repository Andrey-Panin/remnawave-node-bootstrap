#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PYTHON_BIN="$(command -v python3 || command -v python)"
# shellcheck source=../install.sh
source "${ROOT}/install.sh"

# install.sh intentionally replaces PATH for root safety. Keep the exact test
# interpreter selected before sourcing so these tests also run under Git Bash.
python3() { "$TEST_PYTHON_BIN" "$@"; }

expect_success() {
    "$@" || {
        printf 'expected success: %q\n' "$*" >&2
        exit 1
    }
}

expect_failure() {
    if "$@"; then
        printf 'expected failure: %q\n' "$*" >&2
        exit 1
    fi
}

expect_exit_code() {
    local expected="$1"
    shift
    local actual=0
    set +e
    "$@"
    actual=$?
    set -e
    if (( actual != expected )); then
        printf 'expected exit %s, got %s: %q\n' "$expected" "$actual" "$*" >&2
        exit 1
    fi
}

expect_success validate_ipv4 203.0.113.10
expect_success validate_ipv4 1.1.1.1
expect_failure validate_ipv4 999.1.1.1
expect_failure validate_ipv4 127.0.0
expect_failure validate_ipv4 0.0.0.0
expect_failure validate_ipv4 '1.2.3.4 extra'

expect_success validate_port 1
expect_success validate_port 10443
expect_success validate_port 65535
expect_failure validate_port 0
expect_failure validate_port 65536
expect_failure validate_port abc

tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT
printf 'A=one\nSECRET_KEY=abc=def==\n' >"$tmp"
[[ "$(read_setting A "$tmp")" == "one" ]]
[[ "$(read_setting SECRET_KEY "$tmp")" == "abc=def==" ]]

PANEL_IP=''
NODE_PORT='2222'
HY2_PORT='10443'
PANEL_IP_SET=0
NODE_PORT_SET=0
HY2_PORT_SET=0
FIREWALL_MODE_SET=0
FIREWALL_MODE='ufw'
parse_args --panel-ip 203.0.113.10 --node-port 2222 --hy2-port 10443 --external-firewall
[[ "$PANEL_IP" == '203.0.113.10' && "$PANEL_IP_SET" == 1 ]]
[[ "$NODE_PORT" == '2222' && "$NODE_PORT_SET" == 1 ]]
[[ "$HY2_PORT" == '10443' && "$HY2_PORT_SET" == 1 ]]
[[ "$FIREWALL_MODE" == 'external' && "$FIREWALL_MODE_SET" == 1 ]]

safe_ufw=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n22/tcp  ALLOW IN  Anywhere\n2222/tcp  ALLOW IN  203.0.113.10'
exact_public=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n2222/tcp  ALLOW IN  Anywhere'
range_public=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n2000:3000/tcp  ALLOW IN  Anywhere'
all_public=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\nAnywhere  ALLOW IN  Anywhere'
other_source=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n2222/tcp  ALLOW IN  198.51.100.20'
panel_denied=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n2222/tcp  DENY IN  203.0.113.10'
limited=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n2222/tcp  LIMIT IN  203.0.113.10'
udp_only=$'Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n2222/udp  ALLOW IN  Anywhere\n2222/tcp  ALLOW IN  203.0.113.10'
malformed_rule=$'Status: active\n2222/tcp ALLOW IN broken-spacing'
expect_exit_code 1 find_unsafe_ufw_rule "$safe_ufw" 2222 203.0.113.10
expect_exit_code 0 find_unsafe_ufw_rule "$exact_public" 2222 203.0.113.10
expect_exit_code 0 find_unsafe_ufw_rule "$range_public" 2222 203.0.113.10
expect_exit_code 0 find_unsafe_ufw_rule "$all_public" 2222 203.0.113.10
expect_exit_code 0 find_unsafe_ufw_rule "$other_source" 2222 203.0.113.10
expect_exit_code 0 find_unsafe_ufw_rule "$panel_denied" 2222 203.0.113.10
expect_exit_code 0 find_unsafe_ufw_rule "$limited" 2222 203.0.113.10
expect_exit_code 1 find_unsafe_ufw_rule "$udp_only" 2222 203.0.113.10
expect_exit_code 2 find_unsafe_ufw_rule "$safe_ufw" invalid 203.0.113.10
expect_exit_code 2 find_unsafe_ufw_rule "$malformed_rule" 2222 203.0.113.10

python_failure_probe() {
    (
        # shellcheck disable=SC2329
        python3() { return 127; }
        find_unsafe_ufw_rule "$safe_ufw" 2222 203.0.113.10
    )
}
expect_exit_code 2 python_failure_probe

MOCK_CONTAINER_PIDS='101'
MOCK_LISTENER_LINES=''
MOCK_LISTENER_KEY='udp:10443'
container_pids() { printf '%s\n' "$MOCK_CONTAINER_PIDS"; }
listener_lines() {
    [[ "${1}:${2}" == "$MOCK_LISTENER_KEY" ]] || return 0
    printf '%s\n' "$MOCK_LISTENER_LINES"
}

MOCK_LISTENER_LINES='udp UNCONN 0 0 0.0.0.0:10443 0.0.0.0:* users:(("xray",pid=101,fd=3))'
expect_success listener_owned_by_remnanode udp 10443
MOCK_LISTENER_LINES=$'udp UNCONN 0 0 0.0.0.0:10443 0.0.0.0:* users:(("xray",pid=101,fd=3))\nudp UNCONN 0 0 [::]:10443 [::]:* users:(("xray",pid=101,fd=4))'
expect_success listener_owned_by_remnanode udp 10443
MOCK_LISTENER_LINES='udp UNCONN 0 0 0.0.0.0:10443 0.0.0.0:* users:(("foreign",pid=202,fd=3),("xray",pid=101,fd=4))'
expect_failure listener_owned_by_remnanode udp 10443
MOCK_LISTENER_LINES=$'udp UNCONN 0 0 0.0.0.0:10443 0.0.0.0:* users:(("xray",pid=101,fd=3))\nudp UNCONN 0 0 [::]:10443 [::]:* users:(("foreign",pid=202,fd=4))'
expect_failure listener_owned_by_remnanode udp 10443
MOCK_LISTENER_LINES='udp UNCONN 0 0 0.0.0.0:10443 0.0.0.0:*'
expect_failure listener_owned_by_remnanode udp 10443
MOCK_LISTENER_LINES=''
expect_failure listener_owned_by_remnanode udp 10443
MOCK_CONTAINER_PIDS=''
MOCK_LISTENER_LINES='udp UNCONN 0 0 0.0.0.0:10443 0.0.0.0:* users:(("xray",pid=101,fd=3))'
expect_failure listener_owned_by_remnanode udp 10443

changed_tcp_collision() {
    (
        # These globals are consumed dynamically by sourced installer helpers.
        # shellcheck disable=SC2034
        HAD_MANAGED_INSTALL=1
        # shellcheck disable=SC2034
        PREVIOUS_NODE_PORT=2222
        # shellcheck disable=SC2034
        PREVIOUS_HY2_PORT=10443
        NODE_PORT=3333
        HY2_PORT=10443
        MOCK_CONTAINER_PIDS='101'
        MOCK_LISTENER_KEY='tcp:3333'
        MOCK_LISTENER_LINES='tcp LISTEN 0 128 0.0.0.0:3333 0.0.0.0:* users:(("node",pid=101,fd=3))'
        check_listener_collisions
    )
}
expect_failure changed_tcp_collision

changed_udp_collision() {
    (
        # These globals are consumed dynamically by sourced installer helpers.
        # shellcheck disable=SC2034
        HAD_MANAGED_INSTALL=1
        # shellcheck disable=SC2034
        PREVIOUS_NODE_PORT=2222
        # shellcheck disable=SC2034
        PREVIOUS_HY2_PORT=10443
        NODE_PORT=2222
        HY2_PORT=11443
        MOCK_CONTAINER_PIDS='101'
        MOCK_LISTENER_KEY='udp:11443'
        MOCK_LISTENER_LINES='udp UNCONN 0 0 0.0.0.0:11443 0.0.0.0:* users:(("xray",pid=101,fd=3))'
        check_listener_collisions
    )
}
expect_failure changed_udp_collision

printf 'function tests: PASS\n'
