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

## Conventions

Every script follows the same contract, so learning one teaches you all:

| Convention | What it means |
|---|---|
| `-h` / `--help` | Prints the script's own header block — usage, options, examples |
| `--dry-run` / `-WhatIf` | Anything that changes state can be simulated first |
| `--json` | Report scripts emit structured output for Grafana/Zabbix |
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

Full reference: [docs/powershell.en.md](docs/powershell.en.md)

## Bash

| Script | Purpose |
|---|---|
| `backup-folder.sh` | Compressed backup with integrity check and optional e-mail |
| `portscan-vuln.sh` | nmap scan with a simple per-port risk rating |

Full reference: [docs/bash.en.md](docs/bash.en.md)

## Requirements

- **PowerShell** 5.1 (Windows) or 7.x (cross-platform)
- **Bash** 4+; `portscan-vuln.sh` also needs `nmap`

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
