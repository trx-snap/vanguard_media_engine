package com.connects.vanguard_media_engine.audio

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID

// ── AndroidWaveformCache (Phase 5-Unit X / Phase 4-Unit F) ────────────────────
//
// Android parity with VGWaveformCache.m (iOS). Pure disk I/O and path safety
// for the waveform result cache — owns no MethodChannel state, no epochs, no
// tokens. All route parsing and epoch/token bookkeeping lives in
// [AndroidWaveformCacheCoordinator].
//
// Storage topology (relative to the injected root):
//   Legacy:     <sha256(cacheKey)>.vgwc
//   Namespaced: n_<sha256(namespace)>/k_<sha256(assetKey)>/<sps>.vgwc
//
// Cache file layout (little-endian, matches VGWaveformCache.m):
//   [0..3]   uint32  schema version  (currently 1)
//   [4..11]  double  durationSeconds
//   [12..15] uint32  samplesPerSecond
//   [16..19] uint32  pointCount
//   [20..]   opaque  sample bytes (Dart-owned encoding; never reinterpreted here)
//
// Path safety:
//   - Canonical (resolved) paths are used ONLY for root-containment checks.
//   - android.system.Os.lstat (no-follow) is used for every symlink/type check
//     — ENOENT is treated as "absent"; any other errno propagates as an
//     unexpected IOException.
//   - Writes are atomic: a temp file named ".vgwc_tmp_<uuid>" is created
//     directly under the cache root (never inside a namespace/asset dir, so
//     the subtree validators below never observe it), then renamed into
//     place with Os.rename. The temp file is removed in a finally block if
//     the rename did not happen.
//   - Before deleting an asset directory, every child must be a regular,
//     non-symlink file named "<1..1000>.vgwc". Before deleting a namespace
//     directory, every child must be a directory named "k_" + 64 lowercase
//     hex characters, and every grandchild must pass the same density-file
//     check. Any unexpected sibling throws [UnsafePathException] rather than
//     broad-deleting an unrecognized subtree.
class AndroidWaveformCache(private val rootDir: File) {

    /// Thrown for symlink, containment, or unexpected-topology failures.
    /// The coordinator maps this to CACHE_UNSAFE_PATH; any other IOException
    /// maps to the route's generic failure code.
    class UnsafePathException(message: String) : IOException(message)

    data class WaveformResult(
        val samples: ByteArray,
        val durationSeconds: Double,
        val samplesPerSecond: Int,
        val pointCount: Int,
    )

    companion object {
        private const val EXTENSION = ".vgwc"
        private const val NS_PREFIX = "n_"
        private const val KEY_PREFIX = "k_"
        private const val VERSION = 1
        private const val HEADER_SIZE = 20
        private const val TEMP_PREFIX = ".vgwc_tmp_"
        private const val HEX_DIGITS = "0123456789abcdef"
    }

    // ── Path derivation ────────────────────────────────────────────────────

    private fun sha256Hex(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append(String.format("%02x", b))
        return sb.toString()
    }

    private fun legacyFile(cacheKey: String): File =
        File(rootDir, sha256Hex(cacheKey) + EXTENSION)

    private fun namespaceDir(namespace: String): File =
        File(rootDir, NS_PREFIX + sha256Hex(namespace))

    private fun assetDir(namespace: String, assetKey: String): File =
        File(namespaceDir(namespace), KEY_PREFIX + sha256Hex(assetKey))

    private fun namespacedFile(namespace: String, assetKey: String, samplesPerSecond: Int): File =
        File(assetDir(namespace, assetKey), "$samplesPerSecond$EXTENSION")

    // ── Canonical-path containment (containment only — not a symlink check) ─

    private fun isContained(parent: File, child: File): Boolean {
        val parentCanonical = parent.canonicalPath
        val childCanonical = child.canonicalPath
        if (childCanonical.length <= parentCanonical.length) return false
        if (!childCanonical.startsWith(parentCanonical)) return false
        return childCanonical[parentCanonical.length] == File.separatorChar
    }

    // ── lstat (no-follow) helpers ────────────────────────────────────────────

    private fun lstatModeOrNull(path: String): Int? {
        return try {
            Os.lstat(path).st_mode
        } catch (e: ErrnoException) {
            if (e.errno == OsConstants.ENOENT) null else throw IOException("lstat failed for $path", e)
        }
    }

