#Requires -Version 5.1
<#
  Builds the single-file installer:  dist\IranKillSwitch-Setup-<version>.exe
  Version comes from app\VERSION (the only place to change it).

    powershell -ExecutionPolicy Bypass -File Build-Setup.ps1             # tests first, then build
    powershell -ExecutionPolicy Bypass -File Build-Setup.ps1 -SkipTests  # build only

  Uses only what ships with Windows: the .NET Framework C# compiler and System.IO.Compression.
  Nothing is written if the tests fail.
#>
param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$app = Join-Path $root 'app'
. (Join-Path $app 'IKS.ps1')                 # version + New-IKSIconFile
$ver = $script:IKS.Version
if ($ver -notmatch '^\d+\.\d+\.\d+$') { throw "app\VERSION must look like 1.2.3 (found '$ver')." }
Write-Host "Iran Kill Switch $ver - building installer" -ForegroundColor Cyan

if (-not $SkipTests) {
    Write-Host 'Running tests ...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-Tests.ps1') | Select-String 'FAIL|Result' | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed - installer NOT built.' }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "iks-build-$PID"
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $work, $dist | Out-Null
try {
    # payload: the app folder without machine state or build output
    $pkg = Join-Path $work 'pkg'
    Copy-Item $app (Join-Path $pkg 'app') -Recurse
    foreach ($x in 'state', 'bin', 'IranKillSwitch.exe') { Remove-Item (Join-Path $pkg "app\$x") -Recurse -Force -ErrorAction SilentlyContinue }
    $zip = Join-Path $work 'payload.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($pkg, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)

    $ico = Join-Path $work 'setup.ico'; New-IKSIconFile $ico
    $man = Join-Path $work 'setup.manifest'
    @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>
    <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
  </requestedPrivileges></security></trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
  </application></compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
  </windowsSettings></application>
</assembly>
'@ | Set-Content $man -Encoding UTF8

    $out = Join-Path $dist "IranKillSwitch-Setup-$ver.exe"
    if (Test-Path $out) { Remove-Item $out -Force }
    $cp = New-Object System.CodeDom.Compiler.CompilerParameters
    $cp.GenerateExecutable = $true
    $cp.OutputAssembly = $out
    $cp.CompilerOptions = "/target:winexe /optimize+ /win32manifest:`"$man`" /win32icon:`"$ico`""
    foreach ($r in 'System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll') { $null = $cp.ReferencedAssemblies.Add($r) }
    $null = $cp.EmbeddedResources.Add($zip)
    $code = ([IO.File]::ReadAllText((Join-Path $root 'installer\SetupApp.cs'))).Replace('__IKS_VERSION__', $ver)
    Add-Type -TypeDefinition $code -CompilerParameters $cp

    $fi = Get-Item $out
    $hash = (Get-FileHash $out -Algorithm SHA256).Hash
    Write-Host ''
    Write-Host "Built: $($fi.FullName)" -ForegroundColor Green
    Write-Host ("Size : {0:N0} KB   SHA256: {1}" -f ($fi.Length / 1KB), $hash)
    Write-Host 'Install: double-click it.   Silent: IranKillSwitch-Setup-<version>.exe /quiet'
} finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
