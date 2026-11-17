# Actions.ps1 - the user-level operations. Each one is safe to run repeatedly.

function Update-IKSInputs($Settings, [switch]$NoScan) {
    Update-IKSVpnApps $Settings -NoScan:$NoScan
    Update-IKSEndpoints $Settings
    Update-IKSDirectSites $Settings
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

# The checks after "Turn ON" can take a long time on a slow network (DNS timeouts). Re-arm the
# safety net when they finish, so the user always gets the full window to confirm.
# Returns the new undo time, or $null when the auto-revert already turned protection off.
function Reset-IKSRevertTimer {
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        if (-not $s.Enabled) { return $null }
        Register-IKSRevertTask
        $next = (Get-IKSTaskInfo $script:IKS.RevertTask).NextRun
        if (-not $next) { $next = (Get-Date).AddSeconds($script:IKS.RevertSeconds) }
        Write-IKSLog "Auto-undo timer re-armed: $($next.ToString('s'))"
        $next
    }
}

# After Enable: keep protection without asking when the self-test proves the PC is not cut off
# (no check failed AND an Iranian site was reached directly). Anything else -> ask the user.
function Test-IKSAutoKeep($Rows) {
    $rows = @($Rows | Where-Object { $_ })
    if (-not $rows) { return $false }
    if (@($rows | Where-Object { $_.Result -eq 'FAIL' }).Count) { return $false }
    return [bool]@($rows | Where-Object { $_.Test -eq 'Iranian sites work directly' -and $_.Result -eq 'PASS' }).Count
}

function Confirm-IKSKeep([switch]$Auto) {
    Unregister-IKSTask $script:IKS.RevertTask
    Write-IKSLog $(if ($Auto) { 'Self-test passed: protection kept automatically' } else { 'User confirmed: keep protection' })
    'Protection kept. Auto-undo cancelled.'
}

