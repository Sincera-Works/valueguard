# ValueGuard Windows tester uninstall.
# Stops the daemon and removes the autostart entry. Your data
# (%LOCALAPPDATA%\ValueGuard, including the audit log) is left in place -
# delete that folder yourself if you want everything gone.

$ErrorActionPreference = "Stop"
$Base   = Join-Path $env:LOCALAPPDATA "ValueGuard"
$AppDir = Join-Path $Base "app"

$procs = Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -like "$AppDir\*" -and $_.CommandLine -like "*-m valueguard_daemon*"
}
foreach ($p in $procs) {
    Write-Host "stopping ValueGuard daemon (pid $($p.ProcessId))"
    Stop-Process -Id $p.ProcessId -Force
}
Start-Sleep 2
if (Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$AppDir\*" -and $_.CommandLine -like "*-m valueguard_daemon*" }) {
    throw "a ValueGuard daemon process survived Stop-Process - stop it manually (Task Manager) and re-run"
}
if (-not $procs) { Write-Host "no running ValueGuard daemon found" }

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "ValueGuard" -ErrorAction SilentlyContinue
Write-Host "autostart entry removed."
Write-Host "Data kept at $Base (audit log is yours). Delete that folder to remove everything."