    private fun existsNoFollow(file: File): Boolean = lstatModeOrNull(file.path) != null

    private fun isSymlinkNoFollow(file: File): Boolean {
        val mode = lstatModeOrNull(file.path) ?: return false
        return OsConstants.S_ISLNK(mode)
    }

    private fun isDirectoryNoFollow(file: File): Boolean {
        val mode = lstatModeOrNull(file.path) ?: return false
        return OsConstants.S_ISDIR(mode)
    }

    private fun isRegularFileNoFollow(file: File): Boolean {
        val mode = lstatModeOrNull(file.path) ?: return false
        return OsConstants.S_ISREG(mode)
    }

    /// Absent is fine (silently returns). Present-but-wrong-type throws.
    private fun validateDirectoryNoFollow(dir: File) {
        val mode = lstatModeOrNull(dir.path) ?: return
        if (OsConstants.S_ISLNK(mode)) {
            throw UnsafePathException("Symlink at expected directory path: ${dir.path}")
        }
        if (!OsConstants.S_ISDIR(mode)) {
            throw UnsafePathException("Non-directory at expected directory path: ${dir.path}")
        }
    }

    private fun ensureRootDirectory() {
        if (!existsNoFollow(rootDir)) {
            rootDir.mkdirs()
        }
        validateDirectoryNoFollow(rootDir)
        if (!existsNoFollow(rootDir)) {
            throw IOException("failed to create cache root directory: ${rootDir.path}")
        }
    }

    private fun ensureChildDirectory(dir: File) {
        if (!existsNoFollow(dir)) {
            dir.mkdir()
        }
        validateDirectoryNoFollow(dir)
        if (!existsNoFollow(dir)) {
            throw IOException("failed to create directory: ${dir.path}")
        }
    }

    // ── Topology validation helpers ──────────────────────────────────────────

    private fun isValidDensityFilename(name: String): Boolean {
        if (!name.endsWith(EXTENSION)) return false
        val numStr = name.substring(0, name.length - EXTENSION.length)
        val len = numStr.length
        if (len < 1 || len > 4) return false
        if (len > 1 && numStr[0] == '0') return false
        if (!numStr.all { it in '0'..'9' }) return false
        val value = numStr.toIntOrNull() ?: return false
        return value in 1..1000
    }

    private fun isValidAssetDirName(name: String): Boolean {
        if (!name.startsWith(KEY_PREFIX)) return false
        if (name.length != KEY_PREFIX.length + 64) return false
        val hex = name.substring(KEY_PREFIX.length)
        return hex.all { it in HEX_DIGITS }
    }

    // ── Binary payload helpers ────────────────────────────────────────────────

    private fun buildPayload(result: WaveformResult): ByteArray {
        val samples = result.samples
        if (samples.isEmpty()) throw IOException("samples must not be empty")
        val expectedBytes = result.pointCount.toLong() * 4L
        if (samples.size.toLong() != expectedBytes) {
            throw IOException("samples length ${samples.size} != pointCount*4 $expectedBytes")
        }
        val buffer = ByteBuffer.allocate(HEADER_SIZE + samples.size)
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(VERSION)
        buffer.putDouble(result.durationSeconds)
        buffer.putInt(result.samplesPerSecond)
        buffer.putInt(result.pointCount)
        buffer.put(samples)
        return buffer.array()
    }

    private fun parsePayload(data: ByteArray): WaveformResult? {
        if (data.size < HEADER_SIZE) return null
        val buffer = ByteBuffer.wrap(data)
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        val version = buffer.int
        if (version != VERSION) return null
        val durationSeconds = buffer.double
        if (!durationSeconds.isFinite() || durationSeconds <= 0.0) return null
        val sps = buffer.int
        val pointCount = buffer.int
        if (sps <= 0 || pointCount <= 0) return null
        val expectedSampleBytes = pointCount.toLong() * 4L
        val actualSampleBytes = (data.size - HEADER_SIZE).toLong()
        if (actualSampleBytes != expectedSampleBytes) return null
        val samples = data.copyOfRange(HEADER_SIZE, HEADER_SIZE + expectedSampleBytes.toInt())
        return WaveformResult(samples, durationSeconds, sps, pointCount)
    }

