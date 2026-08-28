#!/usr/bin/env python3
from __future__ import annotations

import base64
import ipaddress
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {"", ".md", ".sh", ".yml", ".yaml", ".toml", ".py"}
BASE64_CANDIDATE = re.compile(r"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{160,}(?![A-Za-z0-9+/_=-])")
IPV4_CANDIDATE = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
PUBLIC_DOMAIN_CANDIDATE = re.compile(
    r"(?i)(?<![A-Za-z0-9-])(?:[A-Za-z0-9-]+\.)+(?:com|org|net|io|dev|tech|xyz|test)"
    r"(?![A-Za-z0-9-])"
)
ALLOWED_GLOBAL_IPV4 = {"1.1.1.1", "1.2.3.4"}
ALLOWED_PUBLIC_DOMAINS = {
    "containerd.io",
    "download.docker.com",
    "example.test",
    "github.com",
}
NODE_SECRET_FIELDS = {
    "nodeCertPem",
    "nodeKeyPem",
    "caCertPem",
    "jwtPublicKey",
}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def repository_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for path in ROOT.rglob("*"):
        relative_parts = path.relative_to(ROOT).parts
        if not path.is_file() or ".git" in relative_parts or ".local" in relative_parts:
            continue
        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        files.append(path)
    return sorted(files)


def decode_candidate(value: str) -> bytes | None:
    normalized = value.replace("-", "+").replace("_", "/")
    normalized += "=" * (-len(normalized) % 4)
    try:
        return base64.b64decode(normalized, validate=True)
    except (ValueError, base64.binascii.Error):
        return None


def contains_encoded_node_secret(text: str) -> bool:
    for match in BASE64_CANDIDATE.finditer(text):
        decoded = decode_candidate(match.group(0))
        if decoded is None or len(decoded) > 2_000_000:
            continue
        try:
            parsed = json.loads(decoded)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(parsed, dict) and NODE_SECRET_FIELDS.issubset(parsed):
            return True
    return False


def scan_repository() -> None:
    forbidden_patterns = {
        "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        "proxy credential URI": re.compile(
            r"(?:hysteria2|hy2|vless|trojan|ss)://[^\s`\"']+", re.IGNORECASE
        ),
        "populated node secret": re.compile(
            r"SECRET_KEY\s*=\s*[A-Za-z0-9+/=_-]{128,}"
        ),
        "tokenized subscription URL": re.compile(
            r"https?://(?:sub\.[A-Za-z0-9.-]+/[A-Za-z0-9_-]{16,}|"
            r"[A-Za-z0-9.-]+/api/sub/[A-Za-z0-9_-]{16,})(?:/json)?"
        ),
        "curl piped to shell": re.compile(
            r"curl[^\n|]*\|\s*(?:sudo\s+)?(?:ba)?sh", re.IGNORECASE
        ),
    }
    for path in repository_files():
        text = path.read_text(encoding="utf-8")
        for name, pattern in forbidden_patterns.items():
            if pattern.search(text):
                fail(f"forbidden {name} found in {path.relative_to(ROOT)}")
        for match in IPV4_CANDIDATE.finditer(text):
            try:
                address = ipaddress.ip_address(match.group(0))
            except ValueError:
                continue
            if address.is_global and str(address) not in ALLOWED_GLOBAL_IPV4:
                fail(f"unexpected public IPv4 found in {path.relative_to(ROOT)}")
        for match in PUBLIC_DOMAIN_CANDIDATE.finditer(text):
            domain = match.group(0).lower()
            if domain not in ALLOWED_PUBLIC_DOMAINS and not domain.endswith(".example.test"):
                fail(f"unexpected public domain found in {path.relative_to(ROOT)}")
        if contains_encoded_node_secret(text):
            fail(f"encoded Remnawave node secret found in {path.relative_to(ROOT)}")


def test_detectors() -> None:
    config_text = (ROOT / ".gitleaks.toml").read_text(encoding="utf-8")
    token_rule = re.search(
        r'id\s*=\s*"tokenized-subscription-url".*?regex\s*=\s*\'\'\'(.*?)\'\'\'',
        config_text,
        re.DOTALL,
    )
    if token_rule is None:
        fail("tokenized-subscription-url Gitleaks rule is missing")
    token_pattern = re.compile(token_rule.group(1))
    clone_url = "https://github.com/Andrey-Panin/remnawave-node-bootstrap.git"
    fake_subscription = "https://" + "sub.example.test/" + "abcdefghijklmnop"
    if token_pattern.search(clone_url):
        fail("subscription-token rule incorrectly matches the public clone URL")
    if not token_pattern.search(fake_subscription):
        fail("subscription-token rule misses a representative bearer URL")

    fake_payload = {
        "node" + "CertPem": "fixture-cert",
        "node" + "KeyPem": "fixture-key",
        "ca" + "CertPem": "fixture-ca",
        "jwt" + "PublicKey": "fixture-jwt",
    }
    encoded = base64.b64encode(json.dumps(fake_payload).encode()).decode()
    if not contains_encoded_node_secret(encoded):
        fail("base64 node-secret detector misses its positive fixture")
    if contains_encoded_node_secret(base64.b64encode(b"ordinary fixture").decode()):
        fail("base64 node-secret detector rejects an ordinary value")


