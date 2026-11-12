# Actions.ps1 - the user-level operations. Each one is safe to run repeatedly.

function Update-IKSInputs($Settings, [switch]$NoScan) {
    Update-IKSVpnApps $Settings -NoScan:$NoScan
    Update-IKSEndpoints $Settings
    Update-IKSLearnedTunnels $Settings
}

function Invoke-IKSPreview {
    $s = Read-IKSSettings                       # read-only: settings are NOT saved
    Update-IKSInputs $s
    return (Format-IKSPlan (Get-IKSPlan $s) $s)
}

function Invoke-IKSEnable([switch]$WithRevert) {
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        Write-IKSLog "Enable requested (revert=$WithRevert)"
        Update-IKSInputs $s
        $plan = Get-IKSPlan $s                  # throws before any change if inputs are bad
        Save-IKSSettings $s
        if ($WithRevert) { Register-IKSRevertTask }   # safety net armed BEFORE anything changes
        try { $n = Set-IKSFilters $plan }
        catch {
            Unregister-IKSTask $script:IKS.RevertTask
            $s.LastError = "$_"; Save-IKSSettings $s
            Write-IKSLog "Enable failed (nothing changed): $_" 'ERROR'
            throw
        }
        $null = Remove-IKSLegacy $s
        $s.Enabled = $true; $s.AppliedHash = $plan.Hash; $s.AppliedFilters = $n
        $s.AppliedAt = (Get-Date).ToString('s'); $s.LastError = ''
        $routes = try { Sync-IKSIranRoutes $s } catch { Write-IKSLog "Iran routes: $_" 'WARN'; "failed: $($_.Exception.Message)" }
        Save-IKSSettings $s
        Write-IKSLog "Enabled: $n filters, apps: $(($plan.Apps | ForEach-Object { Split-Path $_ -Leaf }) -join ', '); Iran routes: $routes"
        "Protection is ON: $n filters, $($plan.Apps.Count) VPN programs allowed."
    }
}

# -FromRevertTask: called by the IKS-AutoRevert task itself (it must not delete itself while running)
function Invoke-IKSDisable([switch]$FromRevertTask) {
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        $s.Enabled = $false                     # saved first, so the guard never re-applies
        Save-IKSSettings $s
        $n = Remove-IKSFilters
        $null = Remove-IKSIranRoutes $s
        $null = Remove-IKSLegacy $s
        $s.AppliedHash = ''; $s.AppliedFilters = 0
        Save-IKSSettings $s
        if (-not $FromRevertTask) { Unregister-IKSTask $script:IKS.RevertTask }
        $left = Get-IKSFilterCount
        Write-IKSLog "Disabled$(if ($FromRevertTask) { ' by auto-revert' }): $n filters removed, left: $left"
        if ($left -gt 0) { throw "$left filters could not be removed. Use 'Emergency OFF'." }
        'Protection is OFF. All Iran Kill Switch filters and routes were removed.'
    }
}

function Confirm-IKSKeep {
    Unregister-IKSTask $script:IKS.RevertTask
    Write-IKSLog 'User confirmed: keep protection'
    'Protection kept. Auto-undo cancelled.'
}

function Add-IKSVpnApp([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or $Path -notmatch '(?i)\.exe$') { throw "Not a program file: $Path" }
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        $s.VpnApps = @($s.VpnApps | Where-Object { $_.Path -ne $Path.ToLower() }) +
                     [pscustomobject]@{ Path = $Path.ToLower(); Name = [IO.Path]::GetFileNameWithoutExtension($Path); Source = 'user' }
        $s.IgnoredApps = @($s.IgnoredApps | Where-Object { $_ -ne $Path.ToLower() })
        Save-IKSSettings $s
        Write-IKSLog "VPN app added: $Path"
    }
    Invoke-IKSSync
}

function Remove-IKSVpnApp([string]$Path) {
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        $s.VpnApps = @($s.VpnApps | Where-Object { $_.Path -ne $Path.ToLower() })
        $s.IgnoredApps = @(@($s.IgnoredApps) + $Path.ToLower() | Sort-Object -Unique)   # keep it out of future scans
        Save-IKSSettings $s
        Write-IKSLog "VPN app removed: $Path"
    }
    Invoke-IKSSync -NoScan
}

function Set-IKSIranDirect([bool]$On) {
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        $s.IranDirect = $On
        $r = if ($s.Enabled -or -not $On) { Sync-IKSIranRoutes $s } else { 'saved (applies when protection is ON)' }
        Save-IKSSettings $s
        Write-IKSLog "Iran direct = $On ($r)"
        "Iran direct is $(if ($On) { 'ON' } else { 'OFF' }): $r"
    }
}

