# ops-toolkit

**English** · [Português (BR)](README.pt-BR.md)

[![CI](https://github.com/omfgnick/ops-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/omfgnick/ops-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-informational)](LICENSE)

Operations scripts for infrastructure and incident work — monitoring, health
checks, reporting, backup and auditing — in **PowerShell** and **Bash**.

Written and used by [Nicolas Mesquita Fernandes](https://github.com/omfgnick)
(NOC / N1–N3 support) in day-to-day operations. Every script is linted and
syntax-checked on each push.

> This repository supersedes the former `Powershell-Scripts` and `Bash-Scripts`
> repositories; their history was merged in and is preserved here.

## Layout

```
powershell/   Windows-side operations (PowerShell 5.1+ / 7.x)
bash/         Linux-side operations (bash 4+)
tests/        Pester and Bats test suites
docs/         Per-language reference
```

## What it looks like

Real output, captured from the Docker image in this repository — not mocked up.

`incident-triage` — the first command to run when a ticket lands:

```console
$ incident-triage
===============================================================
 INCIDENT TRIAGE — 7e40c2effda0
 2026-08-18 22:25:17 UTC
===============================================================

-- System ------------------------------------------------------
  Kernel      : Linux 6.18.33.1-microsoft-standard-WSL2
  Uptime      : unknown
  Load        : 0.28 0.38 0.36  (0.04 per core, 8 CPUs)
  Memory      : 11% used
  Fullest FS  : /etc/hosts at 4%

-- Failed units ------------------------------------------------
  none

-- Listening sockets -------------------------------------------
  (ss unavailable)

-- Recent errors (last 15) -------------------------------------
  none (or journalctl unavailable)

-- Summary -----------------------------------------------------
  Nothing alarming found.
```

`disk-space` — flags anything at or below the threshold and exits non-zero:

```console
$ disk-space -t 25
FILESYSTEM               MOUNT                    SIZE     USED    AVAIL  FREE%  STATUS
/dev/sdd                 /etc/hosts            1006.9G    31.7G   923.9G    96%  ok

0 filesystem(s) at or below 25% free.
```

Every report script also speaks JSON, validated in CI against [schemas/](schemas/):

```console
$ disk-space -j | jq
{
  "threshold_percent": 15,
  "low_count": 0,
  "filesystems": [
    {
      "filesystem": "/dev/sdd",
      "mount": "/etc/hosts",
      "size_kb": 1055762868,
      "used_kb": 33232832,
      "available_kb": 968826564,
      "free_percent": 96,
      "low": false
    }
  ]
}
```

`backup-verify` — the backup is only reported good after being restored and
checksummed against the source:

```console
$ backup-verify -s /tmp/conf -d /tmp/bk
Backup: /tmp/bk/conf-2026-08-18_222517.tar.gz
  source       : /tmp/conf (2 file(s), 4117 bytes)
  archive      : 192 bytes
  verification : 2 file(s) restored and checked with sha256
  result       : OK — restored and identical to the source
```

`metrics-collector -p` — ready for the node_exporter textfile collector:

```console
$ metrics-collector -p -s disk-space,incident-triage
# HELP ops_toolkit_up 1 when collection finished without failures
# TYPE ops_toolkit_up gauge
ops_toolkit_up 0
# HELP ops_toolkit_collect_timestamp_seconds When the collection ran
# TYPE ops_toolkit_collect_timestamp_seconds gauge
ops_toolkit_collect_timestamp_seconds 1787091917
```

## Interactive menu

If you would rather pick from a list than remember names and flags:

```bash
./menu.sh
```

```powershell
.\Menu.ps1
```

The list is built from the scripts themselves, so a new script appears with no
change to the menu — and its description comes from the same header that feeds
`--help`, so the two cannot disagree.

Type a number to run one; anything after the number is passed straight through
(`7 -t 20`). The PowerShell menu goes further and prompts for each of the
chosen script's own parameters.

Both also work without the menu, which is what a scheduled task needs:

```bash
./menu.sh -l                        # list names
./menu.sh -r disk-space -t 20       # run one directly
```

### Run it without cloning

Straight from the web, the way you would run a one-off installer:

```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/Menu.ps1")))
```

```bash
curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/menu.sh | bash
```

There is no file on disk in that mode, so the menu asks **where to put the
toolkit** before downloading anything — a temporary folder if you are just
trying it out, or a permanent one if you want to keep it. Nothing is written
until you answer.

To skip the question (unattended use), name the destination up front:

```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/Menu.ps1"))) -Destination Temp
```

```bash
DESTINATION=temp curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/menu.sh | bash
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/omfgnick/ops-toolkit/main/install.sh | bash
```

Each script becomes a command without the `.sh`, so `incident-triage -j` works
from anywhere. `sudo` installs to `/usr/local/bin`; without it, `~/.local/bin`.
Uninstall with `./install.sh -u` — it only removes files carrying the toolkit
marker, so a same-named command from elsewhere is left alone.

Prefer a container? `docker build -t ops-toolkit . && docker run --rm ops-toolkit incident-triage`.
To inspect the **host** rather than the container, see the notes in the [Dockerfile](Dockerfile).

Every command answers `--version` and `--help`, and `man incident-triage` works
after `tools/gen-man.sh` (pages are generated from the same header that feeds
`--help`, so the two cannot drift apart).

## Conventions

Every script follows the same contract, so learning one teaches you all:

| Convention | What it means |
|---|---|
| `-h` / `--help` | Prints the script's own header block — usage, options, examples |
| `--dry-run` / `-WhatIf` | Anything that changes state can be simulated first |
| `--json` | Report scripts emit structured output for Grafana/Zabbix, validated in CI against [schemas/](schemas/) |
| Exit codes | `0` success · `1` runtime failure · `2` bad usage |

Line endings are enforced by `.gitattributes`: `.sh` is always **LF** (CRLF
breaks the shebang on Linux), `.ps1` is **CRLF**. CI fails if that drifts.

## PowerShell

| Script | Purpose |
|---|---|
| `backup-folder.ps1` | Compressed backup of a directory, with optional e-mail notification |
| `backup_retention.ps1` | Removes files older than a threshold, recursively |
| `Get-DiskSpaceReport.ps1` | Free space per volume, flags anything below a threshold |
| `Test-ServiceHealth.ps1` | Checks Windows services, optionally restarting what is stopped |
| `Test-Endpoints.ps1` | HTTP/TCP reachability and latency for a list of endpoints |
| `Get-OpenPorts.ps1` | Listening/established TCP ports with the owning process |
| `Get-EventLogErrors.ps1` | Errors and warnings from the event log over a time window |
| `Get-TLSCertExpiry.ps1` | Days remaining on TLS certificates |
| `New-UptimeReport.ps1` | Uptime and last boot time |
| `Rotate-Logs.ps1` | Rotates and compresses log files |
| `Cleanup-TempFiles.ps1` | Clears temporary directories |
| `Audit-LocalUsers.ps1` | Local accounts, groups and password policy |
| `Get-IncidentTriage.ps1` | One-shot machine snapshot for the start of a ticket |
| `Test-NetworkPath.ps1` | Ping loss/latency and TCP port checks for link monitoring |
| `Get-SecurityAudit.ps1` | Read-only security review: accounts, firewall, SMBv1, RDP |

### As a PowerShell module

The scripts stay standalone — copying a single `.ps1` to a server still works.
On a machine with the whole toolkit, importing the module gives you the same
scripts as commands, with tab completion and `Get-Help`:

```powershell
Import-Module ./powershell/OpsToolkit.psd1
Get-OpsToolkitCommand            # what is available
Get-DiskSpaceReport -ThresholdPercent 20
```

The wrappers forward every parameter untouched (including `-WhatIf`), so the
module cannot behave differently from the file it wraps.

Full reference: [docs/powershell.en.md](docs/powershell.en.md)

## Bash

| Script | Purpose |
|---|---|
| `backup-folder.sh` | Compressed backup with integrity check and optional e-mail |
| `portscan-vuln.sh` | nmap scan with a simple per-port risk rating |
| `check-services.sh` | systemd service health, optionally restarting what is down |
| `disk-space.sh` | Free space per filesystem, flags anything below a threshold |
| `rotate-logs.sh` | Compresses old logs and drops archives past retention (dry run by default) |
| `check-endpoints.sh` | HTTP(S) reachability, status code and latency |
| `check-tls-expiry.sh` | Days remaining on TLS certificates |
| `incident-triage.sh` | One-shot machine snapshot for the start of a ticket |
| `net-monitor.sh` | Ping loss/latency and TCP port checks for link monitoring |
| `audit-hardening.sh` | Read-only security review: accounts, sudo, SSH, file modes |
| `metrics-collector.sh` | Runs the report scripts and emits one JSON, or Prometheus metrics for node_exporter |
| `backup-verify.sh` | Backup that is only trusted after being restored and checksummed |
| `inventory.sh` | Machine inventory: identity, OS, CPU, disks, network, packages |

Full reference: [docs/bash.en.md](docs/bash.en.md)

## Requirements

- **PowerShell** 5.1 (Windows) or 7.x (cross-platform)
- **Bash** 4+ with **GNU coreutils** — tested on Ubuntu, Debian 12 and Rocky 9
  in CI. BusyBox (Alpine) is *not* supported: its `df`, `date` and `find` lack
  the flags these scripts rely on. The scripts detect this and say so rather
  than reporting a wrong answer quietly.
- `portscan-vuln.sh` also needs `nmap`; `check-tls-expiry.sh` needs `openssl`

## Development

```bash
shellcheck -S style bash/*.sh          # must be clean
bash -n bash/<script>.sh               # syntax
```

```powershell
Invoke-ScriptAnalyzer -Path ./powershell -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security note

`portscan-vuln.sh` performs active scanning. Only run it against hosts you are
authorised to test.

## License

[MIT](LICENSE)
