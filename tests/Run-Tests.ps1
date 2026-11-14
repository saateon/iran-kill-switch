#Requires -Version 5.1
<#
  Test suite. Offline part: no admin, no system changes.
    powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
    powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 -WfpLive [-Out f.txt]   # admin, protection OFF:
        the REAL filter set is installed in a DYNAMIC WFP session (auto-removed) and checked with live sockets.
#>
param([switch]$WfpLive, [string]$Out = '')
$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
. (Join-Path $root 'IKS.ps1')
# Isolate state: tests never touch the real state folder
$tmpState = Join-Path ([IO.Path]::GetTempPath()) "iks-test-$PID"
$script:IKS.StateDir = $tmpState; $script:IKS.SettingsFile = "$tmpState\settings.json"; $script:IKS.LogFile = "$tmpState\iks.log"
$script:IKS.EndpointsFile = "$tmpState\allowed.txt"; $script:IKS.RoutesFile = "$tmpState\routes.txt"; $script:IKS.DirectFile = "$tmpState\direct.txt"

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Say([string]$m, [string]$c = 'Gray') { if ($Out) { Add-Content -Path $Out -Value $m -Encoding UTF8 } else { Write-Host $m -ForegroundColor $c } }
function Check([string]$Name, [scriptblock]$Cond) {
    try { $ok = [bool](& $Cond) } catch { $ok = $false; $Name += "  ($($_.Exception.Message))" }
    if ($ok) { $script:pass++; Say "  PASS  $Name" Green } else { $script:fail++; Say "  FAIL  $Name" Red }
}
function Skip([string]$Name, [string]$Why) { $script:skip++; Say "  SKIP  $Name ($Why)" Yellow }
function Rng([string]$t) { return , (ConvertTo-IKSRange $t) }
function L([object[]]$pairs) { $l = New-IKSRangeList; foreach ($p in $pairs) { $l.Add([long[]]$p) }; return , $l }
$MAX = [long]4294967295
$curl = "$env:SystemRoot\System32\curl.exe"
if ($Out) { Set-Content -Path $Out -Value "Iran Kill Switch tests $(Get-Date -f s)" -Encoding UTF8 }

Say "`n[source files]"
foreach ($f in Get-ChildItem (Split-Path -Parent $PSScriptRoot) -Recurse -Include *.ps1, *.cmd, *.cs -File) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    Check "ASCII only: $($f.Name)" { -not ($bytes | Where-Object { $_ -gt 127 }) }
    if ($f.Extension -eq '.ps1') {
        $errs = $null; $null = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        Check "parses: $($f.Name)" { -not $errs }
    }
}
Check "VERSION is semver ($($script:IKS.Version))" { $script:IKS.Version -match '^\d+\.\d+\.\d+$' }

Say "`n[native helper]"
Check 'IksNative.cs compiles and loads' { Import-IKSNative; [bool]('IKS.Native.WfpSession' -as [type]) }
Check 'native version matches VERSION' { [IKS.Native.Ids]::Version -eq $script:IKS.Version }
$phys = Get-IKSPhysicalInterface
if ($phys) { Check "route struct layout (default route = $($phys.ifIndex) $($phys.Gateway))" { [IKS.Native.Routes]::DefaultRouteProbe() -eq "$($phys.ifIndex) $($phys.Gateway)" } }
else { Skip 'route struct layout' 'no default route' }

