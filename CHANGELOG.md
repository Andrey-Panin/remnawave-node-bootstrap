# Changelog

## Simple installer 1.0.0 — 2026-08-28

- Add `install-simple.sh` for short-lived VPS nodes.
- Install Docker, write the Remnawave Node files, and start the pinned Node
  image without reading, modifying, verifying, or restoring host firewall
  rules.
- Default to the main Panel `89.110.92.101`, Node API `2222/tcp`, and
  Hysteria2 `10443/udp`; allow overriding all three through explicit options.

## 1.0.9 — 2026-08-28

- Recognize Docker's exact empty IPv6 `filter`/`nat` scaffold separately from
  its IPv4 scaffold while recovering a legacy v1.0.5 transaction.
- Keep IPv4/IPv6 family mismatches, rule changes, inserted rules, and
  order changes fail-closed.

## 1.0.8 — 2026-08-28

- Hash `iptables-nft` policy once through normalized `iptables-save`; retain
  native nftables tables separately so harmless table reordering and empty
  built-in chains created by `iptables-restore` no longer cause false drift.
- Verify recovery against the protected normalized IPv4/IPv6 restore images
  and an independently preserved native-nft policy hash instead of an
  unreproducible legacy textual nftables hash.
- For legacy v1.0.5 transactions, accept only a pristine/known empty-Docker
  restore image and derive its expected native-nft hash in an isolated network
  namespace; foreign containers, secondary legacy rules, and native drift
  remain fail-closed.
- Permit an interrupted install's one verified stopped `remnanode` container
  during pre-recovery capture and prove the corresponding stopped/absent state
  again if recovery itself must roll back.
- Persist a root-only schema-v2 recovered baseline so a failed fresh install
  from v1.0.5-v1.0.8 can be reconciled and safely retried.
- Retain read-only verification compatibility for completed v1.0.6/v1.0.7
  managed installations and migrate them to firewall-hash schema 2 on their
  next successful reconfiguration.

## 1.0.7 — 2026-08-28

- Allow a fresh retry to retain Docker's installed firewall scaffolding only
  when the empty Docker inventory and both live firewall hashes exactly match
  a root-only transaction already marked `ROLLED_BACK` by `recover.sh`.
- Keep arbitrary pre-existing firewall rules and all foreign containers
  fail-closed; `--external-firewall` remains an explicit operator choice.

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
