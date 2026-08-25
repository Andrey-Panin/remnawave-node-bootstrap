# Changelog

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
