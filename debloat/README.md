# debloat

Removes preinstalled apps and turns off telemetry, promotional content and
unused interface features on Windows.

This lives in its own folder, outside the main menu, on purpose. Everything else
in this toolkit reports on a machine; this changes it. A script that removes
apps should not sit in the same list you scroll through on a production server.

## Try it without changing anything

```powershell
.\Invoke-Debloat.ps1
```

That prints the full plan and exits. Nothing is touched until you add `-Apply`.
It works on any machine, including Linux — the plan is just a data file being
read, so you can review it before going near a workstation.

```powershell
.\Invoke-Debloat.ps1 -Profile Recommended          # see more
.\Invoke-Debloat.ps1 -Profile Recommended -Apply   # do it
```

## Profiles

Cumulative: `Recommended` includes `Minimal`, `Aggressive` includes both.

| Profile | What it covers |
|---|---|
| `Minimal` | Preinstalled games and Bing apps, advertising ID, Start menu suggestions. Nothing here carries a High risk. |
| `Recommended` | Adds Groove/Maps/Clipchamp/consumer Teams, minimum diagnostic data, Widgets, Chat, Copilot and search highlights. |
| `Aggressive` | Adds telemetry services, scheduled tasks and web results in search. |

Services and scheduled tasks appear only in `Aggressive`, and that is
deliberate: a disabled service tends to break something weeks later, far from
any hint that this script was the cause.

## What protects you

**1 — Nothing runs by default.** Without `-Apply`, you get the plan.

**2 — A restore point** is created before the first change. Skip with
`-NoRestorePoint`, which only makes sense where policy disables restore points.
Windows refuses more than one per 24h; if that happens the script says so and
continues, because the registry backup below still applies.

**3 — Registry keys are exported before being touched**, and a revert script is
written next to the export:

```
%USERPROFILE%\ops-toolkit-debloat\<timestamp>\
    privacy.telemetry.reg      exported before the change
    ui.widgets.reg
    Undo-Debloat.ps1           restores everything this run changed
```

A key that did not exist before is recorded as such, so the revert removes it
instead of restoring a value that was never there.

**4 — `-WhatIf` and `-Confirm` work**, because every change goes through
`ShouldProcess`.

## Undoing it

```powershell
& "$env:USERPROFILE\ops-toolkit-debloat\<timestamp>\Undo-Debloat.ps1"
```

Removed apps are not reinstalled by the revert script — they come back from the
Microsoft Store, and the script lists which ones by name. Everything else
(registry, services, scheduled tasks) is restored to the value it had.

## Picking individual actions

Each entry has an id, shown in the plan:

```powershell
.\Invoke-Debloat.ps1 -Profile Aggressive -Skip svc.diagtrack, app.quickassist -Apply
.\Invoke-Debloat.ps1 -Only app.solitaire, app.bing.news -Apply
```

## The list itself

Every change lives in [`Actions.psd1`](Actions.psd1) as data, not code, so it can
be reviewed without reading the engine. Each entry declares its profile, its risk
and how to undo it — and the test suite enforces that: an action without a
documented revert, or a service placed outside `Aggressive`, fails CI.

## Before you trust it

The CI for this repository runs on Linux, so it checks the catalogue, the plan
logic and the safety rules — **but it cannot verify that the removals actually
work**. That needs Windows.

Run it on one machine first, ideally a VM or a spare workstation, and confirm
the result before using it anywhere that matters.
