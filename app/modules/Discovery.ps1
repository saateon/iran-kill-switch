# Discovery.ps1 - finds VPN programs, tunnel adapters and the real internet
# interface automatically. Nothing is read from any VPN client's configuration.

# ---- VPN programs ----------------------------------------------------------
# Returns @{ <full path (lower-case)> = <display name> } for every catalog program found.
function Find-IKSVpnApps {
    $names = @($script:IKS.VpnCatalog | ForEach-Object { $_.ToLower() })
    $found = @{}
    $add = { param($path) if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                 $leaf = (Split-Path $path -Leaf).ToLower()
                 if ($names -contains $leaf) { $found[$path.ToLower()] = [IO.Path]::GetFileNameWithoutExtension($path) } } }
    # 1. running processes
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { try { & $add $p.Path } catch { } }
    # 2. services (VPN background services run even when no window is open)
    foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        if ($svc.PathName -match '^\s*"?([^"]+?\.exe)') { & $add $Matches[1] }
    }
    # 3. vendor folders in the usual install locations (shallow, fast)
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:LOCALAPPDATA, $env:APPDATA)
    foreach ($u in @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue)) {
        $roots += (Join-Path $u.FullName 'AppData\Local\Programs'), (Join-Path $u.FullName 'AppData\Local'), (Join-Path $u.FullName 'AppData\Roaming')
    }
    foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $script:IKS.VendorRegex })) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Depth 3 -Filter *.exe -File -ErrorAction SilentlyContinue)) { & $add $f.FullName }
        }
    }
    return $found
}

# Programs started by an allowed VPN app (e.g. MobaXterm runs MobaRTE.exe from its own
# AppData folder). Windows' own programs (cmd, powershell, conhost...) are never followed.
function Find-IKSChildApps([string[]]$AllowedPaths) {
    $allowed = @($AllowedPaths | ForEach-Object { $_.ToLower() })
    if (-not $allowed) { return @{} }
    $procs = @{}
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $procs[[int]$p.ProcessId] = $p }
    $sys = $env:SystemRoot.ToLower()
    $found = @{}
    foreach ($p in $procs.Values) {
        $path = "$($p.ExecutablePath)".ToLower()
        if (-not $path -or $allowed -contains $path -or $path.StartsWith($sys)) { continue }
        $parent = $p.ParentProcessId; $depth = 0
        while ($parent -and $procs.ContainsKey([int]$parent) -and $depth -lt 6) {
            $pp = $procs[[int]$parent]
            if ($pp.ProcessId -eq $p.ProcessId) { break }
            if ($allowed -contains "$($pp.ExecutablePath)".ToLower()) {
                $found[$path] = "$([IO.Path]::GetFileNameWithoutExtension($path)) (via $([IO.Path]::GetFileNameWithoutExtension($pp.ExecutablePath)))"
                break
            }
            $parent = $pp.ParentProcessId; $depth++
        }
    }
    return $found
}

# Keeps the user's own entries, refreshes the automatic ones. Entry: { Path, Name, Source = auto|user|child }
# Child programs are followed on every call (cheap), even with -NoScan.
function Update-IKSVpnApps($Settings, [switch]$NoScan) {
    $list = @{}
    foreach ($a in $Settings.VpnApps) {
        if ($a.Source -in 'user', 'child' -or $NoScan) { $list[$a.Path.ToLower()] = [pscustomobject]@{ Path = $a.Path; Name = $a.Name; Source = $a.Source } }
    }
    if (-not $NoScan) {
        $auto = Find-IKSVpnApps
        $ignored = @($Settings.IgnoredApps | ForEach-Object { "$_".ToLower() })     # removed by the user: never re-added automatically
        foreach ($k in $auto.Keys) {
            if (-not $list.ContainsKey($k) -and $ignored -notcontains $k) { $list[$k] = [pscustomobject]@{ Path = $k; Name = $auto[$k]; Source = 'auto' } }
        }
    }
    $ignored = @($Settings.IgnoredApps | ForEach-Object { "$_".ToLower() })
    $kids = Find-IKSChildApps @($list.Keys)
    foreach ($k in $kids.Keys) {
        if (-not $list.ContainsKey($k) -and $ignored -notcontains $k) { $list[$k] = [pscustomobject]@{ Path = $k; Name = $kids[$k]; Source = 'child' } }
    }
    $Settings.VpnApps = @($list.Values | Sort-Object Name)
}

# Running children of allowed apps that are not allowed yet (the GUI uses this to sync at once)
function Get-IKSPendingChildren($Settings) {
    $known = @($Settings.VpnApps | ForEach-Object { $_.Path.ToLower() }) + @($Settings.IgnoredApps | ForEach-Object { "$_".ToLower() })
    return @((Find-IKSChildApps @($Settings.VpnApps | ForEach-Object { $_.Path })).Keys | Where-Object { $known -notcontains $_ })
}

# Only programs that still exist on disk can be put in a filter
function Get-IKSAppPaths($Settings) {
    return @($Settings.VpnApps | ForEach-Object { $_.Path } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Sort-Object -Unique)
}