    // ── Atomic write ──────────────────────────────────────────────────────────

    private fun atomicWrite(finalFile: File, payload: ByteArray) {
        ensureRootDirectory()
        val tempFile = File(rootDir, TEMP_PREFIX + UUID.randomUUID().toString())
        var renamed = false
        try {
            tempFile.writeBytes(payload)
            try {
                Os.rename(tempFile.path, finalFile.path)
                renamed = true
            } catch (e: ErrnoException) {
                throw IOException("rename failed: ${tempFile.path} -> ${finalFile.path}", e)
            }
        } finally {
            if (!renamed) {
                try { tempFile.delete() } catch (_: Throwable) {}
            }
        }
    }

    // ── Legacy flat-storage API ──────────────────────────────────────────────

    /// Never throws. Returns null on any miss/corruption/unreadable/unsafe
    /// condition — legacy load never surfaces CACHE_UNSAFE_PATH.
    fun loadLegacy(cacheKey: String): WaveformResult? {
        return try {
            val file = legacyFile(cacheKey)
            if (!file.isFile) return null
            parsePayload(file.readBytes())
        } catch (t: Throwable) {
            null
        }
    }

    /// Throws on build/write failure — caller maps any exception to
    /// CACHE_SAVE_FAILED.
    fun saveLegacy(cacheKey: String, result: WaveformResult) {
        val payload = buildPayload(result)
        atomicWrite(legacyFile(cacheKey), payload)
    }

    // ── Namespaced API ────────────────────────────────────────────────────────

    /// Returns the cached result on hit, null on miss (absent/corrupt/SPS
    /// mismatch), throws [UnsafePathException] on an unsafe tree, or throws a
    /// plain IOException on unexpected read failure.
    fun loadNamespaced(namespace: String, assetKey: String, samplesPerSecond: Int): WaveformResult? {
        validateDirectoryNoFollow(rootDir)

        val nsDir = namespaceDir(namespace)
        if (!existsNoFollow(nsDir)) return null
        validateDirectoryNoFollow(nsDir)

        val assetDirFile = assetDir(namespace, assetKey)
        if (!existsNoFollow(assetDirFile)) return null
        validateDirectoryNoFollow(assetDirFile)

        val file = namespacedFile(namespace, assetKey, samplesPerSecond)
        if (!existsNoFollow(file)) return null
        if (isSymlinkNoFollow(file)) {
            throw UnsafePathException("Cache file is a symlink: ${file.path}")
        }
        if (!isContained(rootDir, file)) {
            throw UnsafePathException("Cache file path is outside root: ${file.path}")
        }

        val data = file.readBytes()
        val parsed = parsePayload(data) ?: return null
        if (parsed.samplesPerSecond != samplesPerSecond) return null
        return parsed
    }

    /// Throws [UnsafePathException] on an unsafe tree, or a plain IOException
    /// on build/write failure (including a samplesPerSecond mismatch).
    fun saveNamespaced(
        namespace: String,
        assetKey: String,
        samplesPerSecond: Int,
        result: WaveformResult,
    ) {
        if (result.samplesPerSecond != samplesPerSecond) {
            throw IOException(
                "result.samplesPerSecond ${result.samplesPerSecond} != requested $samplesPerSecond")
        }

        val nsDir = namespaceDir(namespace)
        val assetDirFile = assetDir(namespace, assetKey)
        val file = namespacedFile(namespace, assetKey, samplesPerSecond)

        if (!isContained(rootDir, file)) {
            throw UnsafePathException("Namespaced file path is outside cache root: ${file.path}")
        }

        ensureRootDirectory()
        ensureChildDirectory(nsDir)
        ensureChildDirectory(assetDirFile)

        if (existsNoFollow(file) && isSymlinkNoFollow(file)) {
            throw UnsafePathException("Cache file is a symlink — write rejected: ${file.path}")
        }

        val payload = buildPayload(result)
        atomicWrite(file, payload)
    }

