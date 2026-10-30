package com.droidlink.app.filesystem

import android.os.Environment
import android.util.Log
import android.webkit.MimeTypeMap
import com.google.protobuf.ByteString
import droidlink.protocol.FileProto
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption

/**
 * High-performance native filesystem manager for Android 15+.
 * Operates directly on /storage/emulated/0 using POSIX FileChannel NIO operations.
 * Bypasses SAF DocumentFile overhead for sub-millisecond directory traversal and wire-speed streaming.
 */
class AndroidFileSystemManager(private val customRootDir: File? = null) {

    val rootDir: File by lazy {
        customRootDir?.canonicalFile ?: defaultRootDir
    }

    companion object {
        private const val TAG = "AndroidFSManager"

        val defaultRootDir: File by lazy {
            Environment.getExternalStorageDirectory().canonicalFile
        }

        val rootDir: File
            get() = defaultRootDir

        /**
         * Calculates dynamic adaptive chunk size based on file size.
         * < 10 MB: 512 KB
         * 10 MB - 256 MB: 2 MB
         * 256 MB - 2 GB: 4 MB
         * > 2 GB: 8 MB
         */
        fun getOptimalChunkSize(fileSize: Long): Int {
            return when {
                fileSize <= 10L * 1024 * 1024 -> 512 * 1024
                fileSize <= 256L * 1024 * 1024 -> 2 * 1024 * 1024
                fileSize <= 2L * 1024 * 1024 * 1024 -> 4 * 1024 * 1024
                else -> 8 * 1024 * 1024
            }
        }
    }

    private fun logError(msg: String) {
        try { Log.e(TAG, msg) } catch (_: Throwable) { System.err.println("$TAG: $msg") }
    }

    private fun logWarn(msg: String) {
        try { Log.w(TAG, msg) } catch (_: Throwable) { System.err.println("$TAG: $msg") }
    }

    /**
     * Resolves a relative path to a canonical File within user storage.
     * Throws SecurityException if path tries to escape /storage/emulated/0.
     */
    fun resolveSafeFile(relativePath: String): File {
        var cleanRel = relativePath.trim()
            .removePrefix("/")
            .removePrefix("\\")
            .ifEmpty { "." }

        // Normalize "Downloads" / "Downloads/..." to standard Android "Download" if "Downloads" does not physically exist
        if ((cleanRel.equals("Downloads", ignoreCase = true) || cleanRel.startsWith("Downloads/", ignoreCase = true))
            && !File(rootDir, "Downloads").exists()) {
            cleanRel = if (cleanRel.equals("Downloads", ignoreCase = true)) {
                "Download"
            } else {
                "Download/" + cleanRel.substring("Downloads/".length)
            }
        }

        val target = File(rootDir, cleanRel).canonicalFile
        if (!target.path.startsWith(rootDir.path)) {
            logError("Directory traversal attack detected: $relativePath -> ${target.path}")
            throw SecurityException("Access denied: path escapes user storage root.")
        }
        return target
    }

    /**
     * Checks if directory is restricted by Android 13+ kernel/SEAndroid rules.
     */
    fun isRestrictedPath(file: File): Boolean {
        val rel = file.canonicalFile.toRelativeString(rootDir).replace('\\', '/')
        if (rel.equals("Android/data", ignoreCase = true) || rel.startsWith("Android/data/", ignoreCase = true)) return true
        if (rel.equals("Android/obb", ignoreCase = true) || rel.startsWith("Android/obb/", ignoreCase = true)) return true
        return false
    }

