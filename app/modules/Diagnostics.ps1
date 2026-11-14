# Diagnostics.ps1 - live leak tests. Read-only: they only open test sockets.
# Key trick: sockets are BOUND to the real NIC address, which is exactly how
# traffic leaves when the VPN is down. So "VPN crashed" is tested without
# having to close the VPN.

function Get-IKSSocketError($Err) {
    $e = $Err.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [Net.Sockets.SocketException]) {
        switch ($e.ErrorCode) { 10013 { return 'blocked by firewall' } 10060 { return 'no answer' } 10065 { return 'no route' } 10051 { return 'network unreachable' } }
    }
    return $e.Message
}

function Test-IKSTcp([string]$From, [string]$To, [int]$Port = 443, [int]$Ms = 3000) {
    $fam = [Net.IPAddress]::Parse($To).AddressFamily
    $sock = New-Object Net.Sockets.Socket($fam, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
    try {
        if ($From) { $sock.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($From), 0))) }
        $ar = $sock.BeginConnect([Net.IPAddress]::Parse($To), $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Ms)) { return @{ Ok = $false; Why = 'no answer' } }
        $sock.EndConnect($ar)
        return @{ Ok = $true; Why = 'connected' }
    } catch { return @{ Ok = $false; Why = (Get-IKSSocketError $_) } }
    finally { $sock.Close() }
}

function Test-IKSUdp([string]$From, [string]$To, [int]$Port, [byte[]]$Payload, [int]$Ms = 2500) {
    $sock = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    try {
        if ($From) { $sock.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($From), 0))) }
        $sock.ReceiveTimeout = $Ms
        $null = $sock.SendTo($Payload, (New-Object Net.IPEndPoint([Net.IPAddress]::Parse($To), $Port)))
        $buf = New-Object byte[] 1500
        $n = $sock.Receive($buf)
        return @{ Answered = $n -gt 0; Why = "answered ($n bytes)" }
    } catch { return @{ Answered = $false; Why = (Get-IKSSocketError $_) } }
    finally { $sock.Close() }
}

