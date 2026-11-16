<#
  BatteryLogger.ps1 - portable, low-overhead battery-life logger (Windows 10/11, PowerShell 5.1+)

  Modes:  Start   launch the hidden background logger (what Start.bat does)
          Run     the logger itself (started by Start)
          Stop    signal the logger to stop cleanly, export Windows reports, print summary
          Report  summarize the newest (or -Session) log folder
          Recover finalize a session whose logger died with the battery (runs automatically at next logon)
          Export  write powercfg battery report + per-app energy (SRUM) csv (needs admin)
#>
param(
    [ValidateSet('Start','Run','Stop','Report','Recover','Export')][string]$Mode = 'Start',
    [string]$Session,
    [int]$Interval = 0,         # override normal sample interval (seconds), for testing
    [switch]$BatterySaver       # run the test with Windows Battery saver forced on while on battery
)

# ----------------------------- settings you can edit -----------------------------
$NormalInterval   = 30     # seconds between samples above 10%
$LowInterval      = 10     # seconds between samples at <=10%
$CriticalInterval = 2      # seconds between samples at <=4%  (so the final record is within ~2 s of death)
$KeepDisplayOn    = $true  # $true = screen never turns off (consistent test). $false = let normal screen timeout work
$TopProcs         = 5      # how many top CPU processes to log per sample
# ---------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Data      = Join-Path $Root 'data'
$StateFile = Join-Path $Data 'state.json'
$StopName  = 'BatteryLoggerStop'
$TaskName  = 'BatteryLoggerRecover'
$GuidRx    = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
if ($Interval -gt 0) { $NormalInterval = $Interval; $LowInterval = $Interval; $CriticalInterval = $Interval }

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Now-Str { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }

# Append a line and force it to physical disk (write-through) so a sudden power loss keeps it.
function Append-Line([string]$Path, [string]$Line) {
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $b = [Text.Encoding]::UTF8.GetBytes($Line + "`r`n")
        $fs.Write($b, 0, $b.Length)
        $fs.Flush($true)
    } finally { $fs.Dispose() }
}
function Log-Event([string]$Dir, [string]$Text) { Append-Line (Join-Path $Dir 'events.log') ("{0}  {1}" -f (Now-Str), $Text) }

function Read-State  { if (Test-Path $StateFile) { try { Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $null } } }
function Write-State($o) { $o | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 }

function Test-LoggerAlive($s) {
    if (-not $s -or -not $s.pid) { return $false }
    $p = Get-Process -Id $s.pid -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    try { return ($p.StartTime.ToString('o') -eq $s.procStart) } catch { return $false }
}

# ------------------------------ power plan handling ------------------------------
function Get-GuidFrom([string]$text) { if ($text -match $GuidRx) { $Matches[0] } }

function Set-TestPowerPlan([bool]$Saver = $false) {
    $orig = Get-GuidFrom ((powercfg /getactivescheme) | Out-String)
    $new  = Get-GuidFrom ((powercfg /duplicatescheme $orig) | Out-String)
    if (-not $orig -or -not $new) { throw 'Could not duplicate the active power plan.' }
    powercfg /changename $new 'Battery Test (temporary)' 'Created by BatteryLogger; removed automatically.' | Out-Null
    powercfg /setactive $new | Out-Null
    foreach ($k in 'ac','dc') {
        powercfg /change standby-timeout-$k 0   | Out-Null   # never sleep
        powercfg /change hibernate-timeout-$k 0 | Out-Null   # never hibernate
        if ($KeepDisplayOn) { powercfg /change monitor-timeout-$k 0 | Out-Null }
    }
    powercfg /setacvalueindex $new SUB_BUTTONS LIDACTION 0 | Out-Null
    powercfg /setdcvalueindex $new SUB_BUTTONS LIDACTION 0 | Out-Null  # lid close = do nothing
    powercfg /setdcvalueindex $new SUB_BATTERY BATACTIONLOW 0  | Out-Null   # low battery action = do nothing
    powercfg /setdcvalueindex $new SUB_BATTERY BATACTIONCRIT 0 | Out-Null   # critical battery action = do nothing (run until it dies)
    if ($Saver) {
        # Battery saver turns on automatically below this charge % while on battery; 100 = always on during the test.
        powercfg /setdcvalueindex $new de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 100 | Out-Null
    }
    powercfg /setactive $new | Out-Null
    [pscustomobject]@{ orig = $orig; temp = $new }
}