# ---- allowed servers (optional; for built-in Windows VPN or a remote SOCKS) --
function Add-IKSHost($Map, [string]$HostName, [string]$Source) {
    if (-not $HostName) { return }
    $h = $HostName.Trim().Trim('[', ']').ToLower()
    if ($h -match ':' -or $h -match '^(localhost$|127\.|0\.)') { return }      # IPv6 / loopback skipped
    if ((Test-IKSIPv4 $h) -or ($h -match '^[\d\.]+/\d{1,2}$') -or $h -match '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$') {
        if (-not $Map.ContainsKey($h)) { $Map[$h] = $Source }
    }
}

# vless:// trojan:// hy2:// tuic:// ss:// socks:// vmess://(base64 json) | bare IP / CIDR / domain
function Add-IKSShareLink($Map, [string]$Line, [string]$Source) {
    $l = "$Line".Trim()
    if (-not $l -or $l[0] -eq '#') { return }
    if ($l -match '(?i)^vmess://([^#]+)') {
        try {
            $b = $Matches[1].Trim(); $b += '=' * ((4 - $b.Length % 4) % 4)
            Add-IKSHost $Map (([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json).add) $Source
        } catch { }
        return
    }
    if ($l -match '(?i)^[a-z][a-z0-9+.-]*://') {
        if ($l -match '@\[?([^\]\s:/?#@]+)\]?(:\d+)?([/?#]|$)') { Add-IKSHost $Map $Matches[1] $Source; return }
        if ($l -match '(?i)^ss://([^#@/?]+)') {
            try {
                $b = $Matches[1]; $b += '=' * ((4 - $b.Length % 4) % 4)
                $d = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))
                if ($d -match '@([^:@]+):\d+') { Add-IKSHost $Map $Matches[1] $Source }
            } catch { }
        }
        if ($l -match '(?i)^socks5?h?://([^:/@]+)') { Add-IKSHost $Map $Matches[1] $Source }
        return
    }
    Add-IKSHost $Map $l $Source
}

# Resolves the allowed-servers file into IPv4 ranges text; keeps recent answers (DNS hiccups)
function Update-IKSEndpoints($Settings) {
    $map = @{}
    if (Test-Path $script:IKS.EndpointsFile) {
        foreach ($line in Get-Content $script:IKS.EndpointsFile) { Add-IKSShareLink $map $line 'allowed-servers' }
    }
    $now = (Get-Date).ToString('s')
    $cache = @{}
    foreach ($c in $Settings.EndpointCache) {
        if ((Get-IKSAgeDays $c.LastSeen) -le $script:IKS.EndpointCacheDays -and $map.ContainsKey($c.Host)) { $cache["$($c.Host)|$($c.Ip)"] = $c }
    }
    foreach ($h in $map.Keys) {
        $ips = @()
        if ((Test-IKSIPv4 $h) -or $h -match '/') { $ips = @($h) }
        else { try { $ips = @([Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { } }
        foreach ($ip in $ips) { $cache["$h|$ip"] = [pscustomobject]@{ Host = $h; Ip = $ip; LastSeen = $now } }
    }
    $Settings.EndpointCache = @($cache.Values | Sort-Object Host, Ip)
}

# ---- interfaces ------------------------------------------------------------
function Get-IKSTunnelAdapters {
    $out = @()
    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $isTunnel = ($script:IKS.TunnelIfTypes -contains [int]$a.InterfaceType) -or ("$($a.InterfaceDescription)" -match $script:IKS.TapRegex)
        if (-not $isTunnel) { continue }
        $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress })
        $out += [pscustomobject]@{ Name = $a.Name; Description = $a.InterfaceDescription; ifIndex = $a.ifIndex
                                   IfType = [int]$a.InterfaceType; IsTap = [int]$a.InterfaceType -eq 6; IPv4 = $ips }
    }
    return $out
}

# Real internet interface = best IPv4 default route that is not a tunnel
function Get-IKSPhysicalInterface {
    $tun = @(Get-IKSTunnelAdapters | ForEach-Object { $_.ifIndex })
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object { $tun -notcontains $_.ifIndex -and $_.NextHop -ne '0.0.0.0' } |
                Sort-Object { $_.RouteMetric + $_.InterfaceMetric })
    foreach ($r in $routes) {
        $ip = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        if ($ip) { return [pscustomobject]@{ ifIndex = $r.ifIndex; Alias = $r.InterfaceAlias; IPv4 = $ip.IPAddress; Gateway = $r.NextHop } }
    }
    return $null
}

# TAP adapters look like Ethernet, so their addresses are remembered and exempted by address
function Update-IKSLearnedTunnels($Settings) {
    $now = (Get-Date).ToString('s')
    $map = @{}
    foreach ($t in $Settings.LearnedTunnels) { if ((Get-IKSAgeDays $t.LastSeen) -le $script:IKS.TunnelKeepDays) { $map[$t.Ip] = $t.LastSeen } }
    $phys = Get-IKSPhysicalInterface
    foreach ($a in @(Get-IKSTunnelAdapters | Where-Object { $_.IsTap })) {
        foreach ($ip in $a.IPv4) { if (-not $phys -or $ip -ne $phys.IPv4) { $map[$ip] = $now } }   # never exempt the real NIC
    }
    $Settings.LearnedTunnels = @($map.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Ip = $_; LastSeen = $map[$_] } })
}

# First local proxy port that is listening (proxy-mode VPN clients)
function Get-IKSLocalProxy {
    try {
        $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::') } | ForEach-Object { $_.LocalPort })
        foreach ($p in $script:IKS.LocalProxyPorts) { if ($listen -contains $p) { return "http://127.0.0.1:$p" } }
    } catch { }
    return $null
}
