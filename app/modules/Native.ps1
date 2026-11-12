# Native.ps1 - loads the C# helper (app\native\IksNative.cs).
# Installed copy: compiled once into bin\IksNative-<version>.dll (fast to load).
# Source copy / missing DLL: compiled in memory (about 0.2 s). Both use the
# C# compiler of the .NET Framework that ships with Windows 10/11.
# The version inside the helper comes from app\VERSION (token __IKS_VERSION__): one source.

function Get-IKSNativeSource { return ([IO.File]::ReadAllText($script:IKS.NativeSrc)).Replace('__IKS_VERSION__', $script:IKS.Version) }

function Import-IKSNative {
    if ('IKS.Native.WfpSession' -as [type]) { return }
    if (Test-Path -LiteralPath $script:IKS.NativeDll) {
        try { Add-Type -LiteralPath $script:IKS.NativeDll; return } catch { Write-IKSLog "native DLL could not be loaded, compiling in memory: $_" 'WARN' }
    }
    if ('IKS.Native.WfpSession' -as [type]) { return }
    Add-Type -TypeDefinition (Get-IKSNativeSource)
}

# Compile the helper into bin\ (installer only). Old versions are removed when not in use.
function Build-IKSNative([string]$Root) {
    $bin = Join-Path $Root 'bin'
    New-Item -ItemType Directory -Force $bin | Out-Null
    Get-ChildItem $bin -Filter 'IksNative-*.dll' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $script:IKS.NativeDll } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $script:IKS.NativeDll)) {
        Add-Type -TypeDefinition (Get-IKSNativeSource) -OutputAssembly $script:IKS.NativeDll -OutputType Library
    }
    return $script:IKS.NativeDll
}

# IranKillSwitch.exe: asks for admin once (manifest) and HOSTS PowerShell in-process to run
# the GUI. One process named "Iran Kill Switch" with the app icon (Task Manager, taskbar),
# never a console window. Execution policy: process scope Bypass, inherited by the GUI's jobs.
function Build-IKSLauncher([string]$Root) {
    $bin = Join-Path $Root 'bin'
    $exe = Join-Path $Root 'IranKillSwitch.exe'
    $ico = Join-Path $bin 'IranKillSwitch.ico'
    $man = Join-Path $bin 'launcher.manifest'
    New-IKSIconFile $ico
    @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>
    <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
  </requestedPrivileges></security></trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
  </application></compatibility>
</assembly>
'@ | Set-Content -Path $man -Encoding UTF8
    $code = @'
using System; using System.IO; using System.Threading;
using System.Management.Automation; using System.Management.Automation.Runspaces;
[assembly: System.Reflection.AssemblyTitle("Iran Kill Switch")]
[assembly: System.Reflection.AssemblyProduct("Iran Kill Switch")]
[assembly: System.Reflection.AssemblyCompany("Mansoor")]
[assembly: System.Reflection.AssemblyCopyright("Made by Mansoor")]
[assembly: System.Reflection.AssemblyVersion("__IKS_VERSION__.0")]
[assembly: System.Reflection.AssemblyFileVersion("__IKS_VERSION__.0")]
public static class Launcher {
    [STAThread] public static int Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");
        try {
            using (Runspace rs = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault())) {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create()) {
                    ps.Runspace = rs;
                    ps.AddCommand(Path.Combine(dir, "IKS.Gui.ps1"));
                    ps.Invoke();
                }
            }
            return 0;
        } catch (Exception ex) {
            try { File.AppendAllText(Path.Combine(dir, @"state\iks.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [ERROR] launcher: " + ex.Message + Environment.NewLine); } catch { }
            return 1;
        }
    }
}
'@
    $code = $code.Replace('__IKS_VERSION__', $script:IKS.Version)
    if (Test-Path $exe) { Remove-Item $exe -Force }
    $cp = New-Object System.CodeDom.Compiler.CompilerParameters
    $cp.GenerateExecutable = $true
    $cp.OutputAssembly = $exe
    $cp.CompilerOptions = "/target:winexe /win32manifest:`"$man`" /win32icon:`"$ico`""
    $null = $cp.ReferencedAssemblies.Add('System.dll')
    $null = $cp.ReferencedAssemblies.Add('System.Core.dll')
    $null = $cp.ReferencedAssemblies.Add([PSObject].Assembly.Location)     # System.Management.Automation (Windows PowerShell 5.1)
    Add-Type -TypeDefinition $code -CompilerParameters $cp
    return $exe
}

# Shield-ring icon (16/32/48 px) drawn with System.Drawing, written as a real .ico file.
function New-IKSIconFile([string]$Path, [string]$Hex = '#34D399') {
    Add-Type -AssemblyName System.Drawing
    $sizes = 16, 32, 48
    $pngs = foreach ($s in $sizes) {
        $bmp = New-Object Drawing.Bitmap $s, $s
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = [Math]::Max(2, [int]($s / 7))
        $pen = New-Object Drawing.Pen ([Drawing.ColorTranslator]::FromHtml($Hex)), $w
        $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#161A21'))), 0, 0, $s - 1, $s - 1)
        $g.DrawEllipse($pen, $w / 2, $w / 2, $s - $w - 1, $s - $w - 1)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        , $ms.ToArray()
    }
    $fs = [IO.File]::Create($Path); $bw = New-Object IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $bw.Write([byte]$sizes[$i]); $bw.Write([byte]$sizes[$i]); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write([byte[]]$p) }
    $bw.Close()
}
