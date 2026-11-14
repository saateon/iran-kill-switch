# Iran Kill Switch - agent brief

Windows selective VPN kill switch. Iran IPv4 -> direct. Everything else -> only via a VPN. VPN dies -> foreign blocked, Iran works.
Works with any VPN client without reading its config. PowerShell 5.1 + C# 5 (P/Invoke), zero dependencies, one installer exe.
Read this file only; open a module when the task needs it. User docs: README.md, docs/*.md (not needed for code work).

## Mechanism (one screen)
- **Filters**: native WFP (`app/native/IksNative.cs`), own provider+sublayer (fixed GUIDs, weight 0xFFFE), persistent, ONE transaction.
  Layers ALE_AUTH_CONNECT + ALE_AUTH_RECV_ACCEPT, v4+v6. Weights: w15 loopback | w14 each VPN app (ALE_APP_ID) |
  w13 tunnel if-types 53/23/131 + learned TAP IPs | w12 remote ranges: Iran + LAN/special + allowed servers + direct sites | w1 block.
  Our block beats every Windows Firewall allow rule. Windows Firewall is never touched.
- **Routes** (TUN VPNs): IP Helper adds Iran CIDRs (~1750) + direct-site CIDRs via the physical gateway, active store only.
- **Direct sites** (`state\direct-sites.txt`, domain/IP/CIDR/URL): resolved (parallel, 4 s, cache 7 days in `DirectCache`) -> w12 + routes,
  only while protection is ON (even with Iran direct off). Proxy-mode VPNs ignore routes, so the GUI also writes them to
  HKCU `ProxyOverride` (ours remembered in `HKCU:\Software\IranKillSwitch\ProxyBypass`); re-applied on ON/OFF, Refresh, list save, hourly.
  Per-app bypass in TUN mode is impossible without a kernel callout driver.
- **Guard**: task `IKS-Guard` (SYSTEM; boot, 5 min, network event) -> `Invoke-IKSSync`: list (7 days), apps, servers, direct sites, filters, routes.
- **Safety**: Enable arms `IKS-AutoRevert` (+120 s) BEFORE filters; re-armed after the GUI checks (`Reset-IKSRevertTimer`); user confirms -> cancelled.
- **VPN modes** (Get-IKSStatus.VpnMode): `tun` (adapter up) | `proxy` (local proxy listening; `SystemProxy` = Windows proxy set) | none.
  Hiddify "Proxy" mode with Windows proxy OFF -> browsers go direct -> blocked (test 9 explains it).

## Files
```
app/VERSION              ONLY version source. Bump for every shipped change.
app/IKS.ps1              CLI + library (dot-source, no -Action). -Action Preview|Enable|Disable|Status|Test|Sync|UpdateList|AddApp|RemoveApp|IranDirect|Install|Uninstall
app/IKS.Gui.ps1          WPF app: XAML at top, Render-Status, handlers, timers (poll 15 s, update check 6 h, proxy bypass 1 h). Jobs: Start-Job2 '<cmd>' { param($o,$e) }
app/native/IksNative.cs  WfpSession, Cond, Routes (Add/Delete), Inet.Refresh (WinINet proxy change notify)
app/modules/Config       $script:IKS (catalog, VendorRegex, weights, URLs, paths), settings.json (atomic), Invoke-IKSLocked (Global mutex, ACL SYSTEM+Admins+Users)
           IpMath        [long[]] ranges in List[long[]]; merge/complement/binary search; ConvertTo-IKSCidrs
           IranList      RIPE NCC + ipdeny; sanity 300+ ranges / 4M-40M addrs; atomic file app/data/ir-ipv4.txt
           Discovery     Find-IKSVpnApps, Update-IKSVpnApps (auto|user|child, IgnoredApps), Find-IKSChildApps, Find-IKSVendorSiblings,
                         allowed servers, direct sites (Get-IKSDirectHosts/Update-IKSDirectSites/Get-IKSDirectCidrs), proxy bypass, interfaces
           Native        Import-IKSNative (bin\IksNative-<ver>.dll or in-memory), Build-IKSLauncher (exe that hosts PowerShell)
           Plan          Get-IKSPlan (pure, hash) -> Get-IKSFilterSpec -> Format-IKSPlan
           Protect       Set/Remove-IKSFilters, Get-IKSRouteCidrs (pure), Sync/Remove-IKSIranRoutes, Remove-IKSLegacy (v1)
           Tasks         IKS-Guard, IKS-AutoRevert
           Actions       Enable/Disable/Confirm-IKSKeep, Reset-IKSRevertTimer, Invoke-IKSSync, Get-IKSStatus, Get-IKSUpdateInfo (GitHub), app add/remove
           Diagnostics   Resolve-IKSIPv4Many, Invoke-IKSTest (sockets bound to the real NIC = "VPN down" simulation)
           Setup         requirements, install/update (keeps state\), uninstall (+ delayed folder removal)
installer/SetupApp.cs    setup exe (WinForms); Build-Setup.ps1 = tests -> payload.zip -> dist\IranKillSwitch-Setup-<ver>.exe (+ optional signing)
tests/Run-Tests.ps1      offline suite (~88 checks); -WfpLive = real filters in a DYNAMIC session (admin, protection OFF)
```
Installed: `C:\Program Files\IranKillSwitch`; `state\` = settings.json, iks.log, routes.txt, allowed-servers.txt, direct-sites.txt.

## Where to change what
| Task | Place |
|---|---|
| new VPN client not detected | Config catalog / VendorRegex; test in Run-Tests "[VPN app detection]" |
| new filter rule | Plan (Get-IKSFilterSpec) + Protect; keep weights order |
| new status row / button | IKS.Gui.ps1 XAML + Render-Status; data from Get-IKSStatus |
| new leak test | Diagnostics Invoke-IKSTest (numbered list) |
| setting key | Config defaults + array normalization in Read-IKSSettings |

## Invariants
- All source ASCII; .ps1/.cs/.cmd CRLF, .md LF (.gitattributes). Python/sed on this machine may write LF -> run `unix2dos`. Tests enforce ASCII + parse.
- PS 5.1 / C# 5 only: no `??`, ternary, `?.`, C# `$"..."`. Type checks as strings: `'IKS.Native.WfpSession' -as [type]`.
- Functions return lists with `return , $list`. Never wrap the call in `@(...)` or `[string[]]@(...)`: it becomes ONE item
  (this broke routes in 2.2.0 and proxy bypass in 2.3.0). Use the result directly or `.ToArray()`.
- Every state change via `Invoke-IKSLocked`; `Enabled=false` saved BEFORE removal; revert task armed BEFORE filters.
- Never auto-allow anything under %SystemRoot%; never whitelist the real NIC address as a tunnel.
- Read-only actions (Preview/Status/Test) never save settings or touch WFP. Not admin -> filter count/tasks "unknown", not "missing".
- GUI work that can block -> Start-Job2 (runspace, dot-sources IKS.ps1). UI thread only for cheap calls (<10 ms).
- The ring (RingBtn) is the only on/off control. Glow ellipse has its own 180 px box (never negative margins: WPF clips).

## Commands
```
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-WfpLive]     # after every change
powershell -ExecutionPolicy Bypass -File Build-Setup.ps1                     # [-CertThumbprint x | -CertPfx f]
$env:IKS_GUI_SELFTEST='x.png'; powershell -File app\IKS.Gui.ps1              # render GUI to PNG, no admin (VIEW=main|apps|tests)
```
Release: GitHub saateon/iran-kill-switch, tag `v<VERSION>`, asset `IranKillSwitch-Setup-<VERSION>.exe` (the app's update check reads it).

## Limits
WSL2/Hyper-V NAT not ALE-filtered. VPNs with their own WFP kill switch block Iran direct too. Android VPNs in BlueStacks: kill switch yes,
Iran direct no. Direct sites: only names + www twin (no subdomain discovery), FakeIP answers useless, CDN IPs shared. Unsigned exe -> SmartScreen.
