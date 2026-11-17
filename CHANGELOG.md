# Changelog

All notable changes. Versions follow `app/VERSION`; each release ships `IranKillSwitch-Setup-<version>.exe`.

## 2.3.10 - 2026-11-17

### Added
- **Live ping cards** under the headline: *VPN PING* (round trip inside the tunnel) and *DIRECT PING*
  (straight to an Iranian site), with a level dot (green < 300 ms, amber < 1000 ms, red slower / no answer).
  Measured like VPN clients do: the tunnel connection is opened first, then one request on it is timed.
- **Scripts and shortcuts as allowed apps**: `.bat`, `.cmd`, `.ps1` and `.lnk` are accepted. The programs
  they start are allowed (nested scripts, `%~dp0`, `$PSScriptRoot`, relative paths), e.g.
  `xray_no_window.cmd -> xray_no_window.ps1 -> xray.exe`.
- **Pure-PowerShell tools** (no `.exe` of their own) get a private `powershell.exe` copy in
  `state\launchers` and a desktop shortcut *Name (Kill Switch)*; only that copy is allowed.
- Leak test row **WebRTC shows the VPN IP**: explains `n/a` in proxy mode (UDP cannot use a proxy) and,
  in TUN mode, sends a real STUN request through the tunnel and fails if the address seen is Iranian.

### Changed
- **After Turn ON, protection is kept automatically** when every check passes and an Iranian site is
  reachable. The question with the auto-undo countdown appears only when a check fails.
- **VPN row names the client that really carries the traffic**, found from evidence (TCP connections to
  a foreign server over the real adapter, or the owner of the proxy port), shown as its app
  (`xray -> v2rayN`). No proof, no name.
- The Windows proxy setting wins when several VPN clients listen on local proxy ports at once.
- "VPN apps" is now **Allowed apps** (not every allowed program is a VPN).
- The power icon in the ring is a drawn path, exactly centred.

### Fixed
- **UDP inside wintun / sing-tun tunnels was blocked** (DNS, WebRTC/STUN) while protection was on:
  unconnected UDP sockets are classified before the interface is known. The local addresses of every
  tunnel adapter are now permitted, not only TAP. The real adapter's address is never exempted.
- TUN-mode ping showed a fake ~10 ms (sing-tun answers the TCP handshake locally).
- Proxy-mode ping showed a fake value (sing-box answers `CONNECT` before dialling).
- `Get-IKSStatus` threw without admin rights on unreadable paths.

### Security
- **Windows' own programs can no longer be allowed** (PowerShell, cmd, curl...): allowing one let every
  script on the PC bypass the kill switch with the real IP. Entries saved by older versions are dropped.
- Helper programs started by an allowed app stay allowed **only while they run** (a one-off tool started
  once was allowed forever).

## 2.3.1 - 2026-11-14
Direct sites, proxy-mode support, fixes. See the [release](https://github.com/saateon/iran-kill-switch/releases/tag/v2.3.1).

## 2.0.5 - 2026-11-12
First public version of the v2 engine (native WFP). See the [release](https://github.com/saateon/iran-kill-switch/releases/tag/v2.0.5).