def test_invariants() -> None:
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")
    recovery = (ROOT / "recover.sh").read_text(encoding="utf-8")
    status = (ROOT / "status.sh").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    required_installer_fragments = [
        "read -r -s",
        "chmod 0600",
        "remnawave/node:3.3.2@sha256:",
        "--external-firewall",
        "write_transaction_state APPLYING",
        "ROLLBACK_INCOMPLETE",
        "listener_owned_by_remnanode udp",
        "primary_fingerprints",
        "docker compose",
        "trap on_exit EXIT",
        "filter_managed_node_nft_tables",
        "matches_recovered_fresh_firewall_baseline",
        "firewall-restore-v4.txt",
        "write_firewall_evidence after-node",
    ]
    for fragment in required_installer_fragments:
        if fragment not in installer:
            fail(f"installer invariant missing: {fragment}")
    docker_service_helper = re.search(
        r"ensure_docker_service\(\)\s*\{(?P<body>.*?)\n\}", installer, re.DOTALL
    )
    if docker_service_helper is None:
        fail("Docker service startup helper is missing")
    docker_service_body = docker_service_helper.group("body")
    socket_start = docker_service_body.find("systemctl enable --now docker.socket")
    service_start = docker_service_body.find("systemctl enable --now docker.service")
    if socket_start < 0 or service_start < 0 or socket_start > service_start:
        fail("docker.socket must start before docker.service")
    if installer.count("ensure_docker_service") != 3:
        fail("both Docker installation paths must use the service startup helper")
    rollback_helper = re.search(
        r"rollback\(\)\s*\{(?P<body>.*?)\n\}", installer, re.DOTALL
    )
    if rollback_helper is None:
        fail("rollback helper is missing")
    rollback_body = rollback_helper.group("body")
    stop_position = rollback_body.find("stop_current_managed_container")
    firewall_position = rollback_body.find("restore_firewall_snapshot")
    if stop_position < 0 or firewall_position < 0 or stop_position > firewall_position:
        fail("rollback must stop the NET_ADMIN container before restoring firewall state")
    required_recovery_fragments = [
        "Type RECOVER",
        "ROLLBACK_INCOMPLETE",
        "filter_inactive_ufw_iptables_save",
        "sha256sum --check --status",
        "restore_recovery_attempt",
        "verify_recovered_source_state",
    ]
    for fragment in required_recovery_fragments:
        if fragment not in recovery:
            fail(f"recovery invariant missing: {fragment}")
    required_status_fragments = [
        "listener_owned_by_remnanode udp",
        "compute_ufw_policy_hash",
        "exit 1",
    ]
    for fragment in required_status_fragments:
        if fragment not in status:
            fail(f"status invariant missing: {fragment}")
    required_workflow_fragments = [
        "persist-credentials: false",
        "ubuntu:22.04@sha256:",
        "ubuntu:24.04@sha256:",
        "proxy_canary_rc=$?",
        "if (( proxy_canary_rc != 1 )); then",
        "decoded_canary_rc=$?",
        "if (( decoded_canary_rc != 1 )); then",
        "--max-decode-depth 1",
    ]
    for fragment in required_workflow_fragments:
        if fragment not in workflow:
            fail(f"workflow invariant missing: {fragment}")
    for image in ("ubuntu:24.04", "ubuntu:22.04"):
        if not re.search(rf"{re.escape(image)}@sha256:[0-9a-f]{{64}}", workflow):
            fail(f"smoke image is not pinned by OCI digest: {image}")
    if "debian:12" in workflow or "Debian 12" in readme:
        fail("Debian remains in the Ubuntu-only public support contract")
    required_readme_fragments = [
        "https://github.com/Andrey-Panin/remnawave-node-bootstrap.git",
        "cd remnawave-node-bootstrap",
        "sudo bash recover.sh",
    ]
    for fragment in required_readme_fragments:
        if fragment not in readme:
            fail(f"README invariant missing: {fragment}")
    if "Andrey-Panin/relay.git" in readme or "cd relay" in readme:
        fail("README still references the unrelated relay repository")


def test_shell_syntax() -> None:
    bash = os.environ.get("BASH") or shutil.which("bash")
    if not bash:
        fail("bash executable not found")
    subprocess.run(
        [bash, "-n", "install.sh", "recover.sh", "status.sh", "tests/test_functions.sh"],
        cwd=ROOT,
        check=True,
    )


def main() -> None:
    scan_repository()
    test_detectors()
    test_invariants()
    test_shell_syntax()
    print("static checks: PASS")


if __name__ == "__main__":
    main()
