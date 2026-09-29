# Windows 7 x64 legacy build

**Device result: FAILED on the actual Windows 7 PC.** The original legacy EXE
fails in `pyi_rth_multiprocessing` while importing `_socket` with
`The parameter is incorrect`. The earlier core-path DLL error no longer appears.
The local results below are historical Windows 10 results, not a Windows 7 pass.
See [WIN7_TEST2.md](WIN7_TEST2.md) for the separate TEST2 candidate and diagnosis.

Use CPython **3.8.10 x64**, installed separately from the default Python.
From this directory:

```powershell
py -3.8 -m venv .venv-win7
.\.venv-win7\Scripts\python.exe -m pip install -r requirements-win7.txt
powershell -NoProfile -ExecutionPolicy Bypass -File .\build_converter_win7.ps1
```

The execution-policy option applies only to that process. The build script uses
only `.venv-win7\Scripts\python.exe`, checks exact interpreter and dependency
versions, runs the existing tests, and stops on failure. It does not install
Python or packages, change the default interpreter, or delete modern artifacts.

PyInstaller **4.10** supports Python 3.6-3.10. Its release documentation says
Windows 7 should work, while official support starts at Windows 8:
https://pypi.org/project/pyinstaller/4.10/
This is a conservative candidate, not a guarantee of Windows 7 compatibility.
Build dependencies are pinned in `requirements-win7.txt`; `xlrd==2.0.2` remains
in the existing application requirements. Reproducing the toolchain does not
promise byte-identical EXEs across build machines or build times.

Output: `dist/TRISMART_Master_Converter_Win7_x64.exe`.
Work files: `build/win7/`. The modern script and modern EXE are separate.
The script prints EXE size and SHA-256 after a successful build.

## Local validation (2026-09-28, Windows 10 build 19045)

- CPython 3.8.10 AMD64; PyInstaller 4.10; xlrd 2.0.2.
- All 14 existing converter tests passed; dependency check passed.
- Packaged EXE opened a tkinter GUI; PE machine AMD64, subsystem Windows GUI.
- Correct title, working file picker, footer and Version 1.0.0 visible initially.
- Converted a copied `23.xls` through the packaged GUI: STATUS VALID, Error 0.
- 11506 rows, 11506 unique PLUs, 10436 filled barcodes, 1070 empty barcodes.
- PLU 1010787 retained barcode 8991102026352 exactly.
- 338 rows with a leading-zero code or barcode matched the validated CSV;
  examples include 0711844160071 and 0711844160057.
- Output was byte-identical to the existing validated `master_barang_safe.csv`.
- BUKA FOLDER HASIL opened the selected source/output directory.
- Original XLS and modern EXE SHA-256 remained unchanged.

Existing layout limitation: a long selected file path wraps onto two lines and
can push Version 1.0.0 below the fixed window at 150% display scaling. The footer
and version are visible initially. No GUI layout changes were made for packaging.

## Required Doko PC test (not yet performed)

1. Confirm the actual PC is Windows 7 SP1 64-bit. Copy the legacy EXE and a COPY
   of the known-good XLS into a writable test directory, preferably a short path.
2. Verify the copied EXE SHA-256 matches the build report.
3. Launch the EXE without installing Python. Check title, no console, file picker,
   Developed By Bimz, and Version 1.0.0.
4. Select the copied XLS and click KONVERSI. Require STATUS VALID and Error 0,
   with the row/PLU/barcode counts above. Check master_barang_safe.csv is beside
   that XLS and BUKA FOLDER HASIL opens the correct directory.
5. Compare output bytes against the validated CSV, and check PLU 1010787 plus
   leading-zero barcodes without opening/saving the CSV through Excel.
6. Record Windows version, EXE hash, result and any exact error message.
   If a runtime/API DLL is missing, record its exact name; do not download
   arbitrary DLL files. Diagnose the actual failure before changing packaging.

A local success is only READY FOR DEVICE TEST. Do not mark WINDOWS 7 PASS until
the application and conversion succeed on the real Windows 7 SP1 x64 PC.
