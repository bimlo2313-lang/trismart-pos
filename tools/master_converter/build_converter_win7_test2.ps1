<#
.SYNOPSIS
Build TEST2: exclude unused multiprocessing and its startup hook; preserve the failed EXE.
.DESCRIPTION
One-time setup from this directory:
  py -3.8 -m venv .venv-win7
  .\.venv-win7\Scripts\python.exe -m pip install -r requirements-win7.txt
Then run this script. No default Python, automatic installs, or modern output cleanup.
Actual Windows 7 SP1 x64 device testing is still required.
#>
$ErrorActionPreference = 'Stop'
$legacyPython = Join-Path $PSScriptRoot '.venv-win7\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $legacyPython)) {
    throw 'CPython 3.8.10 x64 venv required: run py -3.8 -m venv .venv-win7 in this directory.'
}
Push-Location $PSScriptRoot
try {
    & $legacyPython -c "import sys, struct; print(sys.version); print('Architecture:', struct.calcsize('P') * 8); sys.exit(0 if sys.version_info[:3] == (3, 8, 10) and struct.calcsize('P') == 8 and sys.implementation.name == 'cpython' and sys.prefix != sys.base_prefix else 1)"
    if ($LASTEXITCODE -ne 0) { throw 'Legacy build requires isolated CPython 3.8.10 x64; current/default Python is not permitted.' }

    & $legacyPython -c "from importlib.metadata import version; from pathlib import Path; pins = [line.strip().split('==') for line in (Path('requirements.txt').read_text() + '\n' + Path('requirements-win7.txt').read_text()).splitlines() if '==' in line and not line.lstrip().startswith('#')]; actual = [(name, expected, version(name)) for name, expected in pins]; [print(name + '==' + found) for name, expected, found in actual]; assert all(expected == found for name, expected, found in actual), 'Install the exact requirements-win7.txt pins'"
    if ($LASTEXITCODE -ne 0) { throw 'Legacy dependencies missing or incorrect. Install requirements-win7.txt using the venv interpreter.' }
    & $legacyPython -m pip check
    if ($LASTEXITCODE -ne 0) { throw 'Legacy dependency check failed.' }
    & $legacyPython -m unittest -v test_convert_master
    if ($LASTEXITCODE -ne 0) { throw 'Converter tests failed; no EXE built.' }

    & $legacyPython -m PyInstaller `
        --onefile --windowed --clean --noconfirm --exclude-module multiprocessing `
        --name 'TRISMART_Master_Converter_Win7_x64_TEST2' `
        --workpath (Join-Path $PSScriptRoot 'build\win7-test2') `
        --distpath (Join-Path $PSScriptRoot 'dist') `
        --specpath $PSScriptRoot `
        --add-data 'convert_master.py;.' `
        (Join-Path $PSScriptRoot 'master_converter_gui.py')
    if ($LASTEXITCODE -ne 0) { throw 'Legacy PyInstaller build failed.' }
    $legacyExe = Join-Path $PSScriptRoot 'dist\TRISMART_Master_Converter_Win7_x64_TEST2.exe'
    $artifact = Get-Item -LiteralPath $legacyExe
    Write-Host "Output: $($artifact.FullName)"
    Write-Host "Size: $($artifact.Length) bytes"
    Write-Host "SHA-256: $((Get-FileHash -LiteralPath $legacyExe -Algorithm SHA256).Hash)"
    Write-Host 'Build complete. Local GUI smoke test and real Windows 7 device test still required.'
} finally {
    Pop-Location
}
