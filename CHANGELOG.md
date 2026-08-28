# Changelog

## 1.0.6 — 2026-08-28

- Exclude only the upstream-owned dynamic nftables tables `ip remnanode` and
  `ip6 remnanode6` from the host-firewall drift hash.
- Stop the NET_ADMIN container before restoring or verifying firewall state.
- Save verified IPv4/IPv6 restore images and before/after firewall evidence in
  every managed transaction backup.
- Restore exact runtime firewall images instead of relying on `ufw disable` to
  remove its inactive chain scaffolding.
- Add `recover.sh` for fail-closed reconciliation of a failed fresh-install
  transaction from bootstrap 1.0.5/1.0.6.

## 1.0.5 — 2026-08-26

- Start and enable `docker.socket` before `docker.service`, preventing the
  `no sockets found via socket activation` failure on fresh Ubuntu VPS hosts.

## 1.0.4 — 2026-08-26

- Exclude live iptables packet/byte counters from the effective-firewall drift
  hash while continuing to detect every policy and rule change.

## 1.0.3 — 2026-08-25

- Do not upgrade installed OS, firewall, or Docker packages before the
  transactional backup on a managed reconfiguration.
- Remove inherited Docker platform/API overrides before using the pinned image.

## 1.0.2 — 2026-08-25

- Explicitly remove an inherited `SECRET_KEY` export attribute before prompting,
  preventing the real node secret from reaching child processes.

## 1.0.1 — 2026-08-25

- Bind the UFW rollback snapshot to the exact backed-up file metadata.
- Keep the node stopped when firewall rollback cannot be proven complete.
- Add filesystem durability barriers for UFW state.
- Reject any pre-existing raw firewall rules on a fresh managed VPS.

## 1.0.0 — 2026-08-25

- first public Remnawave Node bootstrap release;
- pinned Remnawave Node 3.3.2 OCI image for amd64/arm64;
- transactional backup, rollback, and crash-recovery markers;
- Panel-only Node API policy with managed UFW or explicit external firewall;
- owner-aware TCP/UDP health checks;
- full-history and decoded-secret CI scanning.
