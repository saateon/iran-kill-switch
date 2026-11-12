#Requires -Version 5.1
<#
  Iran Kill Switch - entry point (CLI). Loads modules\*.ps1 in a fixed order.
  Dot-source with no -Action to just load the functions (the GUI and tests do this).

    IKS.ps1 -Action Preview              dry-run: shows the plan, changes nothing
    IKS.ps1 -Action Enable [-WithRevert] turn protection on (-WithRevert: auto-undo in 120 s)
    IKS.ps1 -Action KeepEnabled          cancel the auto-undo
    IKS.ps1 -Action Disable              turn protection off, remove every filter and route
    IKS.ps1 -Action Status|Test [-Json]  health / live leak tests
    IKS.ps1 -Action Sync                 what the background guard runs
    IKS.ps1 -Action AddApp|RemoveApp -Path <exe>
    IKS.ps1 -Action IranDirect -On|-Off
    IKS.ps1 -Action UpdateList           force-download the Iran list
    IKS.ps1 -Action Install|Uninstall [-RestoreOriginal]
#>
param(
    [ValidateSet('', 'Install', 'Uninstall', 'Enable', 'Disable', 'AutoRevert', 'KeepEnabled', 'Preview', 'Status', 'Test',
                 'Sync', 'UpdateList', 'AddApp', 'RemoveApp', 'IranDirect')]
    [string]$Action = '',
    [string]$Path = '',
    [switch]$On,
    [switch]$Off,
    [switch]$WithRevert,
    [switch]$RestoreOriginal,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

foreach ($m in 'Config', 'IpMath', 'IranList', 'Discovery', 'Native', 'Plan', 'Protect', 'Tasks', 'Actions', 'Diagnostics', 'Setup') {
    . (Join-Path $PSScriptRoot "modules\$m.ps1")
}

if (-not $Action) { return }

$code = 0
try {
    if ($Action -notin 'Status', 'Preview', 'Test' -and -not (Test-IKSAdmin)) { throw 'Please run as Administrator.' }
    $out = switch ($Action) {
        'Install'     { Invoke-IKSInstall }
        'Uninstall'   { Invoke-IKSUninstall -RestoreOriginal:$RestoreOriginal }
        'Enable'      { Invoke-IKSEnable -WithRevert:$WithRevert }
        'Disable'     { Invoke-IKSDisable }
        'AutoRevert'  { Invoke-IKSDisable -FromRevertTask }
        'KeepEnabled' { Confirm-IKSKeep }
        'Preview'     { Invoke-IKSPreview }
        'Status'      { Get-IKSStatus }
        'Test'        { Invoke-IKSTest }
        'Sync'        { Invoke-IKSSync }
        'AddApp'      { Add-IKSVpnApp $Path }
        'RemoveApp'   { Remove-IKSVpnApp $Path }
        'IranDirect'  { if ($On -eq $Off) { throw 'Use -On or -Off.' }; Set-IKSIranDirect ([bool]$On) }
        'UpdateList'  { (Update-IKSIranList -Force).Message }
    }
    if ($Json) { ConvertTo-Json -InputObject @($out) -Depth 5 }
    elseif ($Action -eq 'Test') { $out | Format-Table -AutoSize -Wrap | Out-String -Width 200 }
    else { $out }
} catch {
    Write-IKSLog "$Action failed: $_" 'ERROR'
    if ($Json) { ConvertTo-Json @{ Error = "$_" } } else { Write-Host "ERROR: $_" -ForegroundColor Red }
    $code = 1
}
exit $code
