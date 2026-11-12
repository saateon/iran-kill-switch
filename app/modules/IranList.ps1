# IranList.ps1 - Iran IPv4 list: read, info, download + validate + atomic save.
# File format (data\ir-ipv4.txt): "# key: value" header lines, then one range per line.

function Read-IKSIranList {
    if (-not (Test-Path $script:IKS.IranFile)) { throw "Iran IP list missing: $($script:IKS.IranFile)" }
    $l = New-IKSRangeList
    Add-IKSRanges $l @(Get-Content $script:IKS.IranFile | Where-Object { $_ -and $_[0] -ne '#' })
    if ($l.Count -lt 300) { throw "Iran IP list looks damaged ($($l.Count) ranges)." }
    return , (Merge-IKSRanges $l)
}

function Get-IKSListInfo([string]$Path = $script:IKS.IranFile) {
    $info = @{ Ranges = 0; Updated = ''; Source = '' }
    if (Test-Path $Path) {
        $lines = @(Get-Content $Path)
        $info.Ranges = @($lines | Where-Object { $_ -and $_[0] -ne '#' }).Count
        foreach ($l in ($lines | Select-Object -First 6)) {
            if ($l -match '^# updated: (.+)$') { $info.Updated = $Matches[1].Trim() }
            if ($l -match '^# source: (.+)$') { $info.Source = $Matches[1].Trim() }
        }
    }
    return $info
}

# First local proxy port of a running VPN client (proxy-mode clients)
function Get-IKSLocalProxy {
    try {
        $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::') } | ForEach-Object { $_.LocalPort })
        foreach ($p in $script:IKS.LocalProxyPorts) { if ($listen -contains $p) { return "http://127.0.0.1:$p" } }
    } catch { }
    return $null
}

# Direct first (works through TUN), then through the local VPN proxy
function Get-IKSWebText([string]$Url, [int]$TimeoutSec = 90) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $errors = @()
    foreach ($proxy in @($null, (Get-IKSLocalProxy)) | Select-Object -Unique) {
        try {
            $p = @{ Uri = $Url; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
            if ($proxy) { $p.Proxy = $proxy }
            $c = (Invoke-WebRequest @p).Content
            if ($c -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($c) }
            return [string]$c
        } catch { $errors += "$(if ($proxy) { "via $proxy" } else { 'direct' }): $($_.Exception.Message)" }
    }
    throw ($errors -join ' | ')
}

# Parse one source's text into the range list; returns entries found
function Add-IKSSourceRanges($List, [string]$Text, [string]$Kind) {
    $n = 0
    foreach ($line in ($Text -split "`n")) {
        $line = $line.Trim()
        if ($Kind -eq 'ripe') {
            if ($line -match '^ripencc\|IR\|ipv4\|([\d\.]+)\|(\d+)\|') {
                $s = ConvertTo-IKSInt $Matches[1]
                $List.Add([long[]]@($s, ($s + [long]$Matches[2] - 1))); $n++
            }
        } elseif ($line -match '^[\d\.]+/\d+$') {
            $r = ConvertTo-IKSRange $line; if ($null -ne $r) { $List.Add($r); $n++ }
        }
    }
    return $n
}

function Update-IKSIranList([switch]$Force) {
    $info = Get-IKSListInfo
    if (-not $Force -and $info.Ranges -gt 0 -and (Get-IKSAgeDays $info.Updated) -lt $script:IKS.ListMaxAgeDays) {
        return @{ Changed = $false; Message = 'Iran list is up to date.' }
    }
    $all = New-IKSRangeList
    $used = @(); $fails = @()
    foreach ($src in $script:IKS.IranSources) {
        try {
            $n = Add-IKSSourceRanges $all (Get-IKSWebText $src.Url) $src.Kind
            if ($n -lt 300) { throw "only $n entries" }
            $used += "$($src.Name) ($n)"
        } catch { $fails += "$($src.Name): $($_.Exception.Message)" }
    }
    if (-not $used) {
        Write-IKSLog "Iran list download failed: $($fails -join '; ')" 'WARN'
        return @{ Changed = $false; Message = "Download failed, existing list kept. $($fails -join '; ')" }
    }
    $merged = Merge-IKSRanges $all
    $total = Get-IKSAddressCount $merged
    # Sanity: Iran holds roughly 10-14 million IPv4 addresses
    if ($merged.Count -lt 300 -or $total -lt 4000000 -or $total -gt 40000000) {
        Write-IKSLog "Iran list rejected by sanity check ($($merged.Count) ranges, $total addresses)" 'WARN'
        return @{ Changed = $false; Message = 'Downloaded list looked wrong, existing list kept.' }
    }
    if (-not (Test-Path $script:IKS.DataDir)) { New-Item -ItemType Directory -Force $script:IKS.DataDir | Out-Null }
    $body = @('# Iran IPv4 ranges - Iran Kill Switch',
              "# updated: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))",
              "# source: $($used -join ' + ')",
              "# ranges: $($merged.Count)  addresses: $total") + @($merged | ForEach-Object { ConvertTo-IKSRangeText $_ })
    $tmp = "$($script:IKS.IranFile).tmp"
    $body | Set-Content -Path $tmp -Encoding ASCII
    Move-Item $tmp $script:IKS.IranFile -Force
    Write-IKSLog "Iran list updated: $($merged.Count) ranges from $($used -join ' + ')"
    return @{ Changed = $true; Message = "Iran list updated: $($merged.Count) ranges ($($used -join ' + '))." }
}
