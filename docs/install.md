# Install, update, uninstall

[Back to README](../README.md)

## Requirements

| | |
|---|---|
| Windows | 10 version 1607 or newer, or 11 (Home or Pro; x64, x86, ARM64) |
| Rights | Administrator (the installer and the app ask once via UAC) |
| Software | nothing extra: Windows PowerShell 5.1 and .NET Framework 4.x ship with Windows |
| Services | Base Filtering Engine and Task Scheduler running (default) |

The installer checks all of this and explains what is missing.

## Install

1. Download `IranKillSwitch-Setup-<version>.exe` from the [latest release](https://github.com/saateon/iran-kill-switch/releases/latest).
2. Run it, accept the admin prompt, press **Install**.
3. Press **Open Iran Kill Switch**. Protection stays **off** until you turn it on.

SmartScreen may warn because the file is not code-signed: **More info -> Run anyway**.

### Silent install (many PCs)

```
IranKillSwitch-Setup-<version>.exe /quiet
```

Exit code `0` = installed. Nothing is shown.

## Update

Run the newer setup the same way. Settings, the VPN app list, allowed servers and the
on/off state are kept; if protection was on, the new version re-applies it immediately.
A running app window is closed and reopened on the new version.

Version 1 (Windows Firewall rules) is migrated automatically: its rules are removed and the
firewall profiles it turned on are restored.

## Turn off / uninstall

| | |
|---|---|
| Turn off | click the big ring |
| Emergency OFF (even if the app is broken) | Start menu -> Iran Kill Switch -> **Emergency OFF** |
| Uninstall | Settings -> Apps -> Iran Kill Switch, or **Uninstall** at the bottom of the app |

Uninstall removes every filter, route, scheduled task, shortcut and file.
It never changed Windows Firewall, so there is nothing to restore there.

## What gets installed

| Path | |
|---|---|
| `C:\Program Files\IranKillSwitch\` | app, modules, native helper, Iran list |
| `...\state\` | settings, log, allowed servers |
| Task Scheduler `IKS-Guard` | background guard (SYSTEM; boot, every 5 min, network change) |
| Desktop + Start menu | Iran Kill Switch, Emergency OFF |