# PowerShell arguments a launcher uses, or $null when it does not run PowerShell itself.
# Relative paths become absolute (%~dp0, $PSScriptRoot, .\x.ps1); %* is dropped.
function Get-IKSPowerShellArgs([string]$Path, [int]$Depth = 0) {
    if ($Depth -gt 3 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath; $dir = Split-Path $full -Parent
    switch -regex ([IO.Path]::GetExtension($full).ToLower()) {
        '^\.ps1$' { return "-NoProfile -ExecutionPolicy Bypass -File `"$full`"" }
        '^\.(bat|cmd)$' {
            foreach ($line in [IO.File]::ReadAllLines($full)) {
                if ($line -match '(?i)\b(?:powershell|pwsh)(?:\.exe)?"?\s+(.*)$') {
                    $a = $Matches[1] -replace '(?i)%~dp0\\?', ($dir + '\') -replace '\s*%\*', ''
                    return $a.Trim()
                }
            }
            return $null
        }
        '^\.lnk$' {
            try { $l = (New-Object -ComObject WScript.Shell).CreateShortcut($full) } catch { return $null }
            if ("$($l.TargetPath)" -match '(?i)\\(powershell|pwsh)\.exe$') { return "$($l.Arguments)" }
            return Get-IKSPowerShellArgs $l.TargetPath ($Depth + 1)
        }
    }
    return $null
}

# A tool written in PowerShell (no .exe of its own, e.g. HubDesk.bat -> Start.ps1): give it a
# PRIVATE copy of powershell.exe that only this tool uses, allow that copy, and put a shortcut on
# the desktop that starts the tool with it. Windows' own powershell.exe stays blocked.
function New-IKSScriptLauncher([string]$Path, [string]$ShortcutDir = [Environment]::GetFolderPath('Desktop')) {
    $psArgs = Get-IKSPowerShellArgs $Path
    if (-not $psArgs) { return $null }
    $name = ([IO.Path]::GetFileNameWithoutExtension($Path) -replace '[^\w\-. ]', '').Trim()
    if (-not $name) { $name = 'tool' }
    $dir = Join-Path $script:IKS.StateDir 'launchers'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir "$name.exe"
    Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $exe -Force
    $lnk = Join-Path $ShortcutDir "$name (Kill Switch).lnk"
    $w = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $w.TargetPath = $exe; $w.Arguments = $psArgs; $w.WorkingDirectory = (Split-Path (Resolve-Path -LiteralPath $Path).ProviderPath -Parent)
    $w.Description = "$name - allowed by Iran Kill Switch"; $w.WindowStyle = 7; $w.Save()
    return [pscustomobject]@{ Exe = $exe.ToLower(); Shortcut = $lnk; Args = $psArgs }
}

# Accepts a program (.exe) or a launcher (.bat/.cmd/.ps1/.lnk): for a launcher, the programs it
# starts are allowed (never PowerShell/cmd themselves). A pure-PowerShell tool gets its own
# private PowerShell copy + desktop shortcut.
function Add-IKSVpnApp([string]$Path, [string]$ShortcutDir = [Environment]::GetFolderPath('Desktop')) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or $Path -notmatch '(?i)\.(exe|bat|cmd|ps1|lnk)$') { throw "Not a program, script or shortcut: $Path" }
    $isExe = $Path -match '(?i)\.exe$'
    if ($isExe -and (Test-IKSSystemPath $Path)) {
        throw "$(Split-Path $Path -Leaf) is part of Windows. Allowing it would let every script and tool on this PC bypass the kill switch with your real IP. Add the VPN program itself instead."
    }
    $exes = if ($isExe) { @($Path.ToLower()) } else { @(Get-IKSScriptPrograms $Path) }
    $launcher = $null
    if (-not $exes) {
        $launcher = New-IKSScriptLauncher $Path $ShortcutDir
        if ($launcher) { $exes = @($launcher.Exe) }
    }
    if (-not $exes) {
        throw "No VPN program was found inside $(Split-Path $Path -Leaf). It only starts Windows tools (PowerShell, cmd...), which can never be allowed. Add the .exe it runs instead."
    }
    $via = if ($isExe) { '' } else { " (via $(Split-Path $Path -Leaf))" }
    Invoke-IKSLocked {
        $s = Read-IKSSettings
        foreach ($e in $exes) {
            $s.VpnApps = @($s.VpnApps | Where-Object { $_.Path -ne $e }) +
                         [pscustomobject]@{ Path = $e; Name = [IO.Path]::GetFileNameWithoutExtension($e) + $via; Source = 'user' }
            $s.IgnoredApps = @($s.IgnoredApps | Where-Object { $_ -ne $e })
        }
        Save-IKSSettings $s
        Write-IKSLog "VPN app added: $Path$(if (-not $isExe) { ' -> ' + ($exes -join ', ') })"
    }
    $null = Invoke-IKSSync
    if ($launcher) { "$(Split-Path $Path -Leaf) is a PowerShell tool. Start it from the new desktop shortcut '$(Split-Path $launcher.Shortcut -Leaf)' - only that copy may connect." }
    else { "Allowed: $(($exes | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')" }
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
        $r = if ($s.Enabled) { Sync-IKSIranRoutes $s }
             elseif (-not $On) { $null = Remove-IKSIranRoutes $s; 'off' }        # routes exist only while protection is ON
             else { 'saved (applies when protection is ON)' }
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

# Newer release on GitHub? Read-only, sends nothing about this PC. $null = up to date or offline.
function Get-IKSUpdateInfo {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $script:IKS.ReleasesApi -TimeoutSec 10 -UseBasicParsing -Headers @{ 'User-Agent' = 'IranKillSwitch' }
        $tag = "$($r.tag_name)".Trim().TrimStart('v', 'V')
        if ($tag -match '^\d+(\.\d+){1,3}$' -and [version]$tag -gt [version]$script:IKS.Version) {
            $url = "$($r.html_url)"
            if ($url -notlike 'https://github.com/saateon/iran-kill-switch/*') { $url = $script:IKS.ReleasesPage }   # only ever open our own page
            return [pscustomobject]@{ Version = $tag; Url = $url }
        }
    } catch { }
    return $null
}

function Get-IKSStatus {
    $s = Read-IKSSettings
    $filters = Get-IKSFilterCount
    $bfe = "$((Get-Service BFE -ErrorAction SilentlyContinue).Status)"
    $tun = @(Get-IKSTunnelAdapters | Where-Object { $_.IPv4 })
    $running = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { "$($_.Path)".ToLower() } catch { '' } } | Where-Object { $_ })
    $apps = @($s.VpnApps | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Path = $_.Path; Source = $_.Source
                           Exists = $(try { [bool](Test-Path -LiteralPath $_.Path -PathType Leaf) } catch { $true }); Running = $running -contains $_.Path.ToLower() } })
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
        VpnClient = $(if ($mode -ne 'none') { Get-IKSActiveVpnClient $(if ($mode -eq 'proxy') { $proxy } else { '' }) } else { '' })
        SystemProxy = $(if ($mode -eq 'proxy') { $sp = Get-IKSSystemProxy; [bool]($sp.Enabled -or $sp.Pac) } else { $null })
        Tunnel = $(if ($tun) { "$($tun[0].Name) $($tun[0].IPv4 -join ',')" } else { '' })
        IranDirect = [bool]$s.IranDirect; IranRoutes = [int]$s.RoutesCount
        DirectSites = $(($dh = Get-IKSDirectHosts) | Out-Null; @($dh | Where-Object { -not ($_ -like 'www.*' -and $dh.Contains($_.Substring(4))) }).Count)   # www. twins not counted
        IranRanges = $list.Ranges; ListUpdated = $list.Updated; ListSource = $list.Source
        Endpoints = @($s.EndpointCache).Count; LegacyRules = $legacy
        PendingChildren = @(Get-IKSPendingChildren $s).Count     # helpers of allowed apps, not allowed yet
        GuardInstalled = $(if ($admin) { $guard.Exists } else { $null }); GuardLastRun = $(if ($guard.LastRun) { $guard.LastRun.ToString('yyyy-MM-dd HH:mm') } else { '' })
        LastSyncResult = $s.LastSyncResult
        RevertPending = [bool]($revert.Exists -and $revert.NextRun -and $revert.NextRun -gt (Get-Date))
        Healthy = (-not ($problems | Where-Object { $_ -notlike 'No VPN program*' })); Problems = $problems
    }
}