Say "`n[IpMath]"
Check 'CIDR /8'            { $r = Rng '10.0.0.0/8'; $r[0] -eq 167772160 -and $r[1] -eq 184549375 }
Check 'CIDR normalised'    { (Rng '1.2.3.4/24')[0] -eq (ConvertTo-IKSInt '1.2.3.0') }
Check 'range a-b'          { $r = Rng '1.1.1.1-1.1.1.9'; $r[1] - $r[0] -eq 8 }
Check 'invalid rejected'   { $null -eq (Rng '1.2.3.256') -and $null -eq (Rng '1.2.3.4/33') -and $null -eq (Rng 'x') -and $null -eq (Rng '9.9.9.9-1.1.1.1') }
Check 'merge'              { $m = Merge-IKSRanges (L @(@(20, 30), @(1, 5), @(6, 10), @(3, 4))); $m.Count -eq 2 -and $m[0][1] -eq 10 -and $m[1][1] -eq 30 }
Check 'complement + set = everything, disjoint (random)' {
    $l = New-IKSRangeList
    1..300 | ForEach-Object { $s = [long](Get-Random -Maximum 4294000000); $l.Add([long[]]@($s, $s + (Get-Random -Maximum 5000000))) }
    $m = Merge-IKSRanges $l; $c = Get-IKSComplement $m
    ((Get-IKSAddressCount $m) + (Get-IKSAddressCount $c)) -eq ($MAX + 1) -and (Merge-IKSRanges (L (@($m) + @($c)))).Count -eq 1
}
Check 'binary search = linear search (random)' {
    $m = Merge-IKSRanges (L @(@(100, 200), @(5000, 5000), @(70000, 90000)))
    -not (@(99, 100, 200, 201, 5000, 5001, 70000, 90000, 90001) + @(1..200 | ForEach-Object { [long](Get-Random -Maximum 100000) }) | Where-Object {
        $n = $_; (Test-IKSInRanges (ConvertFrom-IKSInt $n) $m) -ne [bool]($m | Where-Object { $n -ge $_[0] -and $n -le $_[1] }) })
}
Check 'range -> CIDRs: exact cover, aligned blocks (random)' {
    $ok = $true
    foreach ($i in 1..200) {
        $s = [long](Get-Random -Maximum 4000000000); $e = $s + (Get-Random -Maximum 3000000)
        $cs = ConvertTo-IKSCidrs ([long[]]@($s, $e)); [long]$next = $s
        foreach ($c in $cs) { $size = [long][math]::Pow(2, 32 - $c[1]); if ($c[0] -ne $next -or ($c[0] % $size) -ne 0) { $ok = $false }; $next = $c[0] + $size }
        if ($next -ne $e + 1) { $ok = $false }
    }
    $ok
}
Check 'range -> CIDRs: known cases' { $a = ConvertTo-IKSCidrs ([long[]]@(0, $MAX)); $b = ConvertTo-IKSCidrs (Rng '1.1.1.1-1.1.1.4'); $a.Count -eq 1 -and $a[0][1] -eq 0 -and $b.Count -eq 3 }

Say "`n[allowed servers parsing]"
$map = @{}
foreach ($l in 'vless://id@1.2.3.4:443?x#n', 'trojan://p@Trojan.Example.com:8443#t', 'socks5://9.8.7.6:1080', 'tuic://u:p@tuic.example.io:443',
               ('vmess://' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"add":"vm.example.org"}')).TrimEnd('=')),
               'ss://YWVzLTI1Ni1nY206cHc@sip002.example.net:8388#t', 'hy2://pw@[2001:db8::1]:443', '203.0.113.0/24', 'my.server.io', '# comment.example.com') {
    Add-IKSShareLink $map $l 't'
}
Check 'vless / trojan / socks5 / tuic / vmess / ss' { $map.ContainsKey('1.2.3.4') -and $map.ContainsKey('trojan.example.com') -and $map.ContainsKey('9.8.7.6') -and $map.ContainsKey('tuic.example.io') -and $map.ContainsKey('vm.example.org') -and $map.ContainsKey('sip002.example.net') }
Check 'CIDR and bare domain kept; IPv6 and comments skipped' { $map.ContainsKey('203.0.113.0/24') -and $map.ContainsKey('my.server.io') -and -not ($map.Keys | Where-Object { $_ -match ':|comment' }) }

