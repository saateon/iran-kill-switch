# Iran Kill Switch - agent brief (v2)

Windows selective kill switch. Iran IPv4 -> direct. Everything else -> only via a VPN. VPN dies -> foreign blocked, Iran keeps working. Works with any VPN client without reading its config (Hiddify, v2rayN, Clash, Amnezia, WireGuard, MobaXterm SSH tunnels, BlueStacks...).

## Mechanism
Native WFP (C# P/Invoke, `app/native/IksNative.cs`), own provider+sublayer (fixed GUIDs, weight 0xFFFE), persistent filters, applied in ONE transaction (abort on any error). Layers: ALE_AUTH_CONNECT + ALE_AUTH_RECV_ACCEPT, v4+v6. Per layer: w15 permit loopback | w14 permit each VPN app (ALE_APP_ID) | w13 permit tunnel interface types 53/23/131 (+ learned TAP local IPs) | w12 permit remote Iran+LAN/special+allowed servers (v4, chunks of 1000 ranges) / LAN prefixes (v6) | w1 block. Block in our sublayer beats every Windows Firewall allow rule. Windows Firewall itself is never touched.
"Iran direct" (TUN VPNs): IP Helper API adds ~1750 CIDR routes for Iran via the physical gateway (more specific than the VPN's routes), active store only, re-synced by the guard.

## Layout
```
Build-Setup.ps1          tests -> dist\IranKillSwitch-Setup-<VERSION>.exe (single file, payload.zip embedded, /quiet supported)
installer/SetupApp.cs    the setup exe (WinForms, app design); __IKS_VERSION__ replaced at build
Setup.cmd / Uninstall.cmd  dev entry points (self-elevate). Install == update (keeps state\)
app/VERSION              ONLY version source (GUI title/footer, native helper, Apps&features, setup file name)
app/IKS.ps1              CLI entry, dot-sources modules; no -Action = library mode
app/IKS.Gui.ps1          WPF app; runspace jobs (Start-Job2); tray; single instance (mutex+event); own AppUserModelID;
                         fixed height, Fit-ToScreen scales on small screens; results/apps open as overlay cards.
                         Dev: IKS_GUI_SELFTEST=<png> [IKS_GUI_SELFTEST_VIEW=main|apps|tests] [IKS_GUI_FIT_HEIGHT=n]; IKS_GUI_DEV=1 (no elevation)
app/IranKillSwitch.exe   built at install: requireAdministrator manifest; HOSTS PowerShell in-process (one process "Iran Kill Switch", app icon in Task Manager); PSExecutionPolicyPreference=Bypass (process scope)
app/native/IksNative.cs  WfpSession (Begin/Commit/Abort, AddFilter, ListOurFilters, RemoveAll), Cond, Routes (Add/Delete/DefaultRouteProbe)
app/modules/
  Config     $script:IKS (catalog, ranges, weights), Set-IKSRoot, log, settings.json (atomic), Invoke-IKSLocked (Global mutex, re-entrant)
  IpMath     [long[]] ranges in List[long[]]; merge/complement/binary search; ConvertTo-IKSCidrs
  IranList   RIPE + ipdeny, sanity 300+ ranges / 4M-40M addrs, atomic file
  Discovery  Find-IKSVpnApps (processes, services, vendor folders); Update-IKSVpnApps (auto|user|child, IgnoredApps);
             Find-IKSChildApps (helpers started by allowed apps, never %SystemRoot%); allowed servers parsing; interfaces
  Native     Import-IKSNative (bin\IksNative-<ver>.dll or in-memory), Build-IKSNative, Build-IKSLauncher, New-IKSIconFile
  Plan       Get-IKSPlan (pure, hash) + Get-IKSFilterSpec (filters as data) + Format-IKSPlan (preview)
  Protect    Set-IKSFilters [-Dynamic|-Session], Remove-IKSFilters, Get-IKSFilterCount (-1 if not admin), Sync/Remove-IKSIranRoutes, Remove-IKSLegacy (v1)
  Tasks      IKS-Guard (SYSTEM: boot, 5 min, network event -> Sync), IKS-AutoRevert (+120 s)
  Actions    Preview, Enable[-WithRevert], Disable, Confirm-IKSKeep, Add/Remove-IKSVpnApp, Set-IKSIranDirect, Sync (self-heal), Get-IKSStatus
  Diagnostics Invoke-IKSTest: sockets bound to the real NIC = "VPN down" simulation
  Setup      requirements (Win10 1607+, PS 5.1, FullLanguage, BFE, Schedule), install/update/migrate v1, uninstall
tests/Run-Tests.ps1      offline suite (+ -WfpLive: real filter set in a DYNAMIC session, admin, protection OFF)
tests/Native.Live.ps1    native helper live test (dynamic session, admin)
```

## Invariants
- All source ASCII (PS 5.1 + write tools mangle \u escapes: keep them as text). Tests enforce; Build-Setup refuses on any failure.
- PS 5.1 / C# 5 only (no `??`, ternary, `?.`, string interpolation in C#). Type checks as strings: `'IKS.Native.WfpSession' -as [type]`.
- Every state change via `Invoke-IKSLocked`; `Enabled=false` saved BEFORE removal; Enable arms the revert task BEFORE touching filters.
- Never auto-allow anything under %SystemRoot%; never whitelist the real NIC address as a tunnel.
- Read-only actions (Preview/Status/Test) never save settings or touch WFP. Without admin, filter count/tasks are "unknown", not "missing".
- One version source: app/VERSION. Bump it for every change that ships.
- The ring is the single on/off control (RingBtn): hover grows, press sinks, ON = arc draw-in + breathing glow, hover hint shows the action.

## Commands
```
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-WfpLive]
powershell -ExecutionPolicy Bypass -File Build-Setup.ps1
dist\IranKillSwitch-Setup-<ver>.exe [/quiet]
```
Installed: `C:\Program Files\IranKillSwitch` (state\: settings.json, iks.log, routes.txt, allowed-servers.txt).

## Limits
WSL2/Hyper-V NAT traffic is forwarded, not ALE-filtered. VPNs with their own WFP kill switch (WireGuard "block untunneled") also block Iran-direct. Android VPNs inside BlueStacks tunnel everything before Windows sees it (kill switch yes, Iran-direct no). Unsigned exe may get a SmartScreen prompt.
