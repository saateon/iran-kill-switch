# IpMath.ps1 - IPv4 range arithmetic.
# A range is [long[]]@(start, end) (inclusive). A range list is List[long[]].
# "Merged" lists are sorted and non-overlapping (needed by complement/search).

function ConvertTo-IKSInt([string]$Ip) {
    $b = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    return ([long]$b[0] -shl 24) + ([long]$b[1] -shl 16) + ([long]$b[2] -shl 8) + [long]$b[3]
}

function ConvertFrom-IKSInt([long]$N) {
    return '{0}.{1}.{2}.{3}' -f (($N -shr 24) -band 255), (($N -shr 16) -band 255), (($N -shr 8) -band 255), ($N -band 255)
}

function Test-IKSIPv4([string]$Text) {
    if ($Text -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($o in $Text.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

function New-IKSRangeList { return , (New-Object 'System.Collections.Generic.List[long[]]') }

# "1.2.3.0/24" | "1.2.3.4-1.2.3.9" | "1.2.3.4"  ->  [long[]](start,end) or $null
function ConvertTo-IKSRange([string]$Text) {
    $t = "$Text".Trim()
    if ($t -match '^([\d\.]+)/(\d{1,2})$' -and (Test-IKSIPv4 $Matches[1]) -and [int]$Matches[2] -le 32) {
        $size = [long][math]::Pow(2, 32 - [int]$Matches[2])
        $start = ConvertTo-IKSInt $Matches[1]
        $start -= $start % $size
        return , ([long[]]@($start, ($start + $size - 1)))
    }
    if ($t -match '^([\d\.]+)-([\d\.]+)$' -and (Test-IKSIPv4 $Matches[1]) -and (Test-IKSIPv4 $Matches[2])) {
        $a = ConvertTo-IKSInt $Matches[1]; $b = ConvertTo-IKSInt $Matches[2]
        if ($a -gt $b) { return $null }
        return , ([long[]]@($a, $b))
    }
    if (Test-IKSIPv4 $t) { $n = ConvertTo-IKSInt $t; return , ([long[]]@($n, $n)) }
    return $null
}

function Add-IKSRanges($List, $Texts) {
    foreach ($t in $Texts) { $r = ConvertTo-IKSRange $t; if ($null -ne $r) { $List.Add($r) } }
}

# Sort + merge overlapping/adjacent ranges -> new merged List[long[]]
function Merge-IKSRanges($List) {
    $n = $List.Count
    $out = New-IKSRangeList
    if ($n -eq 0) { return , $out }
    $starts = New-Object long[] $n
    $ends = New-Object long[] $n
    for ($i = 0; $i -lt $n; $i++) { $starts[$i] = $List[$i][0]; $ends[$i] = $List[$i][1] }
    [Array]::Sort($starts, $ends)
    [long]$cs = $starts[0]; [long]$ce = $ends[0]
    for ($i = 1; $i -lt $n; $i++) {
        if ($starts[$i] -le ($ce + 1)) { if ($ends[$i] -gt $ce) { $ce = $ends[$i] } }
        else { $out.Add([long[]]@($cs, $ce)); $cs = $starts[$i]; $ce = $ends[$i] }
    }
    $out.Add([long[]]@($cs, $ce))
    return , $out
}

# Everything in 0.0.0.0-255.255.255.255 not covered by a MERGED list
function Get-IKSComplement($Merged) {
    $out = New-IKSRangeList
    [long]$next = 0
    foreach ($r in $Merged) {
        if ($r[0] -gt $next) { $out.Add([long[]]@($next, ($r[0] - 1))) }
        $next = $r[1] + 1
    }
    if ($next -le 4294967295) { $out.Add([long[]]@($next, [long]4294967295)) }
    return , $out
}

function ConvertTo-IKSRangeText([long[]]$R) {
    if ($R[0] -eq $R[1]) { return (ConvertFrom-IKSInt $R[0]) }
    return '{0}-{1}' -f (ConvertFrom-IKSInt $R[0]), (ConvertFrom-IKSInt $R[1])
}

# Binary search in a MERGED list
function Test-IKSInRanges([string]$Ip, $Merged) {
    if (-not (Test-IKSIPv4 $Ip)) { return $false }
    $n = ConvertTo-IKSInt $Ip
    $lo = 0; $hi = $Merged.Count - 1
    while ($lo -le $hi) {
        $mid = [int][math]::Floor(($lo + $hi) / 2)
        if ($n -lt $Merged[$mid][0]) { $hi = $mid - 1 }
        elseif ($n -gt $Merged[$mid][1]) { $lo = $mid + 1 }
        else { return $true }
    }
    return $false
}

function Get-IKSAddressCount($Merged) {
    [long]$t = 0
    foreach ($r in $Merged) { $t += $r[1] - $r[0] + 1 }
    return $t
}

# Split one range into the minimal list of CIDR blocks (for routes). Returns @(@(start, prefixLength), ...)
function ConvertTo-IKSCidrs([long[]]$R) {
    $out = New-Object System.Collections.Generic.List[object]
    [long]$s = $R[0]; [long]$e = $R[1]
    while ($s -le $e) {
        $len = 32
        while ($len -gt 0) {
            [long]$size = [long][math]::Pow(2, 33 - $len)            # size of the block one bit shorter
            if (($s % $size) -ne 0 -or ($s + $size - 1) -gt $e) { break }
            $len--
        }
        $out.Add(@($s, $len))
        $s += [long][math]::Pow(2, 32 - $len)
    }
    return , $out
}

function Get-IKSSpecialRanges {
    $l = New-IKSRangeList
    Add-IKSRanges $l $script:IKS.SpecialV4
    return , (Merge-IKSRanges $l)
}