Say "`n[direct sites]"
New-IKSDirectFile
Add-Content $script:IKS.DirectFile 'https://Bank.Example.com:8443/login?a=1', '*.cdn.example.net', '198.51.100.7', '203.0.113.9/24', 'not a host!', '127.0.0.1'
$dh = Get-IKSDirectHosts
Check 'direct sites: URL/wildcard -> host, www twin added, IP + CIDR kept, junk and loopback skipped' {
    ($dh -join ',') -eq 'bank.example.com,www.bank.example.com,cdn.example.net,www.cdn.example.net,198.51.100.7,203.0.113.9/24'
}
$ds = @{ DirectCache = @([pscustomobject]@{ Host = '198.51.100.7'; Ip = '198.51.100.7'; LastSeen = (Get-Date).ToString('s') },
                         [pscustomobject]@{ Host = '203.0.113.9/24'; Ip = '203.0.113.9/24'; LastSeen = (Get-Date).ToString('s') }); IranDirect = $true }
Check 'direct sites -> clean CIDRs for routes (host bits cleared)' { ((Get-IKSDirectCidrs $ds) -join ',') -eq '198.51.100.7/32,203.0.113.0/24' }
Check 'direct sites are allowed outside the tunnel; neighbours are not' {
    $p = Get-IKSPlan $ds
    (Test-IKSInRanges '198.51.100.7' $p.Allowed) -and (Test-IKSInRanges '203.0.113.200' $p.Allowed) -and -not (Test-IKSInRanges '198.51.100.8' $p.Allowed)
}
Check 'route list = Iran CIDRs + direct sites, each item one CIDR' {
    $rc = Get-IKSRouteCidrs $ds (Get-IKSDirectCidrs $ds)
    $rc.Count -eq ((Get-IKSIranCidrs).Count + 2) -and -not ($rc | Where-Object { $_ -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$' }) -and $rc[$rc.Count - 1] -eq '203.0.113.0/24'
}
Check 'proxy bypass entries: names/IPs kept, /24 -> wildcard, odd CIDR skipped' {
    ((ConvertTo-IKSBypassEntries @('a.com', 'www.a.com', '198.51.100.7', '203.0.113.9/24', '10.1.0.0/20', '1.2.3.4/32')) -join ';') -eq 'a.com;www.a.com;198.51.100.7;203.0.113.*;1.2.3.4'
}
Check 'proxy bypass merge: re-adds removed entries, keeps the VPN list, drops stale ones, removes all when OFF' {
    $vpn = 'localhost;127.*;192.168.*;<local>'
    ((Merge-IKSProxyOverride $vpn @('a.com') @('a.com', 'b.com')) -eq "a.com;b.com;$vpn") -and
    ((Merge-IKSProxyOverride "a.com;old.com;$vpn" @('a.com', 'old.com') @('a.com')) -eq "a.com;$vpn") -and
    ((Merge-IKSProxyOverride "a.com;$vpn" @('a.com') @()) -eq $vpn) -and
    ((Merge-IKSProxyOverride '' @() @('a.com')) -eq 'a.com')
}
Remove-Item $script:IKS.DirectFile -Force

Say "`n[Iran list]"
$info = Get-IKSListInfo
Check "bundled list present ($($info.Ranges) ranges, $($info.Updated))" { $info.Ranges -ge 300 }
$iran = Read-IKSIranList
Check "address count plausible ($(Get-IKSAddressCount $iran))" { $a = Get-IKSAddressCount $iran; $a -gt 4000000 -and $a -lt 40000000 }
Check 'Iranian IPs inside, foreign outside' { (Test-IKSInRanges '178.22.122.100' $iran) -and (Test-IKSInRanges '2.176.0.1' $iran) -and -not (Test-IKSInRanges '8.8.8.8' $iran) }
Check "route CIDRs cover the Iran list exactly ($((Get-IKSIranCidrs).Count) routes)" {
    $l = New-IKSRangeList; foreach ($c in (Get-IKSIranCidrs)) { $l.Add((ConvertTo-IKSRange $c)) }
    (Get-IKSAddressCount (Merge-IKSRanges $l)) -eq (Get-IKSAddressCount $iran)
}

Say "`n[VPN app detection]"
$found = Find-IKSVpnApps
Check "detection returns only existing catalog or vendor-named programs ($($found.Count) found)" {
    -not ($found.Keys | Where-Object { $leaf = Split-Path $_ -Leaf
        -not (Test-Path -LiteralPath $_) -or $leaf -match '(?i)^unins' -or
        ($script:IKS.VpnCatalog -notcontains $leaf -and $leaf -notmatch $script:IKS.VendorRegex) })
}
Check 'Hiddify TUN helper (HiddifyAdmin.exe) is a known VPN program' { $script:IKS.VpnCatalog -contains 'HiddifyAdmin.exe' }
# Stub the scanner to test merge rules without depending on this PC
function Find-IKSVpnApps { return @{ $curl.ToLower() = 'curl'; 'c:\nowhere\ghost.exe' = 'ghost' } }
$st = @{ VpnApps = @([pscustomobject]@{ Path = 'c:\mine\my.exe'; Name = 'my'; Source = 'user' }); IgnoredApps = @() }
Update-IKSVpnApps $st
Check 'scan adds auto apps and keeps user apps' { ($st.VpnApps.Path -contains $curl.ToLower()) -and ($st.VpnApps.Path -contains 'c:\mine\my.exe') }
Check 'only existing files reach the filters' { $p = Get-IKSAppPaths $st; ($p -contains $curl.ToLower()) -and ($p -notcontains 'c:\mine\my.exe') -and ($p -notcontains 'c:\nowhere\ghost.exe') }
$st.VpnApps = @($st.VpnApps | Where-Object { $_.Path -ne $curl.ToLower() }); $st.IgnoredApps = @($curl.ToLower())
Update-IKSVpnApps $st
Check 'an app removed by the user is not re-added by the next scan' { $st.VpnApps.Path -notcontains $curl.ToLower() }
Remove-Item Function:\Find-IKSVpnApps; . (Join-Path $root 'modules\Discovery.ps1')

Say "`n[helper processes of allowed apps]"
$hd = Join-Path ([IO.Path]::GetTempPath()) "iks-child-$PID"; New-Item -ItemType Directory -Force $hd | Out-Null
$parentExe = Join-Path $hd 'vpnparent.exe'; $childExe = Join-Path $hd 'vpnhelper.exe'
Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $parentExe; Copy-Item "$env:SystemRoot\System32\PING.EXE" $childExe
$pp = Start-Process $parentExe -ArgumentList "-NoProfile -Command `"& '$childExe' -n 8 127.0.0.1 | Out-Null`"" -PassThru -WindowStyle Hidden
Start-Sleep 3
try {
    $kids = Find-IKSChildApps @($parentExe)
    Check 'helper started by an allowed app is found' { $kids.ContainsKey($childExe.ToLower()) }
    Check "Windows' own programs (conhost etc.) are never followed" { -not ($kids.Keys | Where-Object { $_.StartsWith($env:SystemRoot.ToLower()) }) }
    $st = @{ VpnApps = @([pscustomobject]@{ Path = $parentExe.ToLower(); Name = 'vpnparent'; Source = 'user' }); IgnoredApps = @() }
    Check 'pending helper reported before sync' { (Get-IKSPendingChildren $st) -contains $childExe.ToLower() }
    Update-IKSVpnApps $st -NoScan
    Check 'sync (even without a scan) adds the helper as "child"' { ($st.VpnApps | Where-Object { $_.Path -eq $childExe.ToLower() }).Source -eq 'child' -and @(Get-IKSPendingChildren $st).Count -eq 0 }
} finally { Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue; Get-Process vpnhelper -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1; Remove-Item $hd -Recurse -Force -ErrorAction SilentlyContinue }

Say "`n[plan + filter spec]"
$s = @{ VpnApps = @([pscustomobject]@{ Path = $curl.ToLower(); Name = 'curl'; Source = 'user' })
        EndpointCache = @([pscustomobject]@{ Host = 'x'; Ip = '203.0.113.5'; LastSeen = (Get-Date).ToString('s') })
        LearnedTunnels = @([pscustomobject]@{ Ip = '10.66.66.2'; LastSeen = (Get-Date).ToString('s') }); IranDirect = $true }
$plan = Get-IKSPlan $s
$spec = Get-IKSFilterSpec $plan
Check 'allowed = Iran + LAN/special + allowed servers; foreign not allowed' {
    (Test-IKSInRanges '178.22.122.100' $plan.Allowed) -and (Test-IKSInRanges '192.168.1.1' $plan.Allowed) -and (Test-IKSInRanges '255.255.255.255' $plan.Allowed) -and
    (Test-IKSInRanges '203.0.113.5' $plan.Allowed) -and -not (Test-IKSInRanges '203.0.113.6' $plan.Allowed) -and -not (Test-IKSInRanges '8.8.8.8' $plan.Allowed) -and -not (Test-IKSInRanges '1.1.1.1' $plan.Allowed)
}
Check 'learned TAP address exempt as local address' { (Test-IKSInRanges '10.66.66.2' $plan.Tunnels) -and -not (Test-IKSInRanges '10.66.66.3' $plan.Tunnels) }
Check 'every layer: loopback first, block last (weight 1)' {
    $ok = $true
    foreach ($layer in 'ConnectV4', 'AcceptV4', 'ConnectV6', 'AcceptV6') {
        $f = @($spec | Where-Object { $_.Layer -eq $layer })
        if ($f[0].Kind -ne 'loopback' -or $f[-1].Kind -ne 'block' -or $f[-1].Weight -ne 1 -or @($f | Where-Object { -not $_.Permit }).Count -ne 1) { $ok = $false }
    }
    $ok
}
Check 'VPN app + tunnel types on every layer' { @($spec | Where-Object { $_.Kind -eq 'app' }).Count -eq 4 -and @($spec | Where-Object { $_.Kind -eq 'iftype' }).Count -eq 4 }
Check 'IPv6 layers never allow Iran/foreign ranges (LAN prefixes only)' { -not ($spec | Where-Object { $_.Layer -like '*V6' -and $_.Kind -in 'remote', 'local' }) }
Check "range chunks <= $($script:IKS.ChunkSize) and cover the whole allowed set" {
    $r = @($spec | Where-Object { $_.Layer -eq 'ConnectV4' -and $_.Kind -eq 'remote' })
    -not ($r | Where-Object { $_.Ranges.Count -gt $script:IKS.ChunkSize }) -and (($r | ForEach-Object { $_.Ranges.Count } | Measure-Object -Sum).Sum -eq $plan.Allowed.Count)
}
Check 'hash deterministic; changes when an app is added' {
    $h1 = (Get-IKSPlan $s).Hash; $s2 = $s.Clone(); $s2.VpnApps = @($s.VpnApps) + [pscustomobject]@{ Path = "$env:SystemRoot\System32\ping.exe"; Name = 'ping'; Source = 'user' }
    $h1 -eq $plan.Hash -and (Get-IKSPlan $s2).Hash -ne $plan.Hash
}
Check 'preview text renders' { (Format-IKSPlan $plan $s) -match 'DRY-RUN' }

Say "`n[settings store]"
$st = Read-IKSSettings
Check 'defaults when file missing (Iran direct on)' { $st.Enabled -eq $false -and $st.IranDirect -eq $true -and $st.VpnApps.Count -eq 0 }
$st.Enabled = $true; $st.VpnApps = @([pscustomobject]@{ Path = 'c:\a.exe'; Name = 'a'; Source = 'user' }); Save-IKSSettings $st
$st2 = Read-IKSSettings
Check 'round-trip save/read (single-item array kept as array)' { $st2.Enabled -and @($st2.VpnApps).Count -eq 1 -and $st2.VpnApps[0].Path -eq 'c:\a.exe' }
Set-Content $script:IKS.SettingsFile '{ broken json'
Check 'corrupt settings -> safe defaults' { (Read-IKSSettings).Enabled -eq $false }
Check 'lock is re-entrant and released' { (Invoke-IKSLocked { Invoke-IKSLocked { 42 } }) -eq 42 }

Say "`n[GUI]"
$png = Join-Path ([IO.Path]::GetTempPath()) 'iks-gui-selftest.png'
Remove-Item $png, "$png.txt" -ErrorAction SilentlyContinue
$env:IKS_GUI_SELFTEST = $png
$p = Start-Process powershell -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$(Join-Path $root 'IKS.Gui.ps1')`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput "$png.txt"
if (-not $p.WaitForExit(45000)) { $p.Kill() }
$env:IKS_GUI_SELFTEST = $null
Check "window loads and renders ($png)" { (Test-Path $png) -and ((Get-Content "$png.txt" -Raw) -match 'GUI-SELFTEST-OK') }
Add-Type -AssemblyName System.Drawing
foreach ($v in @(@{ View = 'main'; H = 0 }, @{ View = 'apps'; H = 0 }, @{ View = 'tests'; H = 0 }, @{ View = 'tests'; H = 470 })) {
    $vp = Join-Path ([IO.Path]::GetTempPath()) "iks-gui-$($v.View)-$($v.H).png"; Remove-Item $vp -ErrorAction SilentlyContinue
    $env:IKS_GUI_SELFTEST = $vp; $env:IKS_GUI_SELFTEST_VIEW = $v.View; $env:IKS_GUI_FIT_HEIGHT = $(if ($v.H) { "$($v.H)" } else { $null })
    $p = Start-Process powershell -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$(Join-Path $root 'IKS.Gui.ps1')`"" -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(45000)) { $p.Kill() }
    $sz = if (Test-Path $vp) { $i = [Drawing.Image]::FromFile($vp); $r = @($i.Width, $i.Height); $i.Dispose(); $r } else { @(0, 0) }
    if ($v.H) { Check "small screen ($($v.H)px high): whole window shrinks to fit ($($sz[0])x$($sz[1]))" { $sz[1] -gt 0 -and $sz[1] -le $v.H + 2 -and $sz[0] -lt 440 } }
    else { Check "view '$($v.View)' renders within a normal screen ($($sz[0])x$($sz[1]))" { $sz[1] -gt 0 -and $sz[1] -le 700 } }
}
$env:IKS_GUI_SELFTEST = $null; $env:IKS_GUI_SELFTEST_VIEW = $null; $env:IKS_GUI_FIT_HEIGHT = $null
$guiRunning = $false
try { ([System.Threading.Mutex]::OpenExisting('Local\IranKillSwitch-GUI')).Dispose(); $guiRunning = $true } catch { }
if (-not $guiRunning) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -Namespace IKSTest -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);'
    $env:IKS_GUI_DEV = '1'
    $gargs = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$(Join-Path $root 'IKS.Gui.ps1')`""
    $g1 = Start-Process powershell -ArgumentList $gargs -PassThru -WindowStyle Hidden
    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 40 -and $h -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 500; $g1.Refresh(); $h = $g1.MainWindowHandle }
    Check 'real window opens' { $h -ne [IntPtr]::Zero }
    if ($h -ne [IntPtr]::Zero) {
        Start-Sleep 4
        Check 'window survives startup (no silent crash)' { -not $g1.HasExited }
        $el = [Windows.Automation.AutomationElement]::FromHandle($h)
        $texts = @($el.FindAll('Descendants', [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name })
        Check "footer shows 'Made by Mansoor' and v$($script:IKS.Version)" { [bool]($texts | Where-Object { $_ -match "Made by Mansoor" -and $_ -match [regex]::Escape("v$($script:IKS.Version)") }) }
        Check 'VPN apps row and Iran direct switch present' { ($texts -contains 'VPN apps') -and ($texts -contains 'Iran direct (TUN)') }
        [void][IKSTest.W]::ShowWindow($h, 6); Start-Sleep 1
        $g2 = Start-Process powershell -ArgumentList $gargs -PassThru -WindowStyle Hidden; $null = $g2.WaitForExit(15000); Start-Sleep 1
        Check 'second launch exits and restores the first window' { $g2.HasExited -and -not [IKSTest.W]::IsIconic($h) }
        $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
        $x = $el.FindAll('Descendants', $cond) | Where-Object { $_.Current.Name -eq [string][char]0xE8BB } | Select-Object -First 1
        $x.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep 2
        Check 'X hides to tray (process alive, window hidden)' { -not $g1.HasExited -and -not [IKSTest.W]::IsWindowVisible($h) }
        $g3 = Start-Process powershell -ArgumentList $gargs -PassThru -WindowStyle Hidden; $null = $g3.WaitForExit(15000); Start-Sleep 1
        Check 'launch brings it back from the tray' { [IKSTest.W]::IsWindowVisible($h) }
    }
    Stop-Process -Id $g1.Id -ErrorAction SilentlyContinue
    $env:IKS_GUI_DEV = $null
} else { Skip 'real-window tests' 'the app is open' }

if ($WfpLive) {
    Say "`n[WFP live - real filter set in a DYNAMIC session, curl.exe plays the VPN app]"
    function Sock([string]$from, [string]$ip, [int]$port = 443) {
        $c = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
        try { if ($from) { $c.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($from), 0))) }
              $ar = $c.BeginConnect($ip, $port, $null, $null); if (-not $ar.AsyncWaitHandle.WaitOne(4000)) { return 'timeout' }; $c.EndConnect($ar); return 'connected' }
        catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; if ($e.ErrorCode -eq 10013) { return 'blocked' }; return $e.Message }
        finally { $c.Close() }
    }
    if (-not (Test-IKSAdmin)) { Skip 'WFP live' 'needs Administrator' }
    elseif ((Get-IKSFilterCount) -gt 0 -or @(Get-NetFirewallRule -Group $script:IKS.LegacyGroup -ErrorAction SilentlyContinue).Count) { Skip 'WFP live' 'protection is ON - turn it OFF first' }
    else {
        $iranIp = '185.147.179.11'
        Check 'before: foreign reachable from PowerShell' { (Sock $phys.IPv4 '1.1.1.1') -eq 'connected' }
        Import-IKSNative
        $session = New-Object IKS.Native.WfpSession($true)
        try {
            $n = Set-IKSFilters $plan -Session $session
            Check "real filter set installed atomically ($n filters)" { $n -eq $spec.Count -and $session.ListOurFilters().Count -eq $n }
            Check 'foreign blocked for a normal program (VPN down)' { (Sock $phys.IPv4 '1.1.1.1') -eq 'blocked' -and (Sock $null '8.8.8.8') -eq 'blocked' }
            Check 'foreign allowed for the VPN program (curl.exe, plain HTTP)' { (& $curl -s -o NUL -w '%{http_code}' -m 10 http://1.1.1.1/) -match '^[23]\d\d$' }
            Check 'Iranian site allowed directly' { (Sock $phys.IPv4 $iranIp) -eq 'connected' }
            Check 'LAN allowed (gateway DNS answers)' {
                $u = New-Object Net.Sockets.UdpClient; $u.Client.ReceiveTimeout = 3000
                $q = New-IKSDnsQuery 'www.aparat.com'; $null = $u.Send($q, $q.Length, $phys.Gateway, 53)
                $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); try { $r = $u.Receive([ref]$ep); $r.Length -gt 0 } finally { $u.Close() }
            }
            Check 'loopback allowed' { $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); try { (Sock $null '127.0.0.1' $l.LocalEndpoint.Port) -eq 'connected' } finally { $l.Stop() } }
            Check 'DNS to a foreign resolver blocked (no leak)' { -not (Test-IKSUdp $phys.IPv4 '8.8.8.8' 53 (New-IKSDnsQuery 'example.com')).Answered }
            $plan2 = Get-IKSPlan ($s.Clone()); $plan2.Apps = @()
            $n2 = Set-IKSFilters $plan2 -Session $session
            Check "re-apply replaces the set in one transaction ($n2 filters, no duplicates)" { $session.ListOurFilters().Count -eq $n2 }
            Check 'after removing the app, curl.exe is blocked too' { -not ((& $curl -s -o NUL -w '%{http_code}' -m 6 http://1.1.1.1/) -match '^[23]\d\d$') }
        } finally { $session.Dispose() }
        Check 'dynamic session closed: everything gone, foreign reachable again' { (Get-IKSFilterCount) -eq 0 -and (Sock $phys.IPv4 '1.1.1.1') -eq 'connected' }
    }
}

Remove-Item $tmpState -Recurse -Force -ErrorAction SilentlyContinue
Say "`nResult: $script:pass passed, $script:fail failed, $script:skip skipped" $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
