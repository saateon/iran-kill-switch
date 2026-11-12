# Build from source

[Back to README](../README.md)

Everything builds with tools that ship with Windows; nothing to install.

## Make the installer

```
powershell -ExecutionPolicy Bypass -File Build-Setup.ps1
```

1. Runs the full test suite. **Any failure stops the build.**
2. Packs `app\` (without machine state) as `payload.zip`.
3. Compiles `installer\SetupApp.cs` with the .NET Framework C# compiler.
4. Writes `dist\IranKillSwitch-Setup-<version>.exe`.

## Versioning

`app\VERSION` is the **only** place to change the version. It flows into the window title,
the footer, the native helper, Apps & features, the file properties and the setup file name.
Bump it for every change that ships.

## Tests

```
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1            # offline, no admin
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 -WfpLive   # admin, protection OFF
powershell -ExecutionPolicy Bypass -File tests\Native.Live.ps1          # admin
```

| Suite | Covers |
|---|---|
| offline | ASCII + parse of every file, IP math, CIDR splitting, share-link parsing, Iran list, VPN app detection and helper following, filter plan invariants, settings store, GUI rendering (3 views + small screen), real window: single instance, tray, footer |
| `-WfpLive` | the real filter set in a **dynamic** WFP session (removed automatically): foreign blocked, VPN program allowed, Iran/LAN/loopback allowed, DNS leak blocked, atomic re-apply |
| `Native.Live` | WFP conditions, transactions, enumeration, cleanup; route API layout |

## Layout

```
Build-Setup.ps1          one-command installer build
installer/SetupApp.cs    the installer (WinForms, app design)
app/VERSION              version
app/IKS.ps1              CLI entry; loads modules
app/IKS.Gui.ps1          WPF app
app/native/IksNative.cs  WFP + route API (P/Invoke)
app/modules/             Config, IpMath, IranList, Discovery, Native, Plan, Protect, Tasks, Actions, Diagnostics, Setup
app/data/ir-ipv4.txt     bundled Iran list
tests/                   test suites
Setup.cmd, Uninstall.cmd developer entry points
```

## CLI

```
IKS.ps1 -Action Preview | Enable [-WithRevert] | Disable | Status | Test [-Json]
IKS.ps1 -Action Sync | UpdateList | AddApp -Path <exe> | RemoveApp -Path <exe> | IranDirect -On|-Off
IKS.ps1 -Action Install | Uninstall
```

## Rules for contributors

- Source files are ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI).
- PowerShell 5.1 and C# 5 syntax only.
- Every state change goes through `Invoke-IKSLocked`; read-only actions never write.
- See [AGENTS.md](../AGENTS.md) for invariants.
