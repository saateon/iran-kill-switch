#Requires -Version 5.1
<#
  Live test of app\native\IksNative.cs (Administrator). Safe by design:
  every WFP object is created in a DYNAMIC session, which Windows deletes when the
  session closes; the one test route is deleted in 'finally'.
    powershell -ExecutionPolicy Bypass -File tests\Native.Live.ps1 [-Out result.txt]
#>
param([string]$Out = '')
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'app\native\IksNative.cs'
$script:pass = 0; $script:fail = 0
function Say([string]$m) { if ($Out) { Add-Content -Path $Out -Value $m -Encoding UTF8 } else { Write-Host $m } }
function Check([string]$Name, [scriptblock]$Cond) {
    try { $ok = [bool](& $Cond) } catch { $ok = $false; $Name += "  ($($_.Exception.Message))" }
    if ($ok) { $script:pass++; Say "  PASS  $Name" } else { $script:fail++; Say "  FAIL  $Name" }
}
function Sock([string]$ip, [int]$port = 443) {
    $c = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
    try { $ar = $c.BeginConnect($ip, $port, $null, $null); if (-not $ar.AsyncWaitHandle.WaitOne(4000)) { return 'timeout' }; $c.EndConnect($ar); return 'connected' }
    catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; if ($e.ErrorCode -eq 10013) { return 'blocked' }; return $e.Message }
    finally { $c.Close() }
}
function U32([string]$ip) { $b = [Net.IPAddress]::Parse($ip).GetAddressBytes(); return [uint32](([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor $b[3]) }

if ($Out) { Set-Content -Path $Out -Value 'Native live test' -Encoding UTF8 }
Say '[compile]'
Check 'IksNative.cs compiles' { Add-Type -Path $src; [bool]('IKS.Native.WfpSession' -as [type]) }

$target = '185.147.179.11'          # Iranian host, reachable before the test
$phys = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
$ifType = (Get-NetAdapter -InterfaceIndex $phys.ifIndex).InterfaceType

Say '[routes API layout]'
$probe = [IKS.Native.Routes]::DefaultRouteProbe()
Check "default route read via offsets = '$probe' (system: $($phys.ifIndex) $($phys.NextHop))" { $probe -eq "$($phys.ifIndex) $($phys.NextHop)" }

Say '[WFP]'
Check "target reachable before ($target)" { (Sock $target) -eq 'connected' }
$s = New-Object IKS.Native.WfpSession($true)
try {
    $s.EnsureProviderAndSublayer()
    $s.Begin()
    $null = $s.AddFilter('test block range', [IKS.Native.Ids]::ConnectV4, $false, 1, @([IKS.Native.Cond]::RemoteRange((U32 '185.147.179.0'), (U32 '185.147.179.255'))))
    $s.Commit()
    Check 'remote RANGE block works' { (Sock $target) -eq 'blocked' }

    $s.Begin()
    $null = $s.AddFilter('test permit iftype', [IKS.Native.Ids]::ConnectV4, $true, 10, @([IKS.Native.Cond]::InterfaceType([uint32]$ifType)))
    $s.Commit()
    Check "INTERFACE_TYPE permit ($ifType) overrides the block" { (Sock $target) -eq 'connected' }

    $s.Begin()
    $added = 0
    foreach ($layer in [IKS.Native.Ids]::Layers) {
        $v6 = $layer -eq [IKS.Native.Ids]::ConnectV6 -or $layer -eq [IKS.Native.Ids]::AcceptV6
        $null = $s.AddFilter('test loopback', $layer, $true, 15, @([IKS.Native.Cond]::Loopback())); $added++
        $null = $s.AddFilter('test app', $layer, $true, 14, @([IKS.Native.Cond]::App("$env:SystemRoot\System32\curl.exe"))); $added++
        if ($v6) {
            $ll = [byte[]](0xfe, 0x80) + [byte[]](,0 * 14)
            $null = $s.AddFilter('test v6 prefix', $layer, $true, 12, @([IKS.Native.Cond]::RemoteV6($ll, 10))); $added++
        } else {
            $null = $s.AddFilter('test local range', $layer, $true, 13, @([IKS.Native.Cond]::LocalRange((U32 '172.19.0.0'), (U32 '172.19.0.255')))); $added++
            $many = @(1..1500 | ForEach-Object { [IKS.Native.Cond]::RemoteRange([uint32](16777216 * 100 + $_ * 256), [uint32](16777216 * 100 + $_ * 256 + 255)) })
            $null = $s.AddFilter('test 1500 ranges', $layer, $true, 12, $many); $added++
        }
    }
    $s.Commit()
    Check "loopback / app / v6 prefix / local range / 1500-range filters accepted on all 4 layers ($added)" { $true }
    Check 'enumeration finds exactly our filters' { $s.ListOurFilters().Count -eq ($added + 2) }

    $before = $s.ListOurFilters().Count
    $s.Begin(); $null = $s.AddFilter('test aborted', [IKS.Native.Ids]::ConnectV4, $false, 1, $null); $s.Abort()
    Check 'aborted transaction leaves nothing behind' { $s.ListOurFilters().Count -eq $before }

    $n = $s.RemoveAll()
    Check "RemoveAll deletes everything ($n filters)" { $s.ListOurFilters().Count -eq 0 }
    Check 'target reachable after RemoveAll' { (Sock $target) -eq 'connected' }
} finally { $s.Dispose() }

Say '[routes API]'
$pfx = U32 '185.147.179.0'; $hop = U32 $phys.NextHop
try {
    $r = [IKS.Native.Routes]::Add($pfx, 24, [uint32]$phys.ifIndex, $hop, 1)
    Check "add route 185.147.179.0/24 via $($phys.NextHop) (code $r)" { $r -eq 0 -or $r -eq 5010 }
    Check 'route visible to Windows and chosen for the target' { (Find-NetRoute -RemoteIPAddress $target | Select-Object -Last 1).DestinationPrefix -eq '185.147.179.0/24' }
} finally {
    $d = [IKS.Native.Routes]::Delete($pfx, 24, [uint32]$phys.ifIndex, $hop)
}
Check "delete route (code $d)" { $d -eq 0 -and -not (Get-NetRoute -DestinationPrefix '185.147.179.0/24' -ErrorAction SilentlyContinue) }

Say "Result: $script:pass passed, $script:fail failed"
exit $(if ($script:fail) { 1 } else { 0 })
