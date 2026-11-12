# Config.ps1 - constants, paths, logging, settings store, global lock.
# Every object the tool creates carries the name/prefix "IKS" or "Iran Kill Switch".

$script:IKS = @{
    Name            = 'Iran Kill Switch'
    Author          = 'Mansoor'
    InstallDir      = Join-Path $env:ProgramFiles 'IranKillSwitch'
    GuardTask       = 'IKS-Guard'
    RevertTask      = 'IKS-AutoRevert'
    RevertSeconds   = 120
    LegacyGroup     = 'Iran Kill Switch'        # v1 Windows Firewall rule group (removed on upgrade)
    ListMaxAgeDays  = 7
    EndpointCacheDays = 7
    TunnelKeepDays  = 30
    ChunkSize       = 1000                      # address-range conditions per WFP filter
    RouteMetric     = 1
    # Never "foreign internet": this-net, LAN, CGNAT, loopback, link-local/DHCP,
    # fake-ip/benchmark, multicast + reserved + broadcast
    SpecialV4       = @('0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
                        '172.16.0.0/12', '192.0.0.0/24', '192.168.0.0/16', '198.18.0.0/15', '224.0.0.0/3')
    # IPv6 that never leaves the LAN: link-local, multicast, unique-local
    SpecialV6       = @('fe80::/10', 'ff00::/8', 'fc00::/7')
    # Interface types that are tunnels: PROP_VIRTUAL (wintun, WireGuard), PPP (Windows VPN), TUNNEL
    TunnelIfTypes   = @(53, 23, 131)
    # TAP adapters report as Ethernet (6); their addresses are learned instead
    TapRegex        = '(?i)tap-windows|tap0901|openvpn|amnezia.*tap|tap adapter'
    # Known VPN programs. Detection: running processes, services, and the vendor folders below.
    VpnCatalog      = @(
        'Hiddify.exe', 'HiddifyCli.exe', 'v2rayN.exe', 'xray.exe', 'v2ray.exe', 'sing-box.exe',
        'nekoray.exe', 'nekobox.exe', 'nekobox_core.exe', 'clash-verge.exe', 'verge-mihomo.exe',
        'verge-mihomo-alpha.exe', 'mihomo.exe', 'clash.exe', 'clash-meta.exe',
        'wireguard.exe', 'amneziawg.exe', 'AmneziaVPN.exe', 'AmneziaVPN-service.exe', 'openvpn.exe',
        'tun2socks.exe', 'Outline.exe', 'psiphon3.exe', 'psiphon-tunnel-core.exe',
        'warp-svc.exe', 'ProtonVPN.WireGuardService.exe', 'ProtonVPNService.exe',
        'HD-Player.exe', 'BstkSVC.exe', 'MobaXterm.exe', 'MobaRTE.exe'
    )
    VendorRegex     = '(?i)hiddify|v2ray|xray|sing-?box|nekoray|nekobox|clash|mihomo|wireguard|amnezia|openvpn|outline|psiphon|cloudflare|proton|bluestacks|mobatek|mobaxterm'
    LocalProxyPorts = @(12334, 2334, 10808, 10809, 7890, 7897, 2080, 1080)
    IranSources     = @(
        @{ Name = 'RIPE NCC'; Url = 'https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest'; Kind = 'ripe' },
        @{ Name = 'ipdeny';   Url = 'https://www.ipdeny.com/ipblocks/data/aggregated/ir-aggregated.zone'; Kind = 'cidr' }
    )
}

# All paths derive from the app root, so the same code runs from the source
# folder or from the installed copy.
function Set-IKSRoot([string]$Root) {
    $script:IKS.AppDir        = $Root
    $script:IKS.StateDir      = Join-Path $Root 'state'
    $script:IKS.DataDir       = Join-Path $Root 'data'
    $script:IKS.BackupDir     = Join-Path $Root 'state\backup'
    $script:IKS.LogFile       = Join-Path $Root 'state\iks.log'
    $script:IKS.SettingsFile  = Join-Path $Root 'state\settings.json'
    $script:IKS.EndpointsFile = Join-Path $Root 'state\allowed-servers.txt'
    $script:IKS.RoutesFile    = Join-Path $Root 'state\routes.txt'
    $script:IKS.IranFile      = Join-Path $Root 'data\ir-ipv4.txt'
    $script:IKS.NativeSrc     = Join-Path $Root 'native\IksNative.cs'
    $vf = Join-Path $Root 'VERSION'
    $script:IKS.Version       = if (Test-Path $vf) { (Get-Content $vf -TotalCount 1).Trim() } else { '0.0.0' }
    $script:IKS.NativeDll     = Join-Path $Root "bin\IksNative-$($script:IKS.Version).dll"
}
Set-IKSRoot (Split-Path -Parent $PSScriptRoot)

function Initialize-IKSState {
    if (-not (Test-Path $script:IKS.StateDir)) { New-Item -ItemType Directory -Force $script:IKS.StateDir | Out-Null }
}

function Write-IKSLog([string]$Message, [string]$Level = 'INFO') {
    try {
        Initialize-IKSState
        if ((Test-Path $script:IKS.LogFile) -and (Get-Item $script:IKS.LogFile).Length -gt 1MB) {
            Move-Item $script:IKS.LogFile "$($script:IKS.LogFile).old" -Force
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $script:IKS.LogFile -Value $line -Encoding UTF8
    } catch { }   # logging must never break an operation
}

function Test-IKSAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- settings (state\settings.json) -------------------------------------
function Read-IKSSettings {
    $s = @{
        Enabled = $false; IranDirect = $true
        VpnApps = @(); IgnoredApps = @(); EndpointCache = @(); LearnedTunnels = @()
        AppliedHash = ''; AppliedAt = ''; AppliedFilters = 0
        RoutesIfIndex = 0; RoutesNextHop = ''; RoutesHash = ''; RoutesCount = 0
        ProfilesBackup = $null                       # v1 only: restored by the migration
        LastSync = ''; LastSyncResult = ''; LastError = ''
    }
    if (Test-Path $script:IKS.SettingsFile) {
        try {
            $j = Get-Content $script:IKS.SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = $p.Value }
        } catch { Write-IKSLog "settings.json unreadable, defaults used: $_" 'WARN' }
    }
    foreach ($k in 'VpnApps', 'IgnoredApps', 'EndpointCache', 'LearnedTunnels') { $s[$k] = @($s[$k] | Where-Object { $_ }) }
    return $s
}

function Save-IKSSettings($Settings) {
    Initialize-IKSState
    $tmp = "$($script:IKS.SettingsFile).tmp"
    ($Settings | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $script:IKS.SettingsFile -Force          # atomic replace
}

# ---- one operation at a time (GUI, guard task, CLI) ----------------------
function Invoke-IKSLocked([scriptblock]$Body) {
    $m = New-Object System.Threading.Mutex($false, 'Global\IranKillSwitch')
    $got = $false
    try {
        try { $got = $m.WaitOne(180000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { throw 'Another Iran Kill Switch operation is still running. Try again in a minute.' }
        & $Body
    } finally {
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

# Age in days of an ISO date string; large number when missing/invalid
function Get-IKSAgeDays([string]$When) {
    try { return ((Get-Date) - [datetime]$When).TotalDays } catch { return 99999 }
}