function New-IKSDnsQuery([string]$Name) {
    $q = New-Object System.Collections.Generic.List[byte]
    $q.AddRange([byte[]](0x1A, 0x2B, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
    foreach ($label in $Name.Split('.')) { $q.Add([byte]$label.Length); $q.AddRange([Text.Encoding]::ASCII.GetBytes($label)) }
    $q.AddRange([byte[]](0, 0, 1, 0, 1))
    return $q.ToArray()
}

# All names at once, with one shared time limit: a blocked DNS can otherwise hang ~15 s per name.
function Resolve-IKSIPv4Many([string[]]$Names, [int]$Ms = 3000) {
    $pending = @{}
    foreach ($n in $Names) { try { $pending[$n] = [Net.Dns]::BeginGetHostAddresses($n, $null, $null) } catch { } }
    $end = (Get-Date).AddMilliseconds($Ms)
    $out = @{}
    foreach ($n in $Names) {
        $out[$n] = @()
        $ar = $pending[$n]
        if (-not $ar) { continue }
        $left = [Math]::Max(0, [int]($end - (Get-Date)).TotalMilliseconds)
        if ($ar.AsyncWaitHandle.WaitOne($left)) {
            try { $out[$n] = @([Net.Dns]::EndGetHostAddresses($ar) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { }
        }
    }
    return $out
}

function Resolve-IKSIPv4([string]$Name) { return @((Resolve-IKSIPv4Many @($Name))[$Name]) }

function Invoke-IKSTest {
    $res = New-Object System.Collections.Generic.List[object]
    $add = { param($n, $r, $d) $res.Add([pscustomobject]@{ Test = $n; Result = $r; Detail = $d }) }

    $st = Get-IKSStatus
    $iran = Read-IKSIranList
    $s = Read-IKSSettings
    $known = @($s.EndpointCache | ForEach-Object { $_.Ip })          # user-allowed servers are not leaks
    $phys = Get-IKSPhysicalInterface
    $iranSites = 'www.aparat.com', 'www.digikala.com', 'www.varzesh3.com', 'www.shaparak.ir'
    $dns = Resolve-IKSIPv4Many (@($iranSites) + 'stun.l.google.com')     # in parallel, max 3 s in total

    # 1. protection installed and active
    if ($st.Enabled -and $st.Filters -gt 0) { & $add 'Kill switch active' 'PASS' "$($st.Filters) WFP filters active" }
    elseif ($st.Enabled -and $st.Filters -lt 0) { & $add 'Kill switch active' 'SKIP' 'Run as Administrator to read the filters' }
    elseif ($st.Enabled) { & $add 'Kill switch active' 'FAIL' ($st.Problems -join ' ') }
    else { & $add 'Kill switch active' 'FAIL' 'Protection is OFF' }
    $okApps = @($st.VpnApps | Where-Object Exists)
    if ($okApps) { & $add 'VPN programs allowed' 'PASS' (($okApps | ForEach-Object { "$($_.Name)$(if ($_.Running) { ' (running)' })" }) -join ', ') }
    else { & $add 'VPN programs allowed' 'FAIL' 'No VPN program found - your VPN could not connect while protection is ON.' }

    if (-not $phys) { & $add 'Internet connection' 'FAIL' 'No internet connection (no default route).'; return $res }
    $src = $phys.IPv4

    # 2. VPN-down simulation: foreign traffic from the real NIC
    $targets = @('1.1.1.1', '8.8.8.8', '9.9.9.9', '208.67.222.222' | Where-Object { $known -notcontains $_ }) | Select-Object -First 2
    $leaks = @(); $why = @()
    foreach ($t in $targets) { $r = Test-IKSTcp $src $t 443; if ($r.Ok) { $leaks += $t } else { $why += "$t $($r.Why)" } }
    if ($leaks) { & $add 'Foreign traffic blocked when VPN is down' 'FAIL' "LEAK: reached $($leaks -join ', ') directly via $($phys.Alias)" }
    else { & $add 'Foreign traffic blocked when VPN is down' 'PASS' "$($phys.Alias) ${src}: $($why -join '; ')" }

    # 3. Iranian site directly from the real NIC
    $ok = $false; $detail = 'No Iranian test site resolved to an Iranian IP.'
    foreach ($site in $iranSites) {
        $ip = $dns[$site] | Where-Object { Test-IKSInRanges $_ $iran } | Select-Object -First 1
        if (-not $ip) { continue }
        $r = Test-IKSTcp $src $ip 443
        $detail = "$site ($ip): $($r.Why) via $($phys.Alias)"
        if ($r.Ok) { $ok = $true; $iranIp = $ip; $iranSite = $site; break }
    }
    & $add 'Iranian sites work directly' $(if ($ok) { 'PASS' } else { 'FAIL' }) $detail

    # 4. DNS leak: plain DNS to a foreign resolver outside the tunnel
    $dnsT = @('8.8.8.8', '1.1.1.1', '9.9.9.9' | Where-Object { $known -notcontains $_ })[0]
    $r = Test-IKSUdp $src $dnsT 53 (New-IKSDnsQuery 'example.com')
    & $add 'DNS leak' $(if ($r.Answered) { 'FAIL' } else { 'PASS' }) "foreign DNS $dnsT outside VPN: $($r.Why)"

    # 5. WebRTC leak: a STUN answer outside the tunnel would reveal the real IP
    $stun = $dns['stun.l.google.com'] | Where-Object { -not (Test-IKSInRanges $_ $iran) } | Select-Object -First 1
    if ($stun) {
        $pkt = [byte[]](@(0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42) + @(1..12 | ForEach-Object { Get-Random -Maximum 256 }))
        $r = Test-IKSUdp $src $stun 19302 $pkt
        & $add 'WebRTC leak' $(if ($r.Answered) { 'FAIL' } else { 'PASS' }) "STUN $stun outside VPN: $($r.Why)"
    } else { & $add 'WebRTC leak' 'SKIP' 'STUN server could not be resolved' }

    # 6. IPv6 leak
    # bound to the real adapter's public IPv6 (IPv6 inside a VPN tunnel is allowed and is not a leak)
    $v6 = @(Get-NetIPAddress -AddressFamily IPv6 -InterfaceIndex $phys.ifIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -match '^[23]' -and "$($_.AddressState)" -eq 'Preferred' })
    if (-not $v6) { & $add 'IPv6 leak' 'PASS' 'The real network adapter has no public IPv6 address - nothing can leak.' }
    else {
        $r = Test-IKSTcp $v6[0].IPAddress '2606:4700:4700::1111' 443
        & $add 'IPv6 leak' $(if ($r.Ok) { 'FAIL' } else { 'PASS' }) $(if ($r.Ok) { 'IPv6 internet is reachable outside the VPN!' } else { "IPv6 outside the VPN: $($r.Why)" })
    }

    # 7. Iran direct (only meaningful while a TUN-mode VPN captures all traffic)
    if (-not $st.IranDirect) { & $add 'Iranian sites bypass the VPN (TUN)' 'SKIP' 'Iran direct is turned off.' }
    elseif ($st.VpnMode -ne 'tun') { & $add 'Iranian sites bypass the VPN (TUN)' 'SKIP' 'No TUN-mode VPN connected right now.' }
    elseif (-not $iranIp) { & $add 'Iranian sites bypass the VPN (TUN)' 'SKIP' 'No Iranian test site available.' }
    else {
        $route = Find-NetRoute -RemoteIPAddress $iranIp -ErrorAction SilentlyContinue | Select-Object -First 1
        $direct = $route -and $route.InterfaceIndex -eq $phys.ifIndex
        & $add 'Iranian sites bypass the VPN (TUN)' $(if ($direct) { 'PASS' } else { 'FAIL' }) $(if ($direct) { "$iranSite goes out via $($phys.Alias) ($($route.IPAddress)), not the tunnel" } else { "$iranSite is routed into the tunnel (route: $($route.InterfaceAlias))" })
    }

    # 8. Through the VPN
    if ($st.VpnMode -eq 'none') { & $add 'Internet through VPN' 'SKIP' 'VPN not connected - connect it and test again.' }
    else {
        try {
            $p = @{ Uri = 'https://api.ipify.org'; UseBasicParsing = $true; TimeoutSec = 8 }
            if ($st.VpnMode -eq 'proxy') { $p.Proxy = $st.Proxy }
            $ip = "$((Invoke-WebRequest @p).Content)".Trim()
            if (Test-IKSInRanges $ip $iran) { & $add 'Internet through VPN' 'FAIL' "Public IP $ip is Iranian: traffic is NOT using the VPN." }
            else { & $add 'Internet through VPN' 'PASS' "Foreign sites see $ip ($($st.VpnMode) mode)" }
        } catch { & $add 'Internet through VPN' 'FAIL' "VPN looks connected but a foreign site failed: $($_.Exception.Message)" }
    }

    # 9. Proxy mode only works for programs that use the proxy: Windows must be set to use it
    if ($st.VpnMode -eq 'proxy') {
        $sys = Get-IKSSystemProxy
        if ($sys.Enabled -or $sys.Pac) { & $add 'Browsers use the VPN' 'PASS' "Windows proxy: $(if ($sys.Pac) { $sys.Pac } else { $sys.Server })" }
        else { & $add 'Browsers use the VPN' 'FAIL' "Your VPN runs only as a local proxy ($($st.Proxy -replace 'http://', '')) and Windows is not set to use it, so browsers go direct and are blocked. In your VPN app choose 'System proxy' or 'VPN / TUN' mode." }
    }
    return $res
}
