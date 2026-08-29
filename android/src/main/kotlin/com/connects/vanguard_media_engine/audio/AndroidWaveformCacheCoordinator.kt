package com.connects.vanguard_media_engine.audio

import android.content.Context
import android.os.Handler
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

// ── AndroidWaveformCacheCoordinator (Phase 5-Unit X / Phase 4-Unit F) ─────────
//
// Owns all six waveform-cache MethodChannel routes, mirroring
// VGWaveformCacheMethodHandler.swift (iOS):
//   - waveformCache_save / waveformCache_load (legacy flat storage)
//   - waveformCache_lookupNamespaced / waveformCache_saveNamespaced
//   - waveformCache_invalidateAsset / waveformCache_invalidateNamespace
//
// Architecture:
//   - A single daemon-thread Executor serializes all epoch mutation and disk
//     I/O — arg validation happens synchronously on the calling thread, but
//     everything that reads/writes epoch state or touches disk is submitted
//     to the executor so epoch state stays internally consistent.
//   - Epoch state (namespaceEpochs + assetEpochs) is process-local and is
//     only ever touched from the executor thread.
//   - A per-coordinator session id is embedded in write tokens. A token
//     minted before a session rotation cannot match the current session id.
//   - Write tokens are HMAC-SHA256 authenticated using a per-session random
//     32-byte secret (java.security.SecureRandom).
//   - Every MethodChannel.Result is wrapped by [GuardedReply]: an
//     AtomicBoolean compareAndSet ensures at most one reply per call, posted
//     through [mainHandler], and every posted runnable checks [detached]
//     first so no channel call happens after onDetachedFromEngine.
class AndroidWaveformCacheCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
    private val cache: AndroidWaveformCache =
        AndroidWaveformCache(File(context.cacheDir, "vanguard_waveforms")),
) {
    companion object {
        private val OWNED_METHODS = setOf(
            "waveformCache_save",
            "waveformCache_load",
            "waveformCache_lookupNamespaced",
            "waveformCache_saveNamespaced",
            "waveformCache_invalidateAsset",
            "waveformCache_invalidateNamespace",
            "runAndroidWaveformCacheUnitXSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS

        private const val ERR_INVALID_ARG = "INVALID_ARG"
        private const val ERR_SAVE_FAILED = "CACHE_SAVE_FAILED"
        private const val ERR_LOAD_FAILED = "CACHE_LOAD_FAILED"
        private const val ERR_INVALIDATION_FAILED = "CACHE_INVALIDATION_FAILED"
        private const val ERR_UNSAFE_PATH = "CACHE_UNSAFE_PATH"
        private const val ERR_TOKEN_INVALID = "CACHE_TOKEN_INVALID"
        private const val ERR_LEASE_MISMATCH = "CACHE_LEASE_MISMATCH"

        private const val EPOCH_KEY_SEPARATOR = " "

        private const val TOK_VERSION = "v"
        private const val TOK_NS = "ns"
        private const val TOK_AK = "ak"
        private const val TOK_SPS = "sps"
        private const val TOK_SID = "sid"
        private const val TOK_NSE = "nse"
        private const val TOK_ASE = "ase"

        private const val B64_FLAGS = Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP
    }

    /** AtomicBoolean-guarded, detach-aware [MethodChannel.Result] wrapper. */
    private inner class GuardedReply(private val result: MethodChannel.Result) {
        private val fired = AtomicBoolean(false)

        fun success(value: Any?) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.success(value)
                }
            }
        }

        fun error(code: String, message: String?) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.error(code, message, null)
                }
            }
        }
    }

    private data class TokenPayload(
        val namespace: String,
        val assetKey: String,
        val samplesPerSecond: Int,
        val sessionId: String,
        val nsEpoch: Long,
        val assetEpoch: Long,
    )

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "AndroidWaveformCacheCoordinator").apply { isDaemon = true }
    }

    @Volatile private var detached = false

    // ── Identity + epoch state — only ever touched from [executor] ──────────
    private var sessionId: String = UUID.randomUUID().toString()
    private var secretKey: ByteArray = randomSecret()
    private val namespaceEpochs = mutableMapOf<String, Long>()
    private val assetEpochs = mutableMapOf<String, Long>()

    private fun randomSecret(): ByteArray {
        val secret = ByteArray(32)
        SecureRandom().nextBytes(secret)
        return secret
    }

    private fun submit(block: () -> Unit) {
        try {
            executor.execute(block)
        } catch (_: RejectedExecutionException) {
            // Only possible after disposeAll() has shut the executor down —
            // detached is already true and any GuardedReply would be dropped
            // anyway, so there is nothing further to do here.
        }
    }

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        when (method) {
            "waveformCache_save" -> handleLegacySave(args, result)
            "waveformCache_load" -> handleLegacyLoad(args, result)
            "waveformCache_lookupNamespaced" -> handleLookupNamespaced(args, result)
            "waveformCache_saveNamespaced" -> handleSaveNamespaced(args, result)
            "waveformCache_invalidateAsset" -> handleInvalidateAsset(args, result)
            "waveformCache_invalidateNamespace" -> handleInvalidateNamespace(args, result)
            "runAndroidWaveformCacheUnitXSmoke" -> handleUnitXSmoke(result)
        }
    }

    // ── Identifier validation ────────────────────────────────────────────────

    private fun isValidIdentifier(value: String): Boolean {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > 512) return false
        for (b in bytes) if (b.toInt() == 0) return false
        return true
    }

    // ── Epoch helpers (must only run on [executor]) ──────────────────────────

    private fun combinedKey(namespace: String, assetKey: String): String =
        namespace + EPOCH_KEY_SEPARATOR + assetKey

    private fun nsEpoch(namespace: String): Long = namespaceEpochs[namespace] ?: 0L

    private fun assetEpoch(namespace: String, assetKey: String): Long =
        assetEpochs[combinedKey(namespace, assetKey)] ?: 0L

    /// Overflow rotation: on Long.MAX_VALUE, rotate session id + secret and
    /// clear both epoch maps (mirrors VGWaveformCacheMethodHandler.swift).
    private fun nextEpoch(current: Long): Long {
        if (current == Long.MAX_VALUE) {
            secretKey = randomSecret()
            sessionId = UUID.randomUUID().toString()
            namespaceEpochs.clear()
            assetEpochs.clear()
            return 0L
        }
        return current + 1
    }

    // ── Base64url + HMAC helpers ─────────────────────────────────────────────

    private fun base64UrlEncode(data: ByteArray): String =
        Base64.encodeToString(data, B64_FLAGS)

    private fun base64UrlDecode(str: String): ByteArray? = try {
        Base64.decode(str, B64_FLAGS)
    } catch (_: Throwable) {
        null
    }

    private fun computeHmac(data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secretKey, "HmacSHA256"))
        return mac.doFinal(data)
    }

    // ── Token build / verify (must only run on [executor]) ──────────────────

    private fun buildToken(
        namespace: String,
        assetKey: String,
        samplesPerSecond: Int,
        nsEpoch: Long,
        assetEpoch: Long,
    ): String {
        val payload = JSONObject()
        payload.put(TOK_VERSION, 1)
        payload.put(TOK_NS, namespace)
        payload.put(TOK_AK, assetKey)
        payload.put(TOK_SPS, samplesPerSecond)
        payload.put(TOK_SID, sessionId)
        payload.put(TOK_NSE, nsEpoch)
        payload.put(TOK_ASE, assetEpoch)
        val payloadBytes = payload.toString().toByteArray(Charsets.UTF_8)
        val payloadB64 = base64UrlEncode(payloadBytes)
        val macB64 = base64UrlEncode(computeHmac(payloadBytes))
        return "$payloadB64.$macB64"
    }

    private fun verifyToken(token: String): TokenPayload? {
        val dotIdx = token.indexOf('.')
        if (dotIdx < 0) return null
        val payloadB64 = token.substring(0, dotIdx)
        val macB64 = token.substring(dotIdx + 1)
        if (payloadB64.isEmpty() || macB64.isEmpty()) return null

        val payloadBytes = base64UrlDecode(payloadB64) ?: return null
        val macBytes = base64UrlDecode(macB64) ?: return null

        // Verify HMAC BEFORE JSON decoding.
        val expectedMac = computeHmac(payloadBytes)
        if (!MessageDigest.isEqual(expectedMac, macBytes)) return null

        return try {
            val json = JSONObject(String(payloadBytes, Charsets.UTF_8))

            val version = json.strictInt(TOK_VERSION) ?: return null
            if (version != 1) return null

            val ns = json.strictString(TOK_NS) ?: return null
            if (!isValidIdentifier(ns)) return null

            val ak = json.strictString(TOK_AK) ?: return null
            if (!isValidIdentifier(ak)) return null

            val sid = json.strictString(TOK_SID) ?: return null
            if (sid.isEmpty()) return null

            val spsInt = json.strictInt(TOK_SPS) ?: return null
            if (spsInt < 1 || spsInt > 1000) return null

            val nseLong = json.strictLong(TOK_NSE) ?: return null
            if (nseLong < 0L) return null

            val aseLong = json.strictLong(TOK_ASE) ?: return null
            if (aseLong < 0L) return null

            TokenPayload(ns, ak, spsInt, sid, nseLong, aseLong)
        } catch (_: Throwable) {
            null
        }
    }

    /// Strict JSON field readers: reject missing keys, JSONObject.NULL, and
    /// wrong types instead of silently coercing (org.json's opt*/get* family
    /// coerces numeric strings). [strictInt]/[strictLong] additionally reject
    /// non-finite and fractional numeric values instead of truncating them,
    /// so a forged-but-HMAC-stripped token can't slip a value like 1.5 past
    /// validation via Number.toInt()/toLong() truncation.
    private fun JSONObject.strictNumber(key: String): Number? {
        if (!has(key)) return null
        val value = get(key)
        return value as? Number
    }

    private fun JSONObject.strictString(key: String): String? {
        if (!has(key)) return null
        val value = get(key)
        return value as? String
    }

    private fun JSONObject.strictInt(key: String): Int? {
        val number = strictNumber(key) ?: return null
        val d = number.toDouble()
        if (!d.isFinite()) return null
        val l = number.toLong()
        if (l.toDouble() != d) return null
        if (l < Int.MIN_VALUE || l > Int.MAX_VALUE) return null
        return l.toInt()
    }

    private fun JSONObject.strictLong(key: String): Long? {
        val number = strictNumber(key) ?: return null
        val d = number.toDouble()
        if (!d.isFinite()) return null
        val l = number.toLong()
        if (l.toDouble() != d) return null
        return l
    }

    // ── Waveform result encode helper ────────────────────────────────────────

    private fun encodeWaveformResult(r: AndroidWaveformCache.WaveformResult): Map<String, Any?> = mapOf(
        "samples" to r.samples,
        "durationSeconds" to r.durationSeconds,
        "samplesPerSecond" to r.samplesPerSecond,
        "pointCount" to r.pointCount,
    )

    // ── waveformCache_save ───────────────────────────────────────────────────

    private fun handleLegacySave(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val cacheKey = (args?.get("cacheKey") as? String)?.takeIf { it.isNotEmpty() }
        if (cacheKey == null) {
            reply.error(ERR_INVALID_ARG, "cacheKey is required and must be non-empty")
            return
        }
        val samples = args.get("samples") as? ByteArray
        if (samples == null || samples.isEmpty()) {
            reply.error(ERR_INVALID_ARG, "samples must be non-empty")
            return
        }
        val durationSeconds = (args.get("durationSeconds") as? Number)?.toDouble()
        if (durationSeconds == null || !durationSeconds.isFinite() || durationSeconds <= 0.0) {
            reply.error(ERR_INVALID_ARG, "durationSeconds must be finite and > 0")
            return
        }
        val sps = (args.get("samplesPerSecond") as? Number)?.toInt()
        if (sps == null || sps <= 0) {
            reply.error(ERR_INVALID_ARG, "samplesPerSecond is required and must be > 0")
            return
        }
        val pointCount = (args.get("pointCount") as? Number)?.toInt()
        if (pointCount == null || pointCount <= 0) {
            reply.error(ERR_INVALID_ARG, "pointCount is required and must be > 0")
            return
        }

        val waveResult = AndroidWaveformCache.WaveformResult(samples, durationSeconds, sps, pointCount)
        submit {
            try {
                cache.saveLegacy(cacheKey, waveResult)
                reply.success(null)
            } catch (t: Throwable) {
                reply.error(ERR_SAVE_FAILED, t.message ?: t.javaClass.simpleName)
            }
        }
    }

    // ── waveformCache_load ───────────────────────────────────────────────────

    private fun handleLegacyLoad(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val cacheKey = (args?.get("cacheKey") as? String)?.takeIf { it.isNotEmpty() }
        if (cacheKey == null) {
            reply.error(ERR_INVALID_ARG, "cacheKey is required and must be non-empty")
            return
        }

        submit {
            val cached = cache.loadLegacy(cacheKey)
            if (cached != null) {
                reply.success(encodeWaveformResult(cached))
            } else {
                reply.success(null)
            }
        }
    }

    // ── waveformCache_lookupNamespaced ───────────────────────────────────────

    private fun handleLookupNamespaced(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val namespace = args?.get("namespace") as? String
        val assetKey = args?.get("assetKey") as? String
        val sps = (args?.get("samplesPerSecond") as? Number)?.toInt()
        if (namespace == null || !isValidIdentifier(namespace) ||
            assetKey == null || !isValidIdentifier(assetKey) ||
            sps == null || sps < 1 || sps > 1000
        ) {
            reply.error(
                ERR_INVALID_ARG,
                "namespace, assetKey must be 1-512 UTF-8 bytes without NUL; " +
                    "samplesPerSecond must be in 1-1000")
            return
        }

        submit {
            val nse = nsEpoch(namespace)
            val ase = assetEpoch(namespace, assetKey)
            try {
                val cached = cache.loadNamespaced(namespace, assetKey, sps)
                if (cached != null) {
                    reply.success(mapOf("status" to "hit", "result" to encodeWaveformResult(cached)))
                } else {
                    val token = buildToken(namespace, assetKey, sps, nse, ase)
                    reply.success(mapOf("status" to "miss", "writeLease" to token))
                }
            } catch (e: AndroidWaveformCache.UnsafePathException) {
                reply.error(ERR_UNSAFE_PATH, e.message)
            } catch (t: Throwable) {
                reply.error(ERR_LOAD_FAILED, t.message ?: t.javaClass.simpleName)
            }
        }
    }

    // ── waveformCache_saveNamespaced ─────────────────────────────────────────

    private fun handleSaveNamespaced(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val token = (args?.get("token") as? String)?.takeIf { it.isNotEmpty() }
        if (token == null) {
            reply.error(ERR_INVALID_ARG, "token is required and must be non-empty")
            return
        }
        val samples = args.get("samples") as? ByteArray
        if (samples == null || samples.isEmpty()) {
            reply.error(ERR_INVALID_ARG, "samples must be non-empty")
            return
        }
        val durationSeconds = (args.get("durationSeconds") as? Number)?.toDouble()
        if (durationSeconds == null || !durationSeconds.isFinite() || durationSeconds <= 0.0) {
            reply.error(ERR_INVALID_ARG, "durationSeconds must be finite and > 0")
            return
        }
        val spsArg = (args.get("samplesPerSecond") as? Number)?.toInt()
        if (spsArg == null || spsArg < 1 || spsArg > 1000) {
            reply.error(ERR_INVALID_ARG, "samplesPerSecond is required and must be in 1-1000")
            return
        }
        val pointCount = (args.get("pointCount") as? Number)?.toInt()
        if (pointCount == null || pointCount <= 0) {
            reply.error(ERR_INVALID_ARG, "pointCount is required and must be > 0")
            return
        }

        submit {
            val tok = verifyToken(token)
            if (tok == null) {
                reply.error(
                    ERR_TOKEN_INVALID,
                    "Write token is malformed, has an invalid signature, or invalid payload")
                return@submit
            }
            if (tok.sessionId != sessionId) {
                reply.error(ERR_TOKEN_INVALID, "Write token belongs to a prior process session")
                return@submit
            }
            if (tok.samplesPerSecond != spsArg) {
                reply.error(
                    ERR_LEASE_MISMATCH,
                    "samplesPerSecond $spsArg does not match lease value ${tok.samplesPerSecond}")
                return@submit
            }

            val curNse = nsEpoch(tok.namespace)
            val curAse = assetEpoch(tok.namespace, tok.assetKey)
            if (tok.nsEpoch != curNse || tok.assetEpoch != curAse) {
                reply.success(mapOf("status" to "stale"))
                return@submit
            }

            val waveResult = AndroidWaveformCache.WaveformResult(
                samples, durationSeconds, tok.samplesPerSecond, pointCount)
            try {
                cache.saveNamespaced(tok.namespace, tok.assetKey, tok.samplesPerSecond, waveResult)
                reply.success(mapOf("status" to "saved"))
            } catch (e: AndroidWaveformCache.UnsafePathException) {
                reply.error(ERR_UNSAFE_PATH, e.message)
            } catch (t: Throwable) {
                reply.error(ERR_SAVE_FAILED, t.message ?: t.javaClass.simpleName)
            }
        }
    }

    // ── waveformCache_invalidateAsset ────────────────────────────────────────

    private fun handleInvalidateAsset(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val namespace = args?.get("namespace") as? String
        val assetKey = args?.get("assetKey") as? String
        if (namespace == null || !isValidIdentifier(namespace) ||
            assetKey == null || !isValidIdentifier(assetKey)
        ) {
            reply.error(ERR_INVALID_ARG, "namespace and assetKey must be 1-512 UTF-8 bytes without NUL")
            return
        }

        submit {
            val ck = combinedKey(namespace, assetKey)
            assetEpochs[ck] = nextEpoch(assetEpochs[ck] ?: 0L)
            try {
                cache.invalidateAsset(namespace, assetKey)
                reply.success(null)
            } catch (e: AndroidWaveformCache.UnsafePathException) {
                reply.error(ERR_UNSAFE_PATH, e.message)
            } catch (t: Throwable) {
                reply.error(ERR_INVALIDATION_FAILED, t.message ?: t.javaClass.simpleName)
            }
        }
    }

    // ── waveformCache_invalidateNamespace ────────────────────────────────────

    private fun handleInvalidateNamespace(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val namespace = args?.get("namespace") as? String
        if (namespace == null || !isValidIdentifier(namespace)) {
            reply.error(ERR_INVALID_ARG, "namespace must be 1-512 UTF-8 bytes without NUL")
            return
        }

        submit {
            namespaceEpochs[namespace] = nextEpoch(namespaceEpochs[namespace] ?: 0L)
            val prefix = namespace + EPOCH_KEY_SEPARATOR
            val keysToRemove = assetEpochs.keys.filter { it.startsWith(prefix) }
            for (k in keysToRemove) assetEpochs.remove(k)
            try {
                cache.invalidateNamespace(namespace)
                reply.success(null)
            } catch (e: AndroidWaveformCache.UnsafePathException) {
                reply.error(ERR_UNSAFE_PATH, e.message)
            } catch (t: Throwable) {
                reply.error(ERR_INVALIDATION_FAILED, t.message ?: t.javaClass.simpleName)
            }
        }
    }

    // ── Diagnostic unit X smoke route ────────────────────────────────────────

    private fun handleUnitXSmoke(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        submit {
            try {
                val smokeResult = AndroidWaveformCacheSmokeHarness.run(context)
                reply.success(smokeResult)
            } catch (t: Throwable) {
                reply.error("SMOKE_FAILED", t.message ?: t.javaClass.simpleName)
            }
        }
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /// Idempotently detaches and shuts the executor down. Never
    /// shutdownNow() — in-flight I/O is allowed to finish, but its
    /// GuardedReply will be dropped since [detached] is already true.
    fun disposeAll() {
        detached = true
        executor.shutdown()
    }
}
