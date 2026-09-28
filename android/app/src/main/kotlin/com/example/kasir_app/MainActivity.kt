package com.example.kasir_app

import android.app.Activity
import android.content.Intent
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var pendingBackup: MethodChannel.Result? = null
    private var backupSource: File? = null
    private val backupRequest = 8101
    private var pendingRestore: MethodChannel.Result? = null
    private var restoreTarget: File? = null
    private val restoreRequest = 8102
    private var pendingExport: MethodChannel.Result? = null
    private var exportSource: File? = null
    private val exportRequest = 8103

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "trismart/backup")
            .setMethodCallHandler { call, result ->
                if (call.method == "openBackup") {
                    if (pendingRestore != null || pendingBackup != null || pendingExport != null) {
                        result.error("BUSY", "Backup/pemulihan/export sedang berjalan.", null)
                    } else {
                        try {
                            val target = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                            require(target.path.startsWith(cacheDir.canonicalPath + File.separator) && !target.exists())
                            restoreTarget = target
                            pendingRestore = result
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }, restoreRequest)
                        } catch (_: Exception) {
                            pendingRestore = null
                            restoreTarget = null
                            result.error("OPEN_FAILED", "Pemilih backup tidak dapat dibuka.", null)
                        }
                    }
                } else if (call.method == "saveExport") {
                    if (pendingExport != null || pendingBackup != null || pendingRestore != null) {
                        result.error("BUSY", "Backup/pemulihan/export sedang berjalan.", null)
                    } else {
                        try {
                            val source = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                            val name = requireNotNull(call.argument<String>("filename"))
                            // Channel hanya boleh mengekspor file temporary export aplikasi.
                            require(source.isFile && source.path.startsWith(cacheDir.canonicalPath + File.separator))
                            require(name.endsWith(".zip") && !name.contains('/') && !name.contains("\\"))
                            pendingExport = result
                            exportSource = source
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/zip"
                                putExtra(Intent.EXTRA_TITLE, name)
                            }
                            startActivityForResult(intent, exportRequest)
                        } catch (_: Exception) {
                            pendingExport = null
                            exportSource = null
                            result.error("SAVE_UNAVAILABLE", "Dialog simpan export tidak dapat dibuka.", null)
                        }
                    }
                } else if (call.method != "saveBackup") {
                    result.notImplemented()
                } else if (pendingBackup != null || pendingRestore != null || pendingExport != null) {
                    result.error("BUSY", "Backup sedang berjalan.", null)
                } else {
                    try {
                        val source = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                        val name = requireNotNull(call.argument<String>("filename"))
                        // Channel hanya boleh mengekspor file temporary backup aplikasi.
                        require(source.isFile && source.path.startsWith(cacheDir.canonicalPath + File.separator))
                        require(name.endsWith(".trismart") && !name.contains('/') && !name.contains('\\'))
                        pendingBackup = result
                        backupSource = source
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, name)
                        }
                        startActivityForResult(intent, backupRequest)
                    } catch (_: Exception) {
                        pendingBackup = null
                        backupSource = null
                        result.error("SAVE_UNAVAILABLE", "Dialog simpan tidak dapat dibuka.", null)
                    }
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == restoreRequest) {
            receiveRestore(resultCode, data)
            return
        }
        if (requestCode == exportRequest) {
            receiveExport(resultCode, data)
            return
        }
        if (requestCode != backupRequest) return
        val result = pendingBackup ?: return
        val source = backupSource
        if (resultCode != Activity.RESULT_OK) {
            pendingBackup = null
            backupSource = null
            result.success(false)
            return
        }
        val uri = data?.data
        if (uri == null || source == null) {
            pendingBackup = null
            backupSource = null
            result.error("SAVE_FAILED", "Lokasi backup tidak tersedia.", null)
            return
        }
        // Streaming pada worker thread. Dart membersihkan temporary setelah hasil ini.
        thread(name = "trismart-backup-export") {
            var saved = false
            try {
                val output = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("Output unavailable")
                output.use { target -> source.inputStream().use { it.copyTo(target) } }
                saved = true
            } catch (_: Exception) {
                // Dokumen baru yang gagal ditulis tidak dibiarkan sebagai backup parsial.
                try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { }
            }
            runOnUiThread {
                pendingBackup = null
                backupSource = null
                if (saved) result.success(true)
                else result.error("SAVE_FAILED", "File backup gagal disimpan.", null)
            }
        }
    }

    private fun receiveRestore(resultCode: Int, data: Intent?) {
        val result = pendingRestore ?: return
        val target = restoreTarget
        if (resultCode != Activity.RESULT_OK) {
            pendingRestore = null
            restoreTarget = null
            result.success(false)
            return
        }
        val uri = data?.data
        thread(name = "trismart-backup-import") {
            var copied = false
            try {
                require(uri != null && target != null)
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    require(it.moveToFirst() && it.getString(0).endsWith(".trismart", ignoreCase = true))
                } ?: throw IllegalArgumentException("Missing filename")
                val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("Input unavailable")
                input.use { source -> target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= 256L * 1024 * 1024)
                        output.write(buffer, 0, count)
                    }
                } }
                copied = true
            } catch (_: Exception) {
                target?.delete()
            }
            runOnUiThread {
                pendingRestore = null
                restoreTarget = null
                if (copied) result.success(true)
                else result.error("OPEN_FAILED", "Pilih backup .trismart yang dapat dibaca, maksimal 256 MB.", null)
            }
        }
    }

    private fun receiveExport(resultCode: Int, data: Intent?) {
        val result = pendingExport ?: return
        val source = exportSource
        if (resultCode != Activity.RESULT_OK) {
            pendingExport = null
            exportSource = null
            result.success(false)
            return
        }
        val uri = data?.data
        if (uri == null || source == null) {
            pendingExport = null
            exportSource = null
            result.error("SAVE_FAILED", "Lokasi export tidak tersedia.", null)
            return
        }
        // Streaming pada worker thread. Dart membersihkan temporary setelah hasil ini.
        thread(name = "trismart-export-save") {
            var saved = false
            try {
                val output = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("Output unavailable")
                output.use { target -> source.inputStream().use { it.copyTo(target) } }
                saved = true
            } catch (_: Exception) {
                // Dokumen baru yang gagal ditulis tidak dibiarkan sebagai export parsial.
                try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { }
            }
            runOnUiThread {
                pendingExport = null
                exportSource = null
                if (saved) result.success(true)
                else result.error("SAVE_FAILED", "File export gagal disimpan.", null)
            }
        }
    }
}
