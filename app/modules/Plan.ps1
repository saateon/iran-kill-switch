# Plan.ps1 - what the kill switch allows. Pure: reads settings + Iran list, changes nothing.
#
# Allowed outside the tunnel (everything else is blocked):
#   loopback | VPN programs | tunnel interfaces (wintun/WireGuard/PPP) + learned TAP addresses
#   | remote in Iran + LAN/special + allowed servers
# IPv6: same, except Iran (Iranian sites fall back to IPv4); LAN = link-local/multicast/ULA.

function Get-IKSPlan($Settings) {
    $iran = Read-IKSIranList
    $allowed = New-IKSRangeList
    $allowed.AddRange($iran)
    $allowed.AddRange((Get-IKSSpecialRanges))
    $endpoints = @($Settings.EndpointCache | ForEach-Object { $_.Ip } | Sort-Object -Unique)
    Add-IKSRanges $allowed $endpoints
    Add-IKSRanges $allowed @($Settings.DirectCache | ForEach-Object { $_.Ip } | Where-Object { $_ } | Sort-Object -Unique)   # direct sites
    $allowedMerged = Merge-IKSRanges $allowed

    $tun = New-IKSRangeList
    Add-IKSRanges $tun @($Settings.LearnedTunnels | ForEach-Object { $_.Ip })
    $tunMerged = Merge-IKSRanges $tun

    $apps = Get-IKSAppPaths $Settings
    $text = ($apps -join '|') + '#' + (($allowedMerged | ForEach-Object { "$($_[0])-$($_[1])" }) -join ',') + '#' +
            (($tunMerged | ForEach-Object { "$($_[0])-$($_[1])" }) -join ',')
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))) -replace '-', '').Substring(0, 16)
    return [pscustomobject]@{
        Apps = $apps; Allowed = $allowedMerged; Tunnels = $tunMerged; Endpoints = $endpoints
        DirectHosts = @($Settings.DirectCache | ForEach-Object { $_.Host } | Sort-Object -Unique)
        IranRanges = $iran.Count; Iran = $iran; Hash = $hash
    }
}

# Same filter set the engine installs, as data (used by Set-IKSFilters and by tests)
function Get-IKSFilterSpec($Plan) {
    $spec = New-Object System.Collections.Generic.List[object]
    $v4 = @('ConnectV4', 'AcceptV4'); $v6 = @('ConnectV6', 'AcceptV6')
    foreach ($layer in $v4 + $v6) {
        $isV6 = $v6 -contains $layer
        $spec.Add(@{ Layer = $layer; Name = 'IKS allow loopback'; Permit = $true; Weight = 15; Kind = 'loopback' })
        foreach ($a in $Plan.Apps) { $spec.Add(@{ Layer = $layer; Name = "IKS allow VPN app $(Split-Path $a -Leaf)"; Permit = $true; Weight = 14; Kind = 'app'; App = $a }) }
        $spec.Add(@{ Layer = $layer; Name = 'IKS allow tunnel interfaces'; Permit = $true; Weight = 13; Kind = 'iftype'; Types = $script:IKS.TunnelIfTypes })
        if ($isV6) {
            $spec.Add(@{ Layer = $layer; Name = 'IKS allow IPv6 LAN'; Permit = $true; Weight = 12; Kind = 'v6'; Prefixes = $script:IKS.SpecialV6 })
        } else {
            if ($Plan.Tunnels.Count) { $spec.Add(@{ Layer = $layer; Name = 'IKS allow TAP tunnel addresses'; Permit = $true; Weight = 13; Kind = 'local'; Ranges = $Plan.Tunnels }) }
            for ($i = 0; $i -lt $Plan.Allowed.Count; $i += $script:IKS.ChunkSize) {
                $chunk = $Plan.Allowed.GetRange($i, [Math]::Min($script:IKS.ChunkSize, $Plan.Allowed.Count - $i))
                $spec.Add(@{ Layer = $layer; Name = "IKS allow Iran + LAN ($([int]($i / $script:IKS.ChunkSize) + 1))"; Permit = $true; Weight = 12; Kind = 'remote'; Ranges = $chunk })
            }
        }
        $spec.Add(@{ Layer = $layer; Name = 'IKS block everything else'; Permit = $false; Weight = 1; Kind = 'block' })
    }
    return , $spec
}

function Format-IKSPlan($Plan, $Settings) {
    $spec = Get-IKSFilterSpec $Plan
    $L = @('DRY-RUN - nothing was changed.', '',
           "Windows Filtering Platform: $($spec.Count) filters in the 'Iran Kill Switch' sublayer (all added in one transaction).", '',
           'Allowed outside the VPN tunnel:',
           "   VPN programs   : $(if ($Plan.Apps) { ($Plan.Apps | ForEach-Object { Split-Path $_ -Leaf }) -join ', ' } else { '(none found yet)' })",
           "   Tunnels        : any wintun / WireGuard / PPP adapter$(if ($Plan.Tunnels.Count) { " + TAP addresses $(($Plan.Tunnels | ForEach-Object { ConvertTo-IKSRangeText $_ }) -join ', ')" })",
           "   Iran           : $($Plan.IranRanges) ranges",
           '   Local network  : LAN, loopback, DHCP, multicast',
           "   Allowed servers: $(if ($Plan.Endpoints) { $Plan.Endpoints -join ', ' } else { '-' })",
           "   Direct sites   : $(if ($Plan.DirectHosts) { $Plan.DirectHosts -join ', ' } else { '-' })",
           '   IPv6           : blocked except loopback, LAN and tunnels', '',
           "Iran direct (TUN): $(if ($Settings.IranDirect) { 'ON - Iranian ranges get a direct route via the real network adapter' } else { 'off' })",
           'Windows Firewall : not touched')
    return ($L -join "`r`n")
}
