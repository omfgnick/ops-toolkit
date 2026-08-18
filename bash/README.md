# Bash Scripts

**English** · [Português (BR)](README.pt-BR.md)

Small, self-contained Bash utilities for infrastructure and security tasks.

## Scripts

### `backup-folder.sh`
Creates a compressed (`.tar.gz`) backup of a directory, verifies the resulting
archive is valid, and optionally e-mails a status report.

```bash
./backup-folder.sh -s /var/www -d /mnt/backups -e ops@example.com
```

| Flag | Description | Default |
|------|-------------|---------|
| `-s` | Source directory to back up | `SRC_DIR` env var |
| `-d` | Destination directory for the archive | `DST_DIR` env var |
| `-e` | E-mail recipient for the status report (empty = disabled) | `EMAIL_RECIPIENT` env var |
| `-h` | Show help | — |

Integrity is checked with `gzip -t` and `tar -tzf` on the produced archive.
E-mail notification requires a working `sendmail` binary and is skipped
otherwise.

### `portscan-vuln.sh`
Scans a host with `nmap` and prints a simple, illustrative risk rating for each
open TCP port.

```bash
./portscan-vuln.sh -p 1-1024 example.com
```

| Flag | Description | Default |
|------|-------------|---------|
| `-p` | Port spec passed to nmap (e.g. `22,80,443`, `1-1024`, `-`) | `1-65535` |
| `-h` | Show help | — |

The scan runs `nmap` **once** (grepable output) instead of per-port, which is
dramatically faster than the naive loop.

> ⚠️ **Authorised use only.** Only scan hosts you own or have explicit written
> permission to test. The vulnerability "ratings" are a teaching aid, not a real
> assessment.

## Requirements

- Bash 4+
- `tar`, `gzip`, `mktemp` (for `backup-folder.sh`)
- `nmap` (for `portscan-vuln.sh`)
- `sendmail` (optional, for e-mail notifications)

## Usage

```bash
chmod +x *.sh
./backup-folder.sh -h
```