# Background guard: refresh list/apps/servers and self-heal filters + routes
function Invoke-IKSSync([switch]$NoScan) {
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        $notes = @()
        try { $u = Update-IKSIranList; if ($u.Changed) { $notes += $u.Message } } catch { $notes += "list: $($_.Exception.Message)" }
        try {
            Update-IKSInputs $s -NoScan:$NoScan
            if ($null -ne $s.ProfilesBackup -or @(Get-NetFirewallRule -Group $script:IKS.LegacyGroup -ErrorAction SilentlyContinue).Count) {
                $n = Remove-IKSLegacy $s; $notes += "v1 rules migrated ($n)"
            }
            if ($s.Enabled) {
                $plan = Get-IKSPlan $s
                $count = Get-IKSFilterCount
                $broken = $count -ne [int]$s.AppliedFilters
                if ($broken -or $plan.Hash -ne $s.AppliedHash) {
                    $s.AppliedFilters = Set-IKSFilters $plan
                    $s.AppliedHash = $plan.Hash; $s.AppliedAt = (Get-Date).ToString('s')
                    $notes += $(if ($broken) { "filters repaired ($count -> $($s.AppliedFilters))" } else { 'filters refreshed' })
                }
                $r = Sync-IKSIranRoutes $s
                if ($r -notlike 'unchanged*') { $notes += "Iran routes $r" }
            } elseif ((Get-IKSFilterCount) -gt 0) {
                $null = Remove-IKSFilters; $notes += 'stray filters removed (protection is OFF)'
            }
            $s.LastSyncResult = "OK - $(@(Get-IKSAppPaths $s).Count) VPN apps$(if ($notes) { '; ' + ($notes -join '; ') })"
            $s.LastError = ''
        } catch {
            $s.LastSyncResult = "ERROR - $_"; $s.LastError = "$_"
            Write-IKSLog "Sync error: $_" 'ERROR'
        }
        $s.LastSync = (Get-Date).ToString('s')
        Save-IKSSettings $s
        if ($notes) { Write-IKSLog "Sync: $($notes -join '; ')" }
        $s.LastSyncResult
    }
}

function Get-IKSStatus {
    $s = Read-IKSSettings
    $filters = Get-IKSFilterCount
    $bfe = "$((Get-Service BFE -ErrorAction SilentlyContinue).Status)"
    $tun = @(Get-IKSTunnelAdapters | Where-Object { $_.IPv4 })
    $running = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { "$($_.Path)".ToLower() } catch { '' } } | Where-Object { $_ })
    $apps = @($s.VpnApps | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Path = $_.Path; Source = $_.Source
                           Exists = [bool](Test-Path -LiteralPath $_.Path -PathType Leaf); Running = $running -contains $_.Path.ToLower() } })
    $proxy = Get-IKSLocalProxy
    $guard = Get-IKSTaskInfo $script:IKS.GuardTask
    $revert = Get-IKSTaskInfo $script:IKS.RevertTask
    $list = Get-IKSListInfo
    $legacy = @(Get-NetFirewallRule -Group $script:IKS.LegacyGroup -ErrorAction SilentlyContinue).Count

    $admin = Test-IKSAdmin                      # without admin, filters and SYSTEM tasks cannot be read: unknown, not missing
    $problems = @()
    if ($s.Enabled -and $filters -eq 0) { $problems += 'Filters are missing - the guard will repair them, or press Turn ON again.' }
    if ($bfe -ne 'Running') { $problems += 'Base Filtering Engine service is not running.' }
    if ($admin -and -not $guard.Exists) { $problems += 'Background guard is not installed - run Setup.cmd.' }
    if (-not @($apps | Where-Object Exists)) { $problems += 'No VPN program found yet - start your VPN app, then press Refresh, or add it with "VPN apps".' }
    if ($s.LastError) { $problems += "Last error: $($s.LastError)" }

    $mode = if ($tun) { 'tun' } elseif ($proxy -and @($apps | Where-Object Running)) { 'proxy' } else { 'none' }
    [pscustomobject]@{
        Version = $script:IKS.Version; Author = $script:IKS.Author; Enabled = [bool]$s.Enabled; Filters = $filters
        Installed = (Test-Path (Join-Path $script:IKS.InstallDir 'IKS.ps1'))
        VpnApps = $apps; VpnMode = $mode; Proxy = $proxy
        Tunnel = $(if ($tun) { "$($tun[0].Name) $($tun[0].IPv4 -join ',')" } else { '' })
        IranDirect = [bool]$s.IranDirect; IranRoutes = [int]$s.RoutesCount
        IranRanges = $list.Ranges; ListUpdated = $list.Updated; ListSource = $list.Source
        Endpoints = @($s.EndpointCache).Count; LegacyRules = $legacy
        PendingChildren = @(Get-IKSPendingChildren $s).Count     # helpers of allowed apps, not allowed yet
        GuardInstalled = $(if ($admin) { $guard.Exists } else { $null }); GuardLastRun = $(if ($guard.LastRun) { $guard.LastRun.ToString('yyyy-MM-dd HH:mm') } else { '' })
        LastSyncResult = $s.LastSyncResult
        RevertPending = [bool]($revert.Exists -and $revert.NextRun -and $revert.NextRun -gt (Get-Date))
        Healthy = (-not ($problems | Where-Object { $_ -notlike 'No VPN program*' })); Problems = $problems
    }
}