    /**
     * Enumerates directory children with cursor-based pagination.
     */
    fun enumerateDirectory(
        relativePath: String,
        pageToken: String? = null,
        pageSize: Int = 10000
    ): Pair<List<FileProto.FileInfo>, String?> {
        val dir = resolveSafeFile(relativePath)
        if (!dir.exists() || !dir.isDirectory) {
            logWarn("Directory does not exist or is not a dir: $relativePath")
            return Pair(emptyList(), null)
        }

        val allFiles = dir.listFiles() ?: emptyArray()
        // Sort: directories first, then alphabetical by name.
        // Dotfiles are preserved so macOS Finder can toggle their visibility via Cmd+Shift+.
        val sorted = allFiles
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))

        val startIndex = if (!pageToken.isNullOrEmpty()) {
            pageToken.toIntOrNull() ?: 0
        } else {
            0
        }

        val endIndex = minOf(startIndex + pageSize, sorted.size)
        val pagedFiles = if (startIndex < sorted.size) {
            sorted.subList(startIndex, endIndex)
        } else {
            emptyList()
        }

        val fileInfoList = pagedFiles.map { toFileInfo(it) }
        val nextToken = if (endIndex < sorted.size) endIndex.toString() else null
        return Pair(fileInfoList, nextToken)
    }

    /**
     * Retrieves single item metadata (stat).
     */
    fun getItemMetadata(relativePath: String): FileProto.FileInfo? {
        val file = resolveSafeFile(relativePath)
        if (!file.exists()) return null
        return toFileInfo(file)
    }

    data class ChunkReadResult(
        val data: ByteArray,
        val isEof: Boolean,
        val totalSize: Long,
        val bytesRead: Int
    )

    /**
     * Reads a chunk from file at 64-bit offset using FileChannel.
     */
    fun readChunk(relativePath: String, offset: Long, requestedLength: Int): ChunkReadResult {
        val file = resolveSafeFile(relativePath)
        if (!file.exists() || file.isDirectory) {
            throw IllegalArgumentException("File does not exist or is a directory: $relativePath")
        }

        val totalSize = file.length()
        if (offset >= totalSize) {
            return ChunkReadResult(ByteArray(0), true, totalSize, 0)
        }

        val lengthToRead = minOf(
            if (requestedLength > 0) requestedLength.toLong() else getOptimalChunkSize(totalSize).toLong(),
            totalSize - offset
        ).toInt()

        val buffer = ByteBuffer.allocate(lengthToRead)
        FileChannel.open(file.toPath(), StandardOpenOption.READ).use { channel ->
            channel.position(offset)
            var totalRead = 0
            while (totalRead < lengthToRead) {
                val read = channel.read(buffer)
                if (read == -1) break
                totalRead += read
            }
        }

        val isEof = (offset + lengthToRead) >= totalSize
        return ChunkReadResult(buffer.array(), isEof, totalSize, lengthToRead)
    }

    /**
     * Writes a chunk to file at 64-bit offset using FileChannel.
     */
    fun writeChunk(
        relativePath: String,
        offset: Long,
        data: ByteArray,
        isEof: Boolean,
        truncate: Boolean = true
    ): Long {
        val file = resolveSafeFile(relativePath)
        val parent = file.parentFile
        if (parent != null && !parent.exists()) {
            parent.mkdirs()
        }

        val openOptions = mutableSetOf(
            StandardOpenOption.CREATE,
            StandardOpenOption.WRITE
        )
        if (truncate && offset == 0L) {
            openOptions.add(StandardOpenOption.TRUNCATE_EXISTING)
        }

        FileChannel.open(file.toPath(), openOptions).use { channel ->
            channel.position(offset)
            val buffer = ByteBuffer.wrap(data)
            channel.write(buffer)
            if (isEof) {
                channel.force(true)
            }
        }

        return file.length()
    }

    /**
     * Creates an empty file or directory.
     */
    fun createItem(relativePath: String, isDirectory: Boolean): FileProto.FileInfo {
        val file = resolveSafeFile(relativePath)
        if (isDirectory) {
            if (!file.exists()) file.mkdirs()
        } else {
            val parent = file.parentFile
            if (parent != null && !parent.exists()) parent.mkdirs()
            if (!file.exists()) file.createNewFile()
        }
        return toFileInfo(file)
    }

    /**
     * Deletes a file or directory.
     */
    fun deleteItem(relativePath: String, recursive: Boolean): Boolean {
        val file = resolveSafeFile(relativePath)
        if (!file.exists()) return true
        return if (recursive && file.isDirectory) {
            file.deleteRecursively()
        } else {
            file.delete()
        }
    }

    /**
     * Moves or renames an item.
     */
    fun moveItem(sourceRelative: String, targetRelative: String): Boolean {
        val src = resolveSafeFile(sourceRelative)
        val dst = resolveSafeFile(targetRelative)
        if (!src.exists()) return false
        val dstParent = dst.parentFile
        if (dstParent != null && !dstParent.exists()) {
            dstParent.mkdirs()
        }
        return src.renameTo(dst)
    }

    private fun toFileInfo(file: File): FileProto.FileInfo {
        val relPath = file.toRelativeString(rootDir).replace('\\', '/')
        val isDir = file.isDirectory
        val size = if (isDir) 0L else file.length()
        val mtime = file.lastModified()
        val mimeType = if (isDir) "inode/directory" else getMimeType(file)

        return FileProto.FileInfo.newBuilder()
            .setName(file.name)
            .setPath(relPath)
            .setSize(size)
            .setModifiedTime(mtime)
            .setCreationTime(mtime)
            .setIsDirectory(isDir)
            .setMimeType(mimeType)
            .setIsReadOnly(!file.canWrite() || isRestrictedPath(file))
            .setEtag("${mtime}_${size}")
            .setId(relPath.ifEmpty { "root" })
            .build()
    }

    private fun getMimeType(file: File): String {
        val ext = file.extension.lowercase()
        if (ext.isEmpty()) return "application/octet-stream"
        return runCatching {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        }.getOrNull() ?: when (ext) {
            "txt" -> "text/plain"
            "pdf" -> "application/pdf"
            "mp4" -> "video/mp4"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "zip" -> "application/zip"
            else -> "application/octet-stream"
        }
    }
}
