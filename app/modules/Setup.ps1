# Setup.ps1 - install / update / uninstall.
# Install = Update: re-running Setup copies new code, keeps state\ (settings, logs,
# allowed servers) and the newer Iran list, migrates v1, then re-applies if enabled.

function Test-IKSRequirements {
    $os = [Environment]::OSVersion.Version
    $bad = @()
    if ($os.Major -lt 10 -or $os.Build -lt 14393) { $bad += "Windows 10 version 1607 or newer (or Windows 11) is required; this is $os." }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { $bad += 'Windows PowerShell 5.1 is required.' }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { $bad += 'PowerShell is locked down (Constrained Language Mode) by a company policy.' }
    foreach ($svc in @(@{ N = 'BFE'; D = 'Base Filtering Engine' }, @{ N = 'Schedule'; D = 'Task Scheduler' })) {
        if ("$((Get-Service $svc.N -ErrorAction SilentlyContinue).Status)" -ne 'Running') { $bad += "Windows service '$($svc.D)' is not running." }
    }
    if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) { $bad += 'NetTCPIP PowerShell module is missing.' }
    return $bad
}

function New-IKSShortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$Icon) {
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $sc.TargetPath = $Target; $sc.Arguments = $Arguments; $sc.IconLocation = $Icon
    $sc.WorkingDirectory = $script:IKS.InstallDir; $sc.Save()
}

function Get-IKSMenuDir { return Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Iran Kill Switch' }
function Get-IKSDesktopLink { return Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Iran Kill Switch.lnk' }

function Invoke-IKSInstall {
    $bad = Test-IKSRequirements
    if ($bad) { throw ($bad -join ' ') }
    $src = $script:IKS.AppDir
    $dst = $script:IKS.InstallDir
    Invoke-IKSLocked {
        $prev = if (Test-Path (Join-Path $dst 'VERSION')) { (Get-Content (Join-Path $dst 'VERSION') -TotalCount 1).Trim() } else { '' }
        foreach ($d in 'modules', 'native', 'data', 'state', 'bin') { New-Item -ItemType Directory -Force (Join-Path $dst $d) | Out-Null }
        if ($src -ne $dst) {
            # code: replaced completely
            foreach ($d in 'modules', 'native') { Get-ChildItem (Join-Path $dst $d) -File | Remove-Item -Force }
            Copy-Item (Join-Path $src 'modules\*.ps1') (Join-Path $dst 'modules') -Force
            Copy-Item (Join-Path $src 'native\*.cs') (Join-Path $dst 'native') -Force
            foreach ($f in 'IKS.ps1', 'IKS.Gui.ps1', 'VERSION', 'Emergency-Off.cmd') { Copy-Item (Join-Path $src $f) (Join-Path $dst $f) -Force }
            # data: keep whichever Iran list is newer
            $srcList = Join-Path $src 'data\ir-ipv4.txt'; $dstList = Join-Path $dst 'data\ir-ipv4.txt'
            $si = Get-IKSListInfo $srcList; $di = Get-IKSListInfo $dstList
            if ($di.Ranges -eq 0 -or (Get-IKSAgeDays $si.Updated) -lt (Get-IKSAgeDays $di.Updated)) { Copy-Item $srcList $dstList -Force }
            Get-ChildItem $dst -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        }
        Set-IKSRoot $dst                     # from here on, work on the installed copy
        $null = Build-IKSNative $dst
        $exe = Build-IKSLauncher $dst
        Get-ChildItem (Join-Path $dst 'modules') -Filter 'Firewall.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force   # v1 module
        $old = Join-Path $dst 'state\extra-servers.txt'                                                                    # v1 file name
        if ((Test-Path $old) -and -not (Test-Path $script:IKS.EndpointsFile)) { Move-Item $old $script:IKS.EndpointsFile }
        if (-not (Test-Path $script:IKS.EndpointsFile)) {
            @('# Iran Kill Switch - allowed servers (optional).',
              '# VPN programs are allowed automatically. Use this only for a server that is reached',
              '# by a program you do not want to allow fully, e.g. the built-in Windows VPN (L2TP/IKEv2/SSTP)',
              '# or a SOCKS5 proxy configured directly in a browser extension.',
              '# One per line: an IP, a CIDR, a domain, or a share link (vless:// vmess:// trojan:// ss:// socks5://).', '') |
                Set-Content $script:IKS.EndpointsFile -Encoding UTF8
        }
        # shortcuts: the windowless launcher
        $menu = Get-IKSMenuDir
        New-Item -ItemType Directory -Force $menu | Out-Null
        Get-ChildItem $menu -Filter *.lnk -ErrorAction SilentlyContinue | Remove-Item -Force
        New-IKSShortcut (Get-IKSDesktopLink) $exe '' "$exe,0"
        New-IKSShortcut (Join-Path $menu 'Iran Kill Switch.lnk') $exe '' "$exe,0"
        New-IKSShortcut (Join-Path $menu 'Emergency OFF.lnk') (Join-Path $dst 'Emergency-Off.cmd') '' "$env:SystemRoot\System32\shell32.dll,131"
        # Apps & features entry
        $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\IranKillSwitch'
        New-Item -Path $key -Force | Out-Null
        $vals = @{ DisplayName = 'Iran Kill Switch'; DisplayVersion = $script:IKS.Version; Publisher = $script:IKS.Author
                   InstallLocation = $dst; DisplayIcon = "$exe,0"
                   UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dst 'IKS.ps1')`" -Action Uninstall" }
        foreach ($k in $vals.Keys) { Set-ItemProperty -Path $key -Name $k -Value $vals[$k] }
        Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord
        Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord
        Register-IKSGuardTask
        Write-IKSLog "Installed $($script:IKS.Version)$(if ($prev) { " (update from $prev)" })"
    }
    # Detect VPN programs now, migrate v1, and re-apply if protection was on.
    $null = Invoke-IKSSync
    "Installed version $($script:IKS.Version) to $dst."
}

function Invoke-IKSUninstall([switch]$RestoreOriginal) {
    try { $null = Invoke-IKSDisable } catch {
        Write-IKSLog "Uninstall: disable failed, forcing removal: $_" 'WARN'
        try { $null = Remove-IKSFilters } catch { }
    }
    try { $s = Read-IKSSettings; $null = Remove-IKSLegacy $s } catch { }
    Unregister-IKSTask $script:IKS.GuardTask
    Unregister-IKSTask $script:IKS.RevertTask
    $keep = Join-Path $env:ProgramData 'IranKillSwitch-backup'
    $bk = Join-Path $script:IKS.InstallDir 'state\backup'
    if (Test-Path $bk) { New-Item -ItemType Directory -Force $keep | Out-Null; Copy-Item "$bk\*" $keep -Force }
    $msg = @()
    if ($RestoreOriginal) {
        $orig = Join-Path $keep 'firewall-original.wfw'
        if (Test-Path $orig) { $null = & netsh advfirewall import "$orig" 2>&1; $msg += 'Original Windows Firewall policy restored.' }
        else { $msg += 'Windows Firewall was never changed by version 2; nothing to restore.' }
    }
    Remove-Item (Get-IKSMenuDir) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Get-IKSDesktopLink) -Force -ErrorAction SilentlyContinue
    Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\IranKillSwitch' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:IKS.InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    $left = Get-IKSFilterCount
    $msg += "Uninstalled. Filters left: $(if ($left -lt 0) { 'unknown' } else { $left })."
    $msg -join ' '
}