    /// Idempotent: an absent asset directory is success. Throws
    /// [UnsafePathException] for a symlink, containment violation, or
    /// unexpected sibling; a plain IOException for enumeration/deletion
    /// failure.
    fun invalidateAsset(namespace: String, assetKey: String) {
        validateDirectoryNoFollow(rootDir)

        val nsDir = namespaceDir(namespace)
        if (!existsNoFollow(nsDir)) return
        validateDirectoryNoFollow(nsDir)

        val assetDirFile = assetDir(namespace, assetKey)
        if (!existsNoFollow(assetDirFile)) return
        validateDirectoryNoFollow(assetDirFile)

        if (!isContained(rootDir, assetDirFile)) {
            throw UnsafePathException("Asset directory is outside cache root: ${assetDirFile.path}")
        }

        val children = assetDirFile.list()
            ?: throw IOException("Failed to enumerate asset directory: ${assetDirFile.path}")
        for (childName in children) {
            val childFile = File(assetDirFile, childName)
            if (isSymlinkNoFollow(childFile) ||
                !isRegularFileNoFollow(childFile) ||
                !isValidDensityFilename(childName)
            ) {
                throw UnsafePathException("Unexpected sibling in asset directory: $childName")
            }
        }

        val resolvedAssetDir = File(assetDirFile.canonicalPath)
        if (!isContained(rootDir, resolvedAssetDir)) {
            throw UnsafePathException(
                "Resolved asset directory is outside cache root: ${resolvedAssetDir.path}")
        }

        for (childName in children) {
            val childFile = File(assetDirFile, childName)
            if (!childFile.delete()) throw IOException("Failed to delete: ${childFile.path}")
        }
        if (!assetDirFile.delete()) {
            throw IOException("Failed to delete directory: ${assetDirFile.path}")
        }
    }

    /// Idempotent: an absent namespace directory is success. Throws
    /// [UnsafePathException] for a symlink, containment violation, or
    /// unexpected sibling; a plain IOException for enumeration/deletion
    /// failure.
    fun invalidateNamespace(namespace: String) {
        validateDirectoryNoFollow(rootDir)

        val nsDir = namespaceDir(namespace)
        if (!existsNoFollow(nsDir)) return
        validateDirectoryNoFollow(nsDir)

        if (!isContained(rootDir, nsDir)) {
            throw UnsafePathException("Namespace directory is outside cache root: ${nsDir.path}")
        }

        val children = nsDir.list()
            ?: throw IOException("Failed to enumerate namespace directory: ${nsDir.path}")

        val assetDirs = mutableListOf<Pair<File, List<String>>>()
        for (childName in children) {
            val childFile = File(nsDir, childName)
            if (isSymlinkNoFollow(childFile)) {
                throw UnsafePathException("Symlink in namespace directory: $childName")
            }
            if (!isDirectoryNoFollow(childFile)) {
                throw UnsafePathException("Non-directory in namespace directory: $childName")
            }
            if (!isValidAssetDirName(childName)) {
                throw UnsafePathException("Unexpected sibling in namespace directory: $childName")
            }
            if (!isContained(rootDir, childFile)) {
                throw UnsafePathException("Asset directory outside cache root: $childName")
            }
            val leafNames = childFile.list()
                ?: throw IOException("Failed to enumerate asset subtree: ${childFile.path}")
            for (leafName in leafNames) {
                val leafFile = File(childFile, leafName)
                if (isSymlinkNoFollow(leafFile) ||
                    !isRegularFileNoFollow(leafFile) ||
                    !isValidDensityFilename(leafName)
                ) {
                    throw UnsafePathException(
                        "Unexpected content in asset subtree $childName: $leafName")
                }
            }
            assetDirs.add(childFile to leafNames.toList())
        }

        val resolvedNsDir = File(nsDir.canonicalPath)
        if (!isContained(rootDir, resolvedNsDir)) {
            throw UnsafePathException(
                "Resolved namespace directory is outside cache root: ${resolvedNsDir.path}")
        }

        for ((assetDirFile, leafNames) in assetDirs) {
            for (leafName in leafNames) {
                val leafFile = File(assetDirFile, leafName)
                if (!leafFile.delete()) throw IOException("Failed to delete: ${leafFile.path}")
            }
            if (!assetDirFile.delete()) {
                throw IOException("Failed to delete directory: ${assetDirFile.path}")
            }
        }
        if (!nsDir.delete()) {
            throw IOException("Failed to delete directory: ${nsDir.path}")
        }
    }
}
