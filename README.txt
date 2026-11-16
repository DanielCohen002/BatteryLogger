BATTERY LOGGER - portable battery-life test (Windows 10/11, nothing to install)

TO RUN THE TEST
 1. Charge to 100%, close apps you don't want in the test.
 2. Double-click Start.bat (accept the admin prompt) and pick N (normal) or S (Battery saver forced on for the whole test).
    Start-BatterySaver.bat skips the question and always uses Battery saver. Unplug the charger.
 3. Leave it alone until the laptop dies. Sleep, hibernate, lid-close and low/critical-battery
    shutdown are disabled by a temporary power plan; the screen stays on (edit $KeepDisplayOn in
    BatteryLogger.ps1 to change).
 4. Plug in and boot. Within a minute of logon the recovery task finalizes the log, records the
    death, restores your original power plan and writes report.txt. (Or double-click Report.bat.)

TO STOP EARLY: Stop.bat (restores power plan, exports Windows reports, prints summary).

OUTPUT: data\<PCNAME>_<date>\  samples.csv (raw), events.log, info.txt, report.txt,
        battery-report.html and srum-energy-per-app.csv (Windows' own per-app energy estimates;
        SRUM is flushed about hourly so the last stretch may be missing).
        Copy that folder back to analyse.

HOW THE LAST SECOND IS CAPTURED
 - Every sample is written write-through to disk. Interval: 30 s, 10 s at <=10%, 2 s at <=4%.
 - On the next logon the last sample is marked as the moment of death.

LOW OVERHEAD: sleeps on a kernel event between samples (0% CPU), BelowNormal priority,
 ~tens of ms of work per sample. The report prints the logger's own CPU use.

MOVING IT: copy this whole folder to another laptop. Delete the data folder first if you like.
