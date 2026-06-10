# ValueGuard Windows tester setup (issue #41).
# Run from the extracted zip:  powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
# Installs to %LOCALAPPDATA%\ValueGuard (app, models, policy.bin, audit.log),
# adds an HKCU Run autostart, and starts the daemon (log-only - this build
# never blurs or blocks anything). The extracted zip folder can be deleted
# afterwards. Every downloaded artifact is SHA-256 verified before use.

$ErrorActionPreference = "Stop"

$ReleaseTag = "windows-tester-v0.1.0"
$AssetBase  = "https://github.com/Sincera-Works/valueguard/releases/download/$ReleaseTag"

$Hashes = @{
    model    = "dd5f1505c2057a17e0d8cc8438e1d61cdc95737e26e94c9b94c52a3395623003"  # SigLIP2Vision.fp32.onnx
    python   = "71bd44e6b0e91c17558963557e4cdb80b483de9b0a0a9717f06cf896f95ab598"  # python-3.12.8-amd64.exe (python.org, immutable URL)
    vcredist = "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"  # vc_redist.x64.exe (pinned copy attached to OUR release)
    policy   = "a81055ef5d6fd5f301345b4236a32feb521529c2dd079045fb9b7b8b4c863435"  # default.policy.bin (bundled in the zip)
}

$Base   = Join-Path $env:LOCALAPPDATA "ValueGuard"
$AppDir = Join-Path $Base "app"
$Models = Join-Path $Base "models"
$ModelPath  = Join-Path $Models "SigLIP2Vision.fp32.onnx"
$PolicyPath = Join-Path $Base "policy.bin"
$CmdPath    = Join-Path $Base "valueguard.cmd"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Hash($path, $expected, $label) {
    $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
    if ($actual -ne $expected) {
        Remove-Item $path -Force
        throw "$label failed SHA-256 verification (got $actual) - aborting. Re-download the release."
    }
    Write-Host "  [ok] $label hash verified"
}

function Get-VGProcess {
    # Deterministic identity: OUR venv's executable AND our module invocation.
    Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -like "$AppDir\*" -and $_.CommandLine -like "*-m valueguard_daemon*"
    }
}

if (Get-VGProcess) {
    Write-Host "ValueGuard is already running - setup will not double-start it. Run uninstall.ps1 first if you want a clean reinstall."
    exit 0
}

New-Item -ItemType Directory -Force -Path $AppDir, $Models | Out-Null

# --- Python 3.12 (per-user) ---------------------------------------------
$Py = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
if (Test-Path $Py) {
    Write-Host "[skip] Python 3.12 already present"
} else {
    Write-Host "[1/6] Installing Python 3.12 (per-user)..."
    $pyExe = Join-Path $env:TEMP "python-3.12.8-amd64.exe"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe" -OutFile $pyExe
    Assert-Hash $pyExe $Hashes.python "Python installer"
    Start-Process $pyExe -ArgumentList "/quiet InstallAllUsers=0 PrependPath=0 Include_test=0" -Wait
    if (-not (Test-Path $Py)) { throw "Python install did not produce $Py" }
}

# --- VC++ runtime (onnxruntime needs it) --------------------------------
$vcOk = Test-Path "$env:SystemRoot\System32\msvcp140.dll"
if ($vcOk) {
    Write-Host "[skip] VC++ runtime already present"
} else {
    Write-Host "[2/6] Installing VC++ runtime..."
    $vcExe = Join-Path $env:TEMP "vc_redist.x64.exe"
    Invoke-WebRequest -Uri "$AssetBase/vc_redist.x64.exe" -OutFile $vcExe
    Assert-Hash $vcExe $Hashes.vcredist "VC++ redistributable"
    Start-Process $vcExe -ArgumentList "/install /quiet /norestart" -Wait
}

# --- App + venv -----------------------------------------------------------
Write-Host "[3/6] Installing the daemon to $AppDir..."
Copy-Item -Recurse -Force (Join-Path $Here "daemon-py\*") $AppDir
if (-not (Test-Path (Join-Path $AppDir ".venv"))) {
    & $Py -m venv (Join-Path $AppDir ".venv")
}
# --require-hashes: every dependency wheel is SHA-256-pinned in
# requirements-windows.lock (generated on the target cp312/win_amd64 platform),
# so the PyPI fetch is part of the verified trust chain like the model and
# installers. --only-binary keeps us on the hashed wheels.
& (Join-Path $AppDir ".venv\Scripts\python.exe") -m pip install -q --require-hashes --only-binary :all: -r (Join-Path $AppDir "requirements-windows.lock")

# --- Model ----------------------------------------------------------------
$modelValid = (Test-Path $ModelPath) -and ((Get-FileHash -Algorithm SHA256 $ModelPath).Hash.ToLower() -eq $Hashes.model)
if ($modelValid) {
    Write-Host "[skip] model already present and hash-valid"
} else {
    Write-Host "[4/6] Downloading the vision model (~372 MB, one time)..."
    Invoke-WebRequest -Uri "$AssetBase/SigLIP2Vision.fp32.onnx" -OutFile $ModelPath
    Assert-Hash $ModelPath $Hashes.model "model"
}

# --- Policy (never overwrite an existing one) ----------------------------
if (Test-Path $PolicyPath) {
    Write-Host "[skip] policy.bin already present - keeping it"
} else {
    Write-Host "[5/6] Installing the default policy..."
    Copy-Item (Join-Path $Here "default.policy.bin") $PolicyPath
    Assert-Hash $PolicyPath $Hashes.policy "default policy"
}

# --- Autostart + start ----------------------------------------------------
Write-Host "[6/6] Autostart + first run..."
# (a line array, not a here-string - Windows PowerShell 5.1 misparses
# here-strings in LF-line-ending files)
$cmdLines = @(
    '@echo off',
    'rem ValueGuard daemon launcher. Self-disables if the install is incomplete.',
    "if not exist `"$AppDir\.venv\Scripts\pythonw.exe`" exit /b 0",
    "if not exist `"$ModelPath`" exit /b 0",
    "if not exist `"$PolicyPath`" exit /b 0",
    "cd /d `"$AppDir`"",
    "start `"`" `"$AppDir\.venv\Scripts\pythonw.exe`" -m valueguard_daemon --model `"$ModelPath`""
)
Set-Content -Path $CmdPath -Value $cmdLines -Encoding ascii

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "ValueGuard" -Value "`"$CmdPath`""
& $CmdPath

Start-Sleep 5
if (Get-VGProcess) {
    Write-Host ""
    Write-Host "ValueGuard is running (log-only). It starts automatically when you log in."
    Write-Host "  Flags it would have acted on: $Base\audit.log"
    Write-Host "  Uninstall: powershell -ExecutionPolicy Bypass -File .\uninstall.ps1"
} else {
    throw "Daemon did not stay up - check $Base for clues and report at https://github.com/Sincera-Works/valueguard/issues"
}
