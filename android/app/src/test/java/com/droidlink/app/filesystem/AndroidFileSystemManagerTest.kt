package com.droidlink.app.filesystem

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class AndroidFileSystemManagerTest {

    private lateinit var tempRoot: File
    private lateinit var fsManager: AndroidFileSystemManager

    @Before
    fun setUp() {
        tempRoot = Files.createTempDirectory("droidlink_test_fs").toFile().canonicalFile
        fsManager = AndroidFileSystemManager(customRootDir = tempRoot)
    }

    @After
    fun tearDown() {
        tempRoot.deleteRecursively()
    }

    @Test
    fun testOptimalChunkSizeCalculations() {
        // < 10 MB: 512 KB
        assertEquals(512 * 1024, AndroidFileSystemManager.getOptimalChunkSize(5 * 1024 * 1024L))
        assertEquals(512 * 1024, AndroidFileSystemManager.getOptimalChunkSize(10 * 1024 * 1024L))

        // 10 MB - 256 MB: 2 MB
        assertEquals(2 * 1024 * 1024, AndroidFileSystemManager.getOptimalChunkSize(100 * 1024 * 1024L))
        assertEquals(2 * 1024 * 1024, AndroidFileSystemManager.getOptimalChunkSize(256 * 1024 * 1024L))

        // 256 MB - 2 GB: 4 MB
        assertEquals(4 * 1024 * 1024, AndroidFileSystemManager.getOptimalChunkSize(1024 * 1024 * 1024L))
        assertEquals(4 * 1024 * 1024, AndroidFileSystemManager.getOptimalChunkSize(2L * 1024 * 1024 * 1024))

        // > 2 GB: 8 MB (e.g. 5 GB / 10 GB videos)
        assertEquals(8 * 1024 * 1024, AndroidFileSystemManager.getOptimalChunkSize(5L * 1024 * 1024 * 1024))
        assertEquals(8 * 1024 * 1024, AndroidFileSystemManager.getOptimalChunkSize(12L * 1024 * 1024 * 1024))
    }

    @Test
    fun testResolveSafeFileAndSandboxBoundary() {
        val validFile = fsManager.resolveSafeFile("Download/sample.txt")
        assertEquals(File(tempRoot, "Download/sample.txt").canonicalPath, validFile.canonicalPath)

        val rootFile = fsManager.resolveSafeFile("")
        assertEquals(tempRoot.canonicalPath, rootFile.canonicalPath)

        // Downloads normalization to Download
        val normalizedFile = fsManager.resolveSafeFile("Downloads/DroidLink/sample.txt")
        assertEquals(File(tempRoot, "Download/DroidLink/sample.txt").canonicalPath, normalizedFile.canonicalPath)

        // Traversal attack attempt
        try {
            fsManager.resolveSafeFile("../../etc/passwd")
            assertTrue("Expected SecurityException on directory traversal", false)
        } catch (e: SecurityException) {
            // Expected
            assertTrue(e.message!!.contains("escapes user storage root"))
        }
    }

    @Test
    fun testRestrictedPaths() {
        val dataDir = File(tempRoot, "Android/data")
        val obbDir = File(tempRoot, "Android/obb")
        val downloadDir = File(tempRoot, "Download")

        assertTrue(fsManager.isRestrictedPath(dataDir))
        assertTrue(fsManager.isRestrictedPath(obbDir))
        assertFalse(fsManager.isRestrictedPath(downloadDir))
    }

    @Test
    fun testEnumerateDirectoryAndPagination() {
        val downloadDir = File(tempRoot, "Download").apply { mkdirs() }
        File(downloadDir, "doc_a.pdf").writeText("Sample PDF")
        File(downloadDir, "doc_b.txt").writeText("Sample Text")
        File(downloadDir, "subfolder").mkdir()

        val (items, nextToken) = fsManager.enumerateDirectory("Download", pageToken = null, pageSize = 2)
        assertEquals(2, items.size)
        // Directories sorted first
        assertTrue(items[0].isDirectory)
        assertEquals("subfolder", items[0].name)
        assertNotNull(nextToken)

        // Page 2
        val (page2Items, page2Token) = fsManager.enumerateDirectory("Download", pageToken = nextToken, pageSize = 2)
        assertEquals(1, page2Items.size)
        assertEquals("doc_b.txt", page2Items[0].name)
        assertEquals(null, page2Token)
    }

    @Test
    fun testDotfilesPreservedForFinder() {
        val notesDir = File(tempRoot, "Notes").apply { mkdirs() }
        File(notesDir, ".nomedia").createNewFile()
        File(notesDir, ".hidden_config").writeText("secret=1")
        File(notesDir, "visible.txt").writeText("visible")

        val (items, _) = fsManager.enumerateDirectory("Notes")
        assertEquals(3, items.size)
        assertTrue(items.any { it.name == ".nomedia" })
        assertTrue(items.any { it.name == ".hidden_config" })
        assertTrue(items.any { it.name == "visible.txt" })
    }

    @Test
    fun testDefaultPageSizeDoesNotTruncateAt250() {
        val largeDir = File(tempRoot, "LargeFolder").apply { mkdirs() }
        for (i in 1..300) {
            File(largeDir, "item_%03d.txt".format(i)).createNewFile()
        }

        val (items, nextToken) = fsManager.enumerateDirectory("LargeFolder")
        assertEquals(300, items.size)
        assertEquals(null, nextToken)
    }

    @Test
    fun testChunkReadAndWrite() {
        val testPayload = "Hello DroidLink FileProvider 64-bit chunking!".toByteArray(Charsets.UTF_8)
        val relPath = "Documents/notes.txt"

        // Write chunk
        val totalSize = fsManager.writeChunk(relPath, offset = 0, data = testPayload, isEof = true)
        assertEquals(testPayload.size.toLong(), totalSize)

        // Read metadata
        val info = fsManager.getItemMetadata(relPath)
        assertNotNull(info)
        assertEquals("notes.txt", info!!.name)
        assertEquals(testPayload.size.toLong(), info.size)
        assertFalse(info.isDirectory)

        // Read chunk
        val result = fsManager.readChunk(relPath, offset = 0, requestedLength = 1024)
        assertEquals(testPayload.size, result.data.size)
        assertEquals(String(testPayload), String(result.data))
        assertTrue(result.isEof)
        assertEquals(testPayload.size.toLong(), result.totalSize)
    }
}