function Restore-PowerPlan($s) {
    if (-not $s -or -not $s.origPlan) { return }
    $list = (powercfg /list) | Out-String
    if ($list -match [regex]::Escape($s.origPlan)) { powercfg /setactive $s.origPlan | Out-Null }
    if ($s.tempPlan -and $list -match [regex]::Escape($s.tempPlan)) { powercfg /delete $s.tempPlan | Out-Null }
}

# ------------------------------- recovery / export -------------------------------
function Export-Reports([string]$Dir) {
    if (-not (Test-Admin)) { Write-Host 'Not admin: skipped powercfg report exports.'; return }
    try { powercfg /batteryreport /output (Join-Path $Dir 'battery-report.html') | Out-Null } catch {}
    try { powercfg /srumutil /output (Join-Path $Dir 'srum-energy-per-app.csv') /format csv | Out-Null } catch {}
}

# Finalize a session whose logger is gone without a clean stop (= the battery died / power was cut).
function Invoke-Recover {
    $s = Read-State
    if (-not $s) { return $false }
    if (Test-LoggerAlive $s) { return $false }
    $dir = $s.session
    if ($dir -and (Test-Path $dir)) {
        $lastLine = $null
        $csv = Join-Path $dir 'samples.csv'
        if (Test-Path $csv) { $lastLine = Get-Content $csv -Tail 1 }
        $f = if ($lastLine) { $lastLine -split ',' } else { @() }
        $lastTs = if ($f.Count -gt 3) { "$($f[0]) ($($f[3])%)" } else { 'n/a' }
        Log-Event $dir "UNCLEAN END - logger stopped without a clean shutdown: battery most likely died / power was lost. LAST RECORDED SAMPLE: $lastTs"
        try {
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
            Log-Event $dir "System booted again at $($boot.ToString('yyyy-MM-dd HH:mm:ss')) (this is when the laptop came back, not when it died)."
        } catch {}
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008; StartTime = [datetime]$s.started } -MaxEvents 6 -ErrorAction Stop |
                ForEach-Object { Log-Event $dir ("Windows event {0} at {1}: {2}" -f $_.Id, $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), (($_.Message -split "`n")[0]).Trim()) }
        } catch {}
        Export-Reports $dir
    }
    Restore-PowerPlan $s
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    return $true
}

# ----------------------------------- sampling -----------------------------------
function Get-Wmi([string]$Class, [string]$Ns = 'root\cimv2') {
    Get-CimInstance -Namespace $Ns -ClassName $Class -ErrorAction SilentlyContinue | Select-Object -First 1
}

$script:prevCpu = $null
function Get-TopProcessString {
    $cur = @{}; $by = @{}; $first = ($null -eq $script:prevCpu)
    foreach ($p in [Diagnostics.Process]::GetProcesses()) {
        try {
            $id = $p.Id
            if ($id -eq $PID -or $id -eq 0) { continue }
            $t = $p.TotalProcessorTime.TotalSeconds
            $cur[$id] = $t
            if (-not $first) {
                $prev = 0.0; if ($script:prevCpu.ContainsKey($id)) { $prev = $script:prevCpu[$id] }
                $d = $t - $prev
                if ($d -gt 0.005) { $by[$p.ProcessName] += $d }
            }
        } catch {} finally { $p.Dispose() }
    }
    $script:prevCpu = $cur
    if ($first -or $by.Count -eq 0) { return '' }
    (($by.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopProcs |
        ForEach-Object { '{0}={1:0.00}' -f ($_.Key -replace '[^\w\.\-\+ ]', '_'), $_.Value }) -join '|')
}

$CsvHeader = 'timestamp,epoch_s,elapsed_s,pct_windows,pct_calc,remaining_mwh,full_mwh,voltage_mv,discharge_mw,charge_mw,on_ac,brightness,cpu_util_pct,cpu_perf_pct,interval_s,sample_cost_ms,logger_cpu_s,top_procs_cpu_s'

