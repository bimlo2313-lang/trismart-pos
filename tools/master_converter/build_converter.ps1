<# 
.SYNOPSIS
    Build TRISMART Master Converter as a portable Windows EXE using PyInstaller.

.DESCRIPTION
    This script creates a single-file, windowed executable from the master converter GUI.
    The resulting EXE runs on Windows without requiring Python or xlrd installation.

.NOTES
    Must be run from tools/master_converter/ directory.
    Output: dist/TRISMART_Master_Converter.exe
#>

# Ensure we're in the correct directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Building TRISMART Master Converter EXE" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Working directory: $ScriptDir" -ForegroundColor Gray

# Clean previous builds
if (Test-Path "build") {
    Write-Host "Cleaning previous build directory..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force "build"
}
if (Test-Path "dist") {
    Write-Host "Cleaning previous dist directory..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force "dist"
}
if (Test-Path "TRISMART_Master_Converter.spec") {
    Write-Host "Removing previous spec file..." -ForegroundColor Yellow
    Remove-Item -Force "TRISMART_Master_Converter.spec"
}

# Verify entry point exists
if (-not (Test-Path "master_converter_gui.py")) {
    Write-Error "master_converter_gui.py not found in $ScriptDir"
    exit 1
}

# Verify convert_master.py exists (required dependency)
if (-not (Test-Path "convert_master.py")) {
    Write-Error "convert_master.py not found in $ScriptDir"
    exit 1
}

# Verify xlrd is available
try {
    python -c "import xlrd; print('xlrd version:', xlrd.__version__)"
} catch {
    Write-Error "xlrd not available in Python environment"
    exit 1
}

Write-Host "`nStarting PyInstaller build..." -ForegroundColor Green

# Run PyInstaller
# --onefile: Create a single executable file
# --windowed: Don't open a console window (GUI app)
# --clean: Clean PyInstaller cache before building
# --name: Set the output executable name
# --add-data: Include convert_master.py as a data file (though it should be auto-detected as a module)
# Since convert_master.py is imported as a module from the same directory, PyInstaller should 
# automatically include it. But we'll be explicit to be safe.
python -m PyInstaller `
    --onefile `
    --windowed `
    --clean `
    --name "TRISMART_Master_Converter" `
    --add-data "convert_master.py;." `
    master_converter_gui.py

$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Error "PyInstaller build failed with exit code $exitCode"
    exit $exitCode
}

# Verify the output
$exePath = "dist\TRISMART_Master_Converter.exe"
if (Test-Path $exePath) {
    $fileInfo = Get-Item $exePath
    $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "BUILD SUCCESSFUL" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Output: $exePath" -ForegroundColor Gray
    Write-Host "Size: $($fileInfo.Length) bytes ($sizeMB MB)" -ForegroundColor Gray
    Write-Host "==========================================" -ForegroundColor Cyan
} else {
    Write-Error "EXE not found at expected location: $exePath"
    exit 1
}