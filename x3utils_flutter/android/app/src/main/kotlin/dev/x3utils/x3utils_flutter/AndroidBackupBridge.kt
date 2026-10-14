package dev.x3utils.x3utils_flutter

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// Publishes x3utils output through MediaStore into a FIXED set of folders:
/// the backup and log folders under Downloads/x3utils, and the second copy
/// under Documents/x3utils_2nd_copy (a different parent the user cannot empty
/// together with the backups, and one that survives an uninstall).
class AndroidBackupBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "publishBackup" && call.method != "publishFile") {
            result.notImplemented()
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "unsupported",
                "Android Backup requires Android 10 or newer.",
                null,
            )
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = call.argument<String>("fileName")
        // publishBackup is the original single-purpose call: one .bin into
        // the backup folder.
        val folder =
            if (call.method == "publishBackup") "backup" else call.argument<String>("folder")
        val subfolder = call.argument<String>("subfolder")
        val target = folder?.let { resolveTarget(it, subfolder) }
        val validName = fileName != null &&
            (if (call.method == "publishBackup") VALID_BACKUP_NAME else VALID_FILE_NAME)
                .matches(fileName)
        if (bytes == null || fileName == null || !validName || target == null) {
            result.error("invalid_backup", "The Android backup request was invalid.", null)
            return
        }
        executor.execute {
            try {
                val displayPath = publish(bytes, fileName, target)
                mainHandler.post { result.success(displayPath) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error(
                        "storage_failed",
                        error.message ?: "Android could not save the file.",
                        null,
                    )
                }
            }
        }
    }

    private data class Target(
        val collection: Uri,
        val relativePath: String,
        val displayDirectory: String,
    )

    private fun resolveTarget(folder: String, subfolder: String?): Target? {
        if (subfolder != null && (folder != "logs" || !VALID_SUBFOLDER.matches(subfolder))) {
            return null
        }
        val downloads = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        return when (folder) {
            "backup" -> Target(
                downloads,
                "${Environment.DIRECTORY_DOWNLOADS}/x3utils/backup/",
                "Downloads/x3utils/backup",
            )
            "logs" -> {
                val sub = if (subfolder == null) "" else "$subfolder/"
                Target(
                    downloads,
                    "${Environment.DIRECTORY_DOWNLOADS}/x3utils/logs/$sub",
                    "Downloads/x3utils/logs" + (if (subfolder == null) "" else "/$subfolder"),
                )
            }
            // Documents is not part of the Downloads collection; non-media
            // files there go through the generic Files collection.
            "second_copy" -> Target(
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                "${Environment.DIRECTORY_DOCUMENTS}/x3utils_2nd_copy/",
                "Documents/x3utils_2nd_copy",
            )
            else -> null
        }
    }

    private fun publish(bytes: ByteArray, fileName: String, target: Target): String {
        val resolver = context.contentResolver
        if (fileExists(target, fileName)) {
            throw IOException("A file named $fileName already exists.")
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            // octet-stream keeps the extension exactly as given; a typed MIME
            // can make MediaStore append its own (".log" -> ".log.txt").
            put(
                MediaStore.MediaColumns.MIME_TYPE,
                if (fileName.endsWith(".json")) "application/json" else "application/octet-stream",
            )
            put(MediaStore.MediaColumns.RELATIVE_PATH, target.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(target.collection, values)
            ?: throw IOException("Android could not create the file.")
        try {
            resolver.openOutputStream(uri, "w")?.use { stream ->
                stream.write(bytes)
                stream.flush()
            } ?: throw IOException("Android could not open the file.")
            val published = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            if (resolver.update(uri, published, null, null) != 1) {
                throw IOException("Android could not publish the completed file.")
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        return "${target.displayDirectory}/$fileName"
    }

    private fun fileExists(target: Target, fileName: String): Boolean {
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                "${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        context.contentResolver.query(
            target.collection,
            projection,
            selection,
            arrayOf(fileName, target.relativePath),
            null,
        )?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    companion object {
        private const val CHANNEL_NAME = "dev.x3utils/backup_store"
        private val VALID_BACKUP_NAME = Regex("^[A-Za-z0-9._-]+\\.bin$")
        private val VALID_FILE_NAME = Regex("^[A-Za-z0-9._-]+\\.(bin|json|log)$")
        private val VALID_SUBFOLDER = Regex("^[a-z0-9_]+$")
    }
}
