package com.connects.vanguard_media_engine.audio

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/**
 * Vanguard Android Phase 5-Unit X / Phase 4-Unit F: Waveform Cache Smoke Harness.
 *
 * Validates native disk cache behavior, path safety, and subtree invalidation invariants:
 * - Injected temp root under context.cacheDir with unique smoke prefix.
 * - Instantiates AndroidWaveformCache directly.
 * - No external storage, network, MediaCodec, ExoPlayer, or app state mutation.
 * - Guaranteed cleanup in finally without following symlinks.
 */
object AndroidWaveformCacheSmokeHarness {

    private const val TAG = "AndroidWaveformCacheSmoke"
    private const val SMOKE_PREFIX = "vanguard_waveform_cache_unit_x_smoke_"

    private fun sha256Hex(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append(String.format("%02x", b))
        return sb.toString()
    }

    private fun safeDeleteRecursive(file: File) {
        try {
            val mode = try {
                Os.lstat(file.path).st_mode
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.ENOENT) return else throw e
            }
            if (OsConstants.S_ISLNK(mode) || !OsConstants.S_ISDIR(mode)) {
                file.delete()
                return
            }
            val children = file.listFiles()
            if (children != null) {
                for (child in children) {
                    safeDeleteRecursive(child)
                }
            }
            file.delete()
        } catch (_: Throwable) {
            // best-effort cleanup per node
        }
    }

    fun run(context: Context): Map<String, Any?> {
        val uniqueRunId = UUID.randomUUID().toString()
        val tempRoot = File(context.cacheDir, "$SMOKE_PREFIX$uniqueRunId")

        var laneAPass = false
        var laneBPass = false
        var laneCPass = false
        var laneDPass = false
        var laneEPass = false
        var laneFPass = false
        var cleanupPass = false
        var rawStatus = "INIT"

        try {
            tempRoot.mkdirs()
            val cache = AndroidWaveformCache(tempRoot)

            val testSamples = ByteArray(16) { (it * 7 + 1).toByte() }
            val testResult = AndroidWaveformCache.WaveformResult(
                samples = testSamples,
                durationSeconds = 2.5,
                samplesPerSecond = 100,
                pointCount = 4,
            )

            // ── Lane A: Legacy save/load round-trip ──────────────────────────
            try {
                cache.saveLegacy("unit_x_legacy_key_1", testResult)
                val loadedA = cache.loadLegacy("unit_x_legacy_key_1")
                val loadedMissing = cache.loadLegacy("unit_x_legacy_missing")
                laneAPass = loadedA != null &&
                    loadedA.samples.contentEquals(testResult.samples) &&
                    loadedA.durationSeconds == testResult.durationSeconds &&
                    loadedA.samplesPerSecond == testResult.samplesPerSecond &&
                    loadedA.pointCount == testResult.pointCount &&
                    loadedMissing == null
            } catch (t: Throwable) {
                Log.e(TAG, "Lane A failed", t)
                laneAPass = false
            }

            // ── Lane B: Namespaced save/load round-trip & SPS mismatch ────────
            try {
                val nsB = "unit_x_ns_b"
                val akB = "unit_x_ak_b"
                cache.saveNamespaced(nsB, akB, 100, testResult)
                val loadedHit = cache.loadNamespaced(nsB, akB, 100)
                val loadedDiffSps = cache.loadNamespaced(nsB, akB, 50)
                val loadedMissing = cache.loadNamespaced(nsB, "missing_ak", 100)
                laneBPass = loadedHit != null &&
                    loadedHit.samples.contentEquals(testResult.samples) &&
                    loadedHit.durationSeconds == testResult.durationSeconds &&
                    loadedHit.samplesPerSecond == testResult.samplesPerSecond &&
                    loadedHit.pointCount == testResult.pointCount &&
                    loadedDiffSps == null &&
                    loadedMissing == null
            } catch (t: Throwable) {
                Log.e(TAG, "Lane B failed", t)
                laneBPass = false
            }

            // ── Lane C: Symlink cache file rejection ─────────────────────────
            try {
                val symNs = "unit_x_sym_ns"
                val symAk = "unit_x_sym_ak"
                val symSps = 100
                val symAssetDir = File(
                    File(tempRoot, "n_${sha256Hex(symNs)}"),
                    "k_${sha256Hex(symAk)}"
                )
                symAssetDir.mkdirs()
                val targetFile = File(tempRoot, "sym_target.txt")
                targetFile.writeText("symlink_target_canary")
                val symFile = File(symAssetDir, "$symSps.vgwc")
                Os.symlink(targetFile.absolutePath, symFile.path)

                var loadThrew = false
                try {
                    cache.loadNamespaced(symNs, symAk, symSps)
                } catch (_: AndroidWaveformCache.UnsafePathException) {
                    loadThrew = true
                }

                var saveThrew = false
                try {
                    cache.saveNamespaced(symNs, symAk, symSps, testResult)
                } catch (_: AndroidWaveformCache.UnsafePathException) {
                    saveThrew = true
                }

                laneCPass = loadThrew && saveThrew
            } catch (t: Throwable) {
                Log.e(TAG, "Lane C failed", t)
                laneCPass = false
            }

            // ── Lane D: Subtree invalidation unexpected sibling rejection ─────
            try {
                // Asset directory with rogue file
                val invNs = "unit_x_inv_ns"
                val invAk = "unit_x_inv_ak"
                cache.saveNamespaced(invNs, invAk, 100, testResult)
                val invAssetDir = File(
                    File(tempRoot, "n_${sha256Hex(invNs)}"),
                    "k_${sha256Hex(invAk)}"
                )
                val rogueFile = File(invAssetDir, "rogue_sibling.txt")
                rogueFile.writeText("rogue_canary")

                var assetInvThrew = false
                try {
                    cache.invalidateAsset(invNs, invAk)
                } catch (_: AndroidWaveformCache.UnsafePathException) {
                    assetInvThrew = true
                }
                val rogueStillExists = rogueFile.exists()

                // Namespace directory with rogue subfolder
                val invNs2 = "unit_x_inv_ns2"
                val invAk2 = "unit_x_inv_ak2"
                cache.saveNamespaced(invNs2, invAk2, 100, testResult)
                val invNsDir2 = File(tempRoot, "n_${sha256Hex(invNs2)}")
                val rogueSubDir = File(invNsDir2, "rogue_subfolder")
                rogueSubDir.mkdir()

                var nsInvThrew = false
                try {
                    cache.invalidateNamespace(invNs2)
                } catch (_: AndroidWaveformCache.UnsafePathException) {
                    nsInvThrew = true
                }
                val rogueDirStillExists = rogueSubDir.exists()

                // Namespace directory with symlink child
                val invNs3 = "unit_x_inv_ns3"
                val invNsDir3 = File(tempRoot, "n_${sha256Hex(invNs3)}")
                invNsDir3.mkdirs()
                val targetFile3 = File(tempRoot, "sym_target3.txt")
                targetFile3.writeText("canary3")
                val symlinkInNs = File(invNsDir3, "k_${sha256Hex("fake_asset")}")
                Os.symlink(targetFile3.absolutePath, symlinkInNs.path)

                var symNsInvThrew = false
                try {
                    cache.invalidateNamespace(invNs3)
                } catch (_: AndroidWaveformCache.UnsafePathException) {
                    symNsInvThrew = true
                }
                val symExists = try {
                    Os.lstat(symlinkInNs.path) != null
                } catch (e: ErrnoException) {
                    false
                }

                laneDPass = assetInvThrew && rogueStillExists &&
                    nsInvThrew && rogueDirStillExists &&
                    symNsInvThrew && symExists
            } catch (t: Throwable) {
                Log.e(TAG, "Lane D failed", t)
                laneDPass = false
            }

            // ── Lane E: Missing invalidation targets return success ───────────
            try {
                var missAssetOk = false
                try {
                    cache.invalidateAsset("unit_x_missing_ns", "unit_x_missing_ak")
                    missAssetOk = true
                } catch (_: Throwable) {
                    missAssetOk = false
                }

                var missNsOk = false
                try {
                    cache.invalidateNamespace("unit_x_missing_ns_2")
                    missNsOk = true
                } catch (_: Throwable) {
                    missNsOk = false
                }

                laneEPass = missAssetOk && missNsOk
            } catch (t: Throwable) {
                Log.e(TAG, "Lane E failed", t)
                laneEPass = false
            }

            // ── Lane F: No temporary files left after atomic writes ───────────
            try {
                val tempFiles = tempRoot.listFiles { _, name -> name.startsWith(".vgwc_tmp_") }
                laneFPass = tempFiles != null && tempFiles.isEmpty()
            } catch (t: Throwable) {
                Log.e(TAG, "Lane F failed", t)
                laneFPass = false
            }

            val allLanes = laneAPass && laneBPass && laneCPass && laneDPass && laneEPass && laneFPass
            rawStatus = "laneA=$laneAPass;laneB=$laneBPass;laneC=$laneCPass;laneD=$laneDPass;laneE=$laneEPass;laneF=$laneFPass"
        } finally {
            if (tempRoot.name.startsWith(SMOKE_PREFIX)) {
                safeDeleteRecursive(tempRoot)
                cleanupPass = !tempRoot.exists()
            }
        }

        val pass = laneAPass && laneBPass && laneCPass && laneDPass && laneEPass && laneFPass && cleanupPass
        rawStatus = "$rawStatus;cleanup=$cleanupPass;overall=$pass"

        return mapOf(
            "phase" to "Phase5UnitX",
            "pass" to pass,
            "laneA_legacyRoundTrip" to laneAPass,
            "laneB_namespacedRoundTrip" to laneBPass,
            "laneC_symlinkFileRejection" to laneCPass,
            "laneD_unexpectedSiblingRejection" to laneDPass,
            "laneE_missingInvalidateSuccess" to laneEPass,
            "laneF_noTempFilesLeft" to laneFPass,
            "cleanupPass" to cleanupPass,
            "raw" to rawStatus,
        )
    }
}