# ------------------------------------- modes -------------------------------------
switch ($Mode) {

'Start' {
    if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Path $Data | Out-Null }
    $s = Read-State
    if (Test-LoggerAlive $s) { Write-Host "Logger is already running. Log folder: $($s.session)"; return }
    if (-not (Test-Admin)) { Write-Host 'NOTE: not running as admin - per-process data and auto-recovery will be limited. Use Start.bat.' }
    $bat = Get-Wmi Win32_Battery
    if (-not $bat) { Write-Host 'WARNING: no battery detected on this machine.' }
    elseif ($bat.BatteryStatus -ne 1) { Write-Host 'NOTE: charger is plugged in. Unplug it to begin the discharge test (logging works either way).' }
    $args2 = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode Run"
    if ($Interval -gt 0) { $args2 += " -Interval $Interval" }
    if ($BatterySaver) { $args2 += " -BatterySaver" }
    Start-Process powershell.exe -ArgumentList $args2 -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $s = Read-State
        if ($s -and (Test-Path (Join-Path $s.session 'samples.csv'))) { break }
    }
    if ($s -and $s.session) {
        Write-Host "Logger started in the background (PID $($s.pid))."
        Write-Host "Log folder: $($s.session)"
        if ($BatterySaver) { Write-Host 'Battery saver: ON for this test.' }
        Write-Host 'Sleep/hibernate/lid-close/critical-battery actions are disabled until you run Stop.bat (or the laptop dies).'
        Write-Host 'You can close this window. Leave the laptop alone, unplugged, until it dies.'
    } else { Write-Host 'The logger did not start - check data\startup-error.log' }
}

