# Protect.ps1 - applies / removes the WFP filters and the Iran direct routes.

# ---- WFP ---------------------------------------------------------------------
function ConvertTo-IKSCond($Item) {
    switch ($Item.Kind) {
        'loopback' { return , @([IKS.Native.Cond]::Loopback()) }
        'app'      { return , @([IKS.Native.Cond]::App($Item.App)) }
        'iftype'   { return , @($Item.Types | ForEach-Object { [IKS.Native.Cond]::InterfaceType([uint32]$_) }) }
        'remote'   { return , @($Item.Ranges | ForEach-Object { [IKS.Native.Cond]::RemoteRange([uint32]$_[0], [uint32]$_[1]) }) }
        'local'    { return , @($Item.Ranges | ForEach-Object { [IKS.Native.Cond]::LocalRange([uint32]$_[0], [uint32]$_[1]) }) }
        'v6'       {
            return , @($Item.Prefixes | ForEach-Object {
                $a, $len = $_ -split '/'
                [IKS.Native.Cond]::RemoteV6([Net.IPAddress]::Parse($a).GetAddressBytes(), [byte]$len)
            })
        }
        'block'    { return , @() }
    }
}

# Replaces every IKS filter in ONE transaction. Any error -> abort: the old filters stay exactly as they were.
function Set-IKSFilters($Plan, [switch]$Dynamic, $Session) {
    Import-IKSNative
    $own = -not $Session
    if ($own) { $Session = New-Object IKS.Native.WfpSession([bool]$Dynamic) }
    try {
        $spec = Get-IKSFilterSpec $Plan
        $Session.Begin()
        try {
            $null = $Session.DeleteOurFilters()
            $Session.EnsureProviderAndSublayer()
            foreach ($f in $spec) {
                $layer = [IKS.Native.Ids]::($f.Layer)
                $null = $Session.AddFilter($f.Name, $layer, [bool]$f.Permit, [byte]$f.Weight, (ConvertTo-IKSCond $f))
            }
            $Session.Commit()
        } catch { $Session.Abort(); throw "Applying the kill switch failed, nothing was changed: $($_.Exception.Message)" }
        return $spec.Count
    } finally { if ($own) { $Session.Dispose() } }
}

function Remove-IKSFilters {
    Import-IKSNative
    $s = New-Object IKS.Native.WfpSession($false)
    try { return $s.RemoveAll() } finally { $s.Dispose() }
}

# -1 when it cannot be read (not Administrator: WFP enumeration silently returns nothing)
function Get-IKSFilterCount {
    if (-not (Test-IKSAdmin)) { return -1 }
    try {
        Import-IKSNative
        $s = New-Object IKS.Native.WfpSession($false)
        try { return $s.ListOurFilters().Count } finally { $s.Dispose() }
    } catch { return -1 }
}

# ---- Iran direct routes (help TUN-mode VPNs send Iranian traffic outside the tunnel) ----
function Get-IKSIranCidrs {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in (Read-IKSIranList)) { foreach ($c in (ConvertTo-IKSCidrs $r)) { $out.Add("$(ConvertFrom-IKSInt $c[0])/$($c[1])") } }
    return , $out
}

function Remove-IKSIranRoutes($Settings) {
    if (-not (Test-Path $script:IKS.RoutesFile)) { $Settings.RoutesCount = 0; $Settings.RoutesHash = ''; return 0 }
    Import-IKSNative
    $if = [uint32]$Settings.RoutesIfIndex; $hop = [uint32](ConvertTo-IKSInt $Settings.RoutesNextHop)
    $n = 0
    foreach ($line in Get-Content $script:IKS.RoutesFile) {
        if ($line -match '^([\d\.]+)/(\d+)$') {
            if ([IKS.Native.Routes]::Delete([uint32](ConvertTo-IKSInt $Matches[1]), [byte]$Matches[2], $if, $hop) -eq 0) { $n++ }
        }
    }
    Remove-Item $script:IKS.RoutesFile -Force -ErrorAction SilentlyContinue
    $Settings.RoutesCount = 0; $Settings.RoutesHash = ''; $Settings.RoutesIfIndex = 0; $Settings.RoutesNextHop = ''
    return $n
}

# Idempotent: re-adds only when the network (adapter/gateway) or the Iran list changed,
# or when Windows dropped the routes (e.g. after a reboot - they live in the active store only).
function Sync-IKSIranRoutes($Settings) {
    if (-not $Settings.IranDirect) { $null = Remove-IKSIranRoutes $Settings; return 'off' }
    $phys = Get-IKSPhysicalInterface
    if (-not $phys) { return 'no network' }
    $cidrs = Get-IKSIranCidrs
    $hash = "$($phys.ifIndex)|$($phys.Gateway)|$($cidrs.Count)|$($cidrs[0])|$($cidrs[$cidrs.Count - 1])"
    $probe = $cidrs[[int]($cidrs.Count / 2)]
    $present = [bool](Get-NetRoute -DestinationPrefix $probe -InterfaceIndex $phys.ifIndex -ErrorAction SilentlyContinue)
    if ($Settings.RoutesHash -eq $hash -and $present) { return "unchanged ($($Settings.RoutesCount) routes)" }
    $null = Remove-IKSIranRoutes $Settings
    Import-IKSNative
    $if = [uint32]$phys.ifIndex; $hop = [uint32](ConvertTo-IKSInt $phys.Gateway); $ok = 0; $bad = 0
    foreach ($c in $cidrs) {
        $a, $len = $c -split '/'
        $r = [IKS.Native.Routes]::Add([uint32](ConvertTo-IKSInt $a), [byte]$len, $if, $hop, [uint32]$script:IKS.RouteMetric)
        if ($r -eq 0 -or $r -eq 5010) { $ok++ } else { $bad++ }
    }
    $cidrs | Set-Content -Path $script:IKS.RoutesFile -Encoding ASCII
    $Settings.RoutesIfIndex = $phys.ifIndex; $Settings.RoutesNextHop = $phys.Gateway
    $Settings.RoutesHash = $hash; $Settings.RoutesCount = $ok
    if ($bad) { Write-IKSLog "Iran routes: $bad of $($cidrs.Count) could not be added" 'WARN' }
    return "applied ($ok routes via $($phys.Alias))"
}

# ---- v1 (Windows Firewall rules) migration -------------------------------------
function Remove-IKSLegacy($Settings) {
    $rules = @(Get-NetFirewallRule -Group $script:IKS.LegacyGroup -ErrorAction SilentlyContinue)
    if ($rules) { $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue; Write-IKSLog "Removed $($rules.Count) v1 firewall rules" }
    if ($null -ne $Settings.ProfilesBackup) {
        foreach ($p in $Settings.ProfilesBackup.PSObject.Properties) {
            if ($p.Name -in @('Domain', 'Private', 'Public') -and -not $p.Value) {
                try { Set-NetFirewallProfile -Name $p.Name -Enabled False } catch { }
            }
        }
        $Settings.ProfilesBackup = $null
        Write-IKSLog 'Windows Firewall profiles restored to their pre-v1 state'
    }
    return $rules.Count
}
