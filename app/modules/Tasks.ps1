# Tasks.ps1 - scheduled tasks (run as SYSTEM, no window).
#   IKS-Guard      : at boot, every 5 min, on network connect -> Action Sync (self-heal)
#   IKS-AutoRevert : one-shot safety net after "Turn ON" -> Action AutoRevert

function Get-IKSTaskAction([string]$ActionName) {
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $entry = Join-Path $script:IKS.InstallDir 'IKS.ps1'
    return New-ScheduledTaskAction -Execute $ps -WorkingDirectory $script:IKS.InstallDir `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$entry`" -Action $ActionName"
}

function Get-IKSSystemPrincipal { return New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest }

function Register-IKSGuardTask {
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5))
    )
    try {   # also when any network connects (NetworkProfile event 10000)
        $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
        $t = New-CimInstance -CimClass $cls -ClientOnly
        $t.Enabled = $true
        $t.Delay = 'PT20S'
        $t.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select></Query></QueryList>'
        $triggers += $t
    } catch { Write-IKSLog "Network event trigger unavailable: $_" 'WARN' }
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:IKS.GuardTask -Action (Get-IKSTaskAction 'Sync') -Trigger $triggers `
        -Settings $set -Principal (Get-IKSSystemPrincipal) -Force `
        -Description 'Iran Kill Switch guard: keeps rules, VPN server IPs and the Iran list up to date.' | Out-Null
}

function Register-IKSRevertTask {
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds($script:IKS.RevertSeconds)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $script:IKS.RevertTask -Action (Get-IKSTaskAction 'AutoRevert') -Trigger $trg `
        -Settings $set -Principal (Get-IKSSystemPrincipal) -Force `
        -Description 'Iran Kill Switch safety net: turns protection off unless you confirmed it works.' | Out-Null
}

function Unregister-IKSTask([string]$Name) {
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-IKSTaskInfo([string]$Name) {
    try {
        $t = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
        $i = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
        return [pscustomobject]@{
            Exists = $true; State = "$($t.State)"
            LastRun = $(if ($i.LastRunTime -and $i.LastRunTime.Year -gt 2000) { $i.LastRunTime } else { $null })
            NextRun = $(if ($i.NextRunTime -and $i.NextRunTime.Year -gt 2000) { $i.NextRunTime } else { $null })
        }
    } catch { return [pscustomobject]@{ Exists = $false; State = ''; LastRun = $null; NextRun = $null } }
}
