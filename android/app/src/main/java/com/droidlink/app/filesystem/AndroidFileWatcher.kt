package com.droidlink.app.filesystem

import android.os.Build
import android.os.FileObserver
import android.util.Log
import droidlink.protocol.FileProto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

/**
 * Monitors user storage directories using Linux inotify (android.os.FileObserver).
 * Automatically debounces rapid filesystem changes and fires events to notify macOS Finder in real time.
 */
class AndroidFileWatcher(
    private val scope: CoroutineScope,
    private val onFileChange: (FileProto.FileMessage) -> Unit
) {

    companion object {
        private const val TAG = "AndroidFileWatcher"
        private const val DEBOUNCE_DELAY_MS = 300L
    }

    private var activeObserver: FileObserver? = null
    private val debounceJobs = mutableMapOf<String, Job>()

    /**
     * Starts watching a directory relative to /storage/emulated/0.
     */
    fun startWatching(relativePath: String = "") {
        stopWatching()

        val targetDir = try {
            AndroidFileSystemManager().resolveSafeFile(relativePath)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to resolve path for watching: $relativePath", e)
            return
        }

        if (!targetDir.exists() || !targetDir.isDirectory) {
            Log.w(TAG, "Cannot watch non-existent directory: ${targetDir.path}")
            return
        }

        Log.d(TAG, "👁️ Starting FileObserver on: ${targetDir.path}")

        val mask = FileObserver.CREATE or
                FileObserver.DELETE or
                FileObserver.MODIFY or
                FileObserver.MOVED_FROM or
                FileObserver.MOVED_TO

        activeObserver = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            object : FileObserver(targetDir, mask) {
                override fun onEvent(event: Int, path: String?) {
                    handleEvent(event, targetDir, path)
                }
            }
        } else {
            @Suppress("DEPRECATION")
            object : FileObserver(targetDir.path, mask) {
                override fun onEvent(event: Int, path: String?) {
                    handleEvent(event, targetDir, path)
                }
            }
        }

        activeObserver?.startWatching()
    }

    fun stopWatching() {
        try {
            activeObserver?.stopWatching()
            activeObserver = null
            debounceJobs.values.forEach { it.cancel() }
            debounceJobs.clear()
            Log.d(TAG, "FileObserver stopped.")
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping FileObserver", e)
        }
    }

    private fun handleEvent(event: Int, baseDir: File, childName: String?) {
        if (childName.isNullOrEmpty() || childName.startsWith(".")) return

        val affectedFile = File(baseDir, childName)
        val relPath = affectedFile.toRelativeString(AndroidFileSystemManager.rootDir).replace('\\', '/')

        val changeType = when {
            (event and FileObserver.CREATE) != 0 -> FileProto.FileMessage.ChangeType.CHANGE_CREATED
            (event and FileObserver.DELETE) != 0 -> FileProto.FileMessage.ChangeType.CHANGE_DELETED
            (event and FileObserver.MOVED_FROM) != 0 -> FileProto.FileMessage.ChangeType.CHANGE_DELETED
            (event and FileObserver.MOVED_TO) != 0 -> FileProto.FileMessage.ChangeType.CHANGE_CREATED
            (event and FileObserver.MODIFY) != 0 -> FileProto.FileMessage.ChangeType.CHANGE_MODIFIED
            else -> return
        }

        // Debounce rapid events on the same file path (e.g. multi-block writes)
        val key = "$relPath:$changeType"
        debounceJobs[key]?.cancel()
        debounceJobs[key] = scope.launch(Dispatchers.IO) {
            delay(DEBOUNCE_DELAY_MS)
            debounceJobs.remove(key)

            try {
                val fileInfo = if (changeType != FileProto.FileMessage.ChangeType.CHANGE_DELETED && affectedFile.exists()) {
                    AndroidFileSystemManager().getItemMetadata(relPath)
                } else null

                val msgBuilder = FileProto.FileMessage.newBuilder()
                    .setOperation(FileProto.FileMessage.FileOperation.FILE_CHANGE_EVENT)
                    .setFilePath(relPath)
                    .setChangeType(changeType)

                if (fileInfo != null) {
                    msgBuilder.setFileInfo(fileInfo)
                }

                val msg = msgBuilder.build()
                Log.d(TAG, "📢 Emitting filesystem change event: $relPath ($changeType)")
                onFileChange(msg)
            } catch (e: Exception) {
                Log.e(TAG, "Error preparing file change notification", e)
            }
        }
    }
}
