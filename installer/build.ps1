# ──────────────────────────────────────────────────────────────
#  Builds installer\dist\Samanvaya_Setup_<version>.exe
#
#    powershell -ExecutionPolicy Bypass -File installer\build.ps1
#
#  Needs, on the BUILD machine only:
#    - Python 3.12 (py -3.12) — used once to pip-install the packages
#      into the bundled runtime. Its minor version must match $PyVersion.
#    - Inno Setup 6 (winget install JRSoftware.InnoSetup)
#  End users need neither: Python ships inside the setup exe.
# ──────────────────────────────────────────────────────────────
$ErrorActionPreference = 'Stop'

$PyVersion = '3.12.10'
$PyTag     = 'python312'

$Here  = $PSScriptRoot
$Root  = Split-Path $Here
$Build = Join-Path $Here 'build'
$Cache = Join-Path $Build 'cache'
$Py    = Join-Path $Build 'python'
$Ver   = (Get-Content (Join-Path $Root 'VERSION') -Raw).Trim()

New-Item -ItemType Directory -Force $Cache | Out-Null

# ── 1. Embeddable Python (official python.org build) ─────────────
$Zip = Join-Path $Cache "python-$PyVersion-embed-amd64.zip"
if (-not (Test-Path $Zip)) {
    $Url = "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-amd64.zip"
    Write-Host "[build] Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing
}
if (Test-Path $Py) { Remove-Item -Recurse -Force $Py }
Expand-Archive -Path $Zip -DestinationPath $Py

# The ._pth file fixes sys.path for the embeddable build. Turn on
# "import site" and add Lib\site-packages so the packages below load.
@(
    "$PyTag.zip"
    '.'
    'Lib\site-packages'
    'import site'
) | Set-Content -Encoding ascii (Join-Path $Py "$PyTag._pth")

# ── 2. Packages: thin client + direct mode, so both work offline ──
$Site = Join-Path $Py 'Lib\site-packages'
Write-Host "[build] Installing packages into the bundled runtime"
& py -3.12 -m pip install --disable-pip-version-check --no-warn-script-location `
    --only-binary=:all: --target $Site `
    -r (Join-Path $Root 'requirements.txt') `
    -r (Join-Path $Root 'requirements-direct.txt')
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
# Console entry-point stubs (Scripts\*.exe) hard-code the build machine's
# Python path and are useless on another PC.
$Stubs = Join-Path $Site 'bin'
if (Test-Path $Stubs) { Remove-Item -Recurse -Force $Stubs }
# Package test suites and bytecode caches are dead weight, and their deep
# paths (google\genai\tests\afc\__pycache__\...) can cross Windows' 260-char
# MAX_PATH under a long user profile, which makes the install roll back.
# Python rebuilds __pycache__ on the user's machine on first import.
Get-ChildItem $Site -Recurse -Directory -Include 'tests', '__pycache__' |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

# ── 3. Smoke test the runtime exactly as REAPER will call it ─────
& (Join-Path $Py 'python.exe') -c "import ssl, certifi, truststore, numpy, soundfile, google.genai; print('[build] runtime OK')"
if ($LASTEXITCODE -ne 0) { throw "bundled runtime failed its import test" }

# ── 4. Compile the installer ─────────────────────────────────────
$Iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Iscc) { throw "Inno Setup 6 not found. Install it: winget install JRSoftware.InnoSetup" }

& $Iscc /Q "/DAppVersion=$Ver" (Join-Path $Here 'Samanvaya.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
Write-Host "[build] Done: $(Join-Path $Here "dist\Samanvaya_Setup_$Ver.exe")"