'Run' {
    if (-not (Test-Path $Data)) { New-Item -ItemType Directory -Path $Data | Out-Null }
    $errLog = Join-Path $Data 'startup-error.log'
    try {
        $old = Read-State
        if (Test-LoggerAlive $old) { return }
        if ($old) { Invoke-Recover | Out-Null }          # previous run ended by battery death

        $me = Get-Process -Id $PID
        try { $me.PriorityClass = 'BelowNormal' } catch {}
        $stop = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $StopName)

        $dir = Join-Path $Data ("{0}_{1}" -f $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $csv = Join-Path $dir 'samples.csv'
        Append-Line $csv $CsvHeader

        # machine / battery info
        $cs = Get-Wmi Win32_ComputerSystem; $os = Get-Wmi Win32_OperatingSystem; $cpu = Get-Wmi Win32_Processor
        $des = Get-Wmi BatteryStaticData 'root\wmi'; $fc = Get-Wmi BatteryFullChargedCapacity 'root\wmi'; $cyc = Get-Wmi BatteryCycleCount 'root\wmi'
        $info = @(
            "Computer : $env:COMPUTERNAME  ($($cs.Manufacturer) $($cs.Model))",
            "OS       : $($os.Caption) $($os.Version)",
            "CPU      : $($cpu.Name)",
            "Battery design capacity : $($des.DesignedCapacity) mWh",
            "Battery full-charge cap : $($fc.FullChargedCapacity) mWh",
            "Battery cycle count     : $($cyc.CycleCount)",
            "Keep display on         : $KeepDisplayOn",
            "Battery saver           : $(if ($BatterySaver) { 'ON (forced for whole test)' } else { 'off (normal power settings)' })",
            "Started                 : $(Now-Str)")
        Set-Content (Join-Path $dir 'info.txt') $info -Encoding UTF8

        $plan = Set-TestPowerPlan ([bool]$BatterySaver)
        Write-State ([pscustomobject]@{ pid = $PID; procStart = $me.StartTime.ToString('o'); session = $dir; started = (Get-Date).ToString('o'); origPlan = $plan.orig; tempPlan = $plan.temp })

        # keep system (and optionally display) awake for as long as this thread lives
        Add-Type -Namespace Win32 -Name Power -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
        $es = if ($KeepDisplayOn) { 2147483651 } else { 2147483649 }   # CONTINUOUS | SYSTEM_REQUIRED [| DISPLAY_REQUIRED]
        [Win32.Power]::SetThreadExecutionState([uint32]$es) | Out-Null

        # one-time counters
        $cUtil = $null; $cPerf = $null
        try {
            $cUtil = New-Object Diagnostics.PerformanceCounter('Processor Information', '% Processor Utility', '_Total')
            $cPerf = New-Object Diagnostics.PerformanceCounter('Processor Information', '% Processor Performance', '_Total')
            [void]$cUtil.NextValue(); [void]$cPerf.NextValue()
        } catch { $cUtil = $null; $cPerf = $null }
        [void](Get-TopProcessString)   # baseline

        Log-Event $dir "START logger PID $PID. Power plan switched to temporary no-sleep plan."
        $tickStart = [Diagnostics.Stopwatch]::StartNew()
        $lastEpoch = $null; $lastAc = $null; $interval = $NormalInterval
        $lastSelf = 0.0

        while ($true) {
            $t0 = [Diagnostics.Stopwatch]::StartNew()
            try {
                $bs = Get-Wmi BatteryStatus 'root\wmi'
                $wb = Get-Wmi Win32_Battery
                $br = Get-Wmi WmiMonitorBrightness 'root\wmi'
                $fcNow = (Get-Wmi BatteryFullChargedCapacity 'root\wmi').FullChargedCapacity
                $rem  = $bs.RemainingCapacity
                $pctC = if ($fcNow -gt 0 -and $null -ne $rem) { [math]::Round(100.0 * $rem / $fcNow, 2) } else { $null }
                $pctW = $wb.EstimatedChargeRemaining
                $ac   = if ($bs) { [int][bool]$bs.PowerOnline } else { [int]($wb.BatteryStatus -ne 1) }
                $util = if ($cUtil) { [math]::Round($cUtil.NextValue(), 1) } else { $null }
                $perf = if ($cPerf) { [math]::Round($cPerf.NextValue(), 1) } else { $null }
                $procs = Get-TopProcessString
                $nowE = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000.0

                if ($null -ne $lastAc -and $ac -ne $lastAc) { Log-Event $dir ($(if ($ac) { 'CHARGER PLUGGED IN' } else { 'CHARGER UNPLUGGED' })) }
                $lastAc = $ac
                if ($lastEpoch -and ($nowE - $lastEpoch) -gt ($interval * 2.5 + 5)) {
                    Log-Event $dir ("GAP of {0:0} s between samples (expected {1} s) - system may have been suspended or starved." -f ($nowE - $lastEpoch), $interval)
                }
                $lastEpoch = $nowE

                $pct = if ($null -ne $pctC) { $pctC } else { $pctW }
                $interval = if ($null -ne $pct -and $pct -le 4) { $CriticalInterval } elseif ($null -ne $pct -and $pct -le 10) { $LowInterval } else { $NormalInterval }

                $me.Refresh(); $self = [math]::Round($me.TotalProcessorTime.TotalSeconds, 2)
                $cost = [int]$t0.ElapsedMilliseconds
                $row = @((Now-Str), ('{0:0.000}' -f $nowE), [int]$tickStart.Elapsed.TotalSeconds, $pctW, $pctC, $rem, $fcNow, $bs.Voltage, $bs.DischargeRate, $bs.ChargeRate, $ac, $br.CurrentBrightness, $util, $perf, $interval, $cost, $self, ('"' + $procs + '"')) -join ','
                Append-Line $csv $row
            } catch {
                try { Log-Event $dir "Sample error: $($_.Exception.Message)" } catch {}
            }
            $wait = [Math]::Max(200, $interval * 1000 - [int]$t0.ElapsedMilliseconds)
            if ($stop.WaitOne($wait)) { break }      # zero-CPU sleep; Stop.bat sets this event
        }

        Log-Event $dir 'CLEAN STOP requested by user.'
        [Win32.Power]::SetThreadExecutionState([uint32]2147483648) | Out-Null
        Restore-PowerPlan (Read-State)
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Log-Event $dir 'Original power plan restored.'
    } catch {
        Add-Content $errLog ("{0}  {1}`r`n{2}" -f (Now-Str), $_.Exception.Message, $_.ScriptStackTrace)
    }
}

