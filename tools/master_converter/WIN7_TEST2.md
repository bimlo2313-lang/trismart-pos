# TEST2 diagnosis and device-test candidate

Status: **WIN7 TEST2 READY FOR DEVICE TEST**. Original legacy build FAILED on the
actual Windows 7 Doko PC. TEST2 has passed local Windows 10 checks only.

## Evidence and minimal packaging change

Neither `convert_master.py` nor `master_converter_gui.py` imports multiprocessing
or socket/networking. The GUI uses `threading.Thread` and `queue.Queue`.
A search of installed xlrd 2.0.2 source also found no multiprocessing/socket/
network imports. App imports and full 11506-row conversion succeeded with an
import finder that raises on multiprocessing, socket, or _socket imports.
The guarded conversion output was byte-identical to the validated CSV.

The original PyInstaller xref records this static dependency path:

```text
convert_master -> hashlib -> logging -> pickle -> doctest -> unittest
-> unittest.async_case -> asyncio -> asyncio.base_events
-> concurrent.futures -> concurrent.futures.process -> multiprocessing
```

This is an Analysis graph, not a trace of actual app execution. In Python 3.8.10,
`pickle.py:1781` imports doctest inside `_test()`; `concurrent/futures/__init__.py:44`
lazily imports the process executor. Static analysis collects these branches.
`concurrent/futures/process.py:53-55` imports multiprocessing and connection/queues.
PyInstaller `hooks/rthooks.dat:27` maps the collected multiprocessing package to
`pyi_rth_multiprocessing.py`. That startup hook imports multiprocessing at line 12
and Windows process-spawn support at line 59, before application startup.
The device traceback then reaches multiprocessing.connection -> socket -> _socket.
The application does not need that multiprocessing startup hook.

New script: `build_converter_win7_test2.ps1`, copied from the first legacy script.
The only functional packaging option added is:

```text
--exclude-module multiprocessing
```

Name changes to `TRISMART_Master_Converter_Win7_x64_TEST2`; work path changes to
`build/win7-test2`. The original build script and both older EXEs are preserved.
Python 3.8.10 x64, PyInstaller 4.10, all pinned dependencies, xlrd 2.0.2,
onefile/windowed/clean options and convert_master.py data bundling remain the same.
No source, business logic, GUI, CSV format or version changes were made.

TEST2 Analysis confirms no multiprocessing package, `_multiprocessing` extension,
or `pyi_rth_multiprocessing` runtime hook. Other runtime hooks remain: subprocess,
pkgutil, inspect and tkinter. `socket` and `_socket` remain bundled via other
stdlib paths; they were not broadly excluded. Removing an unused startup import
does not repair a Windows DLL loader that lacks required update support.

References:
- [PyInstaller 4.10 exclusions](https://www.pyinstaller.org/en/v4.10/usage.html)
- Local evidence: `build/win7*/TRISMART_Master_Converter_*/Analysis-00.toc`
  and the adjacent `xref-*.html` files (ignored build artifacts).

## Native Windows failure: evidence and uncertainty

PE inspection of the actual CPython 3.8.10 `_socket.pyd` found these direct imports:
WS2_32.dll, IPHLPAPI.DLL, KERNEL32.dll, python38.dll, VCRUNTIME140.dll,
api-ms-win-crt-runtime-l1-1-0.dll and api-ms-win-crt-string-l1-1-0.dll.
The original Analysis bundled `_socket.pyd` and VCRUNTIME140.dll from the Python38
installation, not Python314. It did not list a separately bundled UCRT DLL.
That does not establish that UCRT is missing on the Doko PC.

CPython 3.8.10 loads extensions using `LoadLibraryExW` with
`LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`.
Microsoft documents that those flags require KB2533623 support on Windows 7;
Python 3.8 documentation also identifies this prerequisite.
The error text `The parameter is incorrect` makes missing loader-flag support
a plausible, leading native-runtime explanation, not proof. Device SP1/update
inventory and API availability were not supplied. A superseding update can provide
the same support, so absence of one KB number alone is not conclusive.

- **A confirmed:** an unnecessary runtime hook triggers the failing import.
- **B suspected:** Windows 7 loader/update dependency is the leading native-error
  hypothesis; confirm on the device before recommending installation.
- **C not established:** no evidence justifies changing Python 3.8.10 yet.
- Exact native cause remains undetermined without device diagnostics.

Do not assume a Visual C++ redistributable is missing: VCRUNTIME140.dll is bundled,
and this error does not specifically identify a missing VC/UCRT DLL. No runtime
or Windows update was installed, and no arbitrary DLL was downloaded or copied.

Sources:
- [CPython 3.8.10 extension loader, lines 178-185](https://github.com/python/cpython/blob/v3.8.10/Python/dynload_win.c#L178-L185)
- [Microsoft LoadLibraryExW flags and feature detection](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-loadlibraryexw)
- [Python 3.8 Windows runtime prerequisite](https://docs.python.org/3.8/using/windows.html)

## Build and local results

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build_converter_win7_test2.ps1
```

The script verifies the dedicated interpreter and pinned packages, runs the
existing 14 tests, and stops before packaging on failure.

- CPython 3.8.10 x64; PyInstaller 4.10; xlrd 2.0.2; Windows 10 build 19045.
- 14/14 existing tests PASS, including exact barcode and leading-zero regressions.
- TEST2 GUI opened with correct title; x64 PE Windows GUI subsystem (no console).
- File picker selected a COPY of 23.xls; packaged conversion succeeded.
- STATUS VALID, Error 0; rows 11506, unique PLUs 11506, filled barcode 10436,
  empty barcode 1070. Folder button opened the correct directory.
- PLU 1010787 -> 8991102026352 exactly. All 338 rows having a leading-zero
  identifier matched baseline, including barcode 0711844160071.
- Output CSV byte-identical to existing validated baseline; SHA-256:
  `6BA773DB3477552C0F313F1FBE9AE853575BC781F11312AAFAF808CBDFE75873`.
- Source-level guarded conversion reported two existing XLS container warnings
  (sector-size alignment and SSCS/SSAT inconsistency), with zero errors.
- Screenshots and validation JSON are under ignored `build/win7-test2/`.

Artifact:
`C:\FlutterProjects\kasir_app\tools\master_converter\dist\TRISMART_Master_Converter_Win7_x64_TEST2.exe`

Size: **9389555 bytes**.

SHA-256: `A61C980F193BBE4D94B4B6DC3573DCBF7F761EB6201433D2F8FDF941A9445EB1`.

## Next action on the same Windows 7 Doko PC

Copy TEST2 (keep the failed EXE), verify its SHA-256, and run it with a copied XLS.
Require GUI startup and STATUS VALID with the counts above, exact target barcode,
leading zeros and identical CSV. Only that real-device test can establish success.

If startup fails again, record the complete new traceback and the failing module.
Check Windows 7 SP1/x64, kernel32 version and update inventory. In particular,
Microsoft recommends testing whether kernel32 exports AddDllDirectory,
RemoveDllDirectory or SetDefaultDllDirectories to determine support for the
loader flags, rather than relying on one KB number. If support is absent, investigate
the applicable official Microsoft update/superseding update separately. If support
exists, inspect the actual missing/failing dependency and loader error on-device.
An error moving from _socket to another extension would mean the exclusion bypassed
the first trigger but did not resolve the underlying loader problem.

Do not download arbitrary DLLs or claim WINDOWS 7 PASS from local results.