'Stop' {
    $s = Read-State
    try {
        $ev = [Threading.EventWaitHandle]::OpenExisting($StopName)
        [void]$ev.Set()
        for ($i = 0; $i -lt 60 -and (Test-Path $StateFile); $i++) { Start-Sleep -Milliseconds 500 }
        Write-Host 'Logger stopped; original power plan restored.'
    } catch {
        if ($s) { Write-Host 'Logger was not running (stale session) - finalizing.'; Invoke-Recover | Out-Null }
        else { Write-Host 'Logger is not running.' }
    }
    if ($s -and $s.session) { Export-Reports $s.session; & $PSCommandPath -Mode Report -Session $s.session }
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

'Recover' {
    $did = Invoke-Recover
    $s = Read-State
    if (-not (Test-LoggerAlive $s)) { try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {} }
    if ($did) {
        $d = Get-ChildItem $Data -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d) { & $PSCommandPath -Mode Report -Session $d.FullName | Out-Null }
    }
}

'Export' {
    $d = if ($Session) { $Session } else { (Get-ChildItem $Data -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
    Export-Reports $d; Write-Host "Exported into $d"
}

'Report' {
    $dir = $Session
    if (-not $dir) { $dir = (Get-ChildItem $Data -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
    if (-not $dir -or -not (Test-Path (Join-Path $dir 'samples.csv'))) { Write-Host 'No log data found.'; return }
    $rows = @(Import-Csv (Join-Path $dir 'samples.csv'))
    if ($rows.Count -lt 2) { Write-Host 'Not enough samples yet.'; return }
    function N($v) { if ($null -eq $v -or $v -eq '') { $null } else { [double]$v } }

    # longest contiguous run on battery
    $best = @(); $cur = @()
    foreach ($r in $rows) { if ($r.on_ac -eq '0') { $cur += $r } else { if ($cur.Count -gt $best.Count) { $best = $cur }; $cur = @() } }
    if ($cur.Count -gt $best.Count) { $best = $cur }
    $seg = if ($best.Count -ge 2) { $best } else { $rows }

    $first = $seg[0]; $last = $seg[-1]
    $runSec = (N $last.epoch_s) - (N $first.epoch_s)
    $pS = if ($first.pct_calc) { N $first.pct_calc } else { N $first.pct_windows }
    $pE = if ($last.pct_calc)  { N $last.pct_calc }  else { N $last.pct_windows }
    $evt = Join-Path $dir 'events.log'
    $evText = if (Test-Path $evt) { Get-Content $evt } else { @() }
    $died = [bool]($evText -match 'UNCLEAN END')

    # weighted averages over the segment
    $wSum = 0.0; $wDis = 0.0; $wBr = 0.0; $nBr = 0.0; $wCpu = 0.0; $nCpu = 0.0; $wPerf = 0.0; $nPerf = 0.0
    $bands = @{}; $procSum = @{}
    for ($i = 1; $i -lt $seg.Count; $i++) {
        $r = $seg[$i]; $dt = (N $r.epoch_s) - (N $seg[$i-1].epoch_s)
        if ($dt -le 0 -or $dt -gt 600) { continue }
        $dis = N $r.discharge_mw; $br = N $r.brightness; $cu = N $r.cpu_util_pct; $cp = N $r.cpu_perf_pct
        $pp = if ($r.pct_calc) { N $r.pct_calc } else { N $r.pct_windows }
        $wSum += $dt
        if ($null -ne $dis) { $wDis += $dis * $dt }
        if ($null -ne $br)  { $wBr += $br * $dt; $nBr += $dt }
        if ($null -ne $cu)  { $wCpu += $cu * $dt; $nCpu += $dt }
        if ($null -ne $cp)  { $wPerf += $cp * $dt; $nPerf += $dt }
        if ($null -ne $pp) {
            $b = [int]([math]::Floor($pp / 10) * 10)
            if (-not $bands.ContainsKey($b)) { $bands[$b] = [pscustomobject]@{ t = 0.0; dis = 0.0; cpu = 0.0; ct = 0.0 } }
            $bands[$b].t += $dt; if ($null -ne $dis) { $bands[$b].dis += $dis * $dt }
            if ($null -ne $cu) { $bands[$b].cpu += $cu * $dt; $bands[$b].ct += $dt }
        }
        $pr = $r.top_procs_cpu_s
        if ($pr) { foreach ($e in ($pr -split '\|')) { $kv = $e -split '='; if ($kv.Count -eq 2) { $procSum[$kv[0]] += [double]$kv[1] } } }
    }
    $remS = N $first.remaining_mwh; $remE = N $last.remaining_mwh
    $energy = if ($null -ne $remS -and $null -ne $remE) { $remS - $remE } else { $null }
    $hrs = $runSec / 3600.0
    $o = New-Object Collections.Generic.List[string]
    $o.Add('==================== BATTERY TEST REPORT ====================')
    $o.Add((Get-Content (Join-Path $dir 'info.txt') -ErrorAction SilentlyContinue | Select-Object -First 6) -join "`r`n")
    $o.Add('')
    $o.Add("Discharge started : $($first.timestamp)   at $pS %")
    $o.Add("Last sample       : $($last.timestamp)   at $pE %   <- $(if ($died) { 'BATTERY DIED (last second recorded)' } else { 'logger stopped cleanly' })")
    $o.Add(('Battery runtime   : {0:0}h {1:00}m {2:00}s' -f [math]::Floor($runSec/3600), [math]::Floor(($runSec%3600)/60), ($runSec%60)))
    if ($pS -and $pS -gt $pE) { $o.Add(('Average drain     : {0:0.0} %/hour   (projected 100->0 : {1:0.0} h)' -f (($pS-$pE)/$hrs), (100/(($pS-$pE)/$hrs)))) }
    if ($null -ne $energy -and $hrs -gt 0) { $o.Add(('Energy used       : {0:0} mWh  = average {1:0.00} W (from capacity counter)' -f $energy, ($energy/1000/$hrs))) }
    if ($wSum -gt 0 -and $wDis -gt 0) { $o.Add(('Avg reported draw : {0:0.00} W (battery discharge-rate sensor)' -f ($wDis/$wSum/1000))) }
    if ($nBr -gt 0)   { $o.Add(('Avg brightness    : {0:0} %' -f ($wBr/$nBr))) }
    if ($nCpu -gt 0)  { $o.Add(('Avg CPU utility   : {0:0.0} %' -f ($wCpu/$nCpu))) }
    if ($nPerf -gt 0) { $o.Add(('Avg CPU frequency : {0:0} % of base' -f ($wPerf/$nPerf))) }
    $o.Add('')
    $o.Add('--- Drain by charge band (where the power went over the discharge) ---')
    $o.Add('Band      Time      Avg W    Avg CPU%')
    foreach ($k in ($bands.Keys | Sort-Object -Descending)) {
        $b = $bands[$k]
        $o.Add(('{0,3}-{1,3}%  {2,6:0.0} m  {3,6:0.00}  {4,6:0.0}' -f $k, ($k+10), ($b.t/60), $(if ($b.t) { $b.dis/$b.t/1000 } else { 0 }), $(if ($b.ct) { $b.cpu/$b.ct } else { 0 })))
    }
    $o.Add('')
    $o.Add("--- Top CPU consumers (CPU-seconds, from the top $TopProcs per sample) ---")
    $tot = ($procSum.Values | Measure-Object -Sum).Sum
    foreach ($e in ($procSum.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15)) {
        $o.Add(('{0,-32} {1,9:0.0} s   {2,5:0.0} %   (~{3:0.0}% of one core on average)' -f $e.Key, $e.Value, (100*$e.Value/$tot), (100*$e.Value/$runSec)))
    }
    $selfCpu = (N $last.logger_cpu_s); $costAvg = ($seg | ForEach-Object { N $_.sample_cost_ms } | Measure-Object -Average).Average
    $o.Add('')
    $o.Add(('--- Logger overhead: used {0:0.0} CPU-seconds total ({1:0.000}% of one core), avg sample took {2:0} ms ---' -f $selfCpu, (100*$selfCpu/$runSec), $costAvg))
    $ev2 = @($evText | Where-Object { $_ -match 'UNPLUGGED|PLUGGED|GAP|UNCLEAN|booted|Windows event' })
    if ($ev2.Count) { $o.Add(''); $o.Add('--- Notable events ---'); $ev2 | ForEach-Object { $o.Add($_) } }
    $o.Add('')
    $o.Add('Raw data : samples.csv   | Windows extras (if exported): battery-report.html, srum-energy-per-app.csv')
    $text = $o -join "`r`n"
    Set-Content (Join-Path $dir 'report.txt') $text -Encoding UTF8
    Write-Host $text
}
}
