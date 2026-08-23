package com.connects.vanguard_media_engine.streaming

import android.util.Log
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element
import org.w3c.dom.Node

/**
 * Vanguard Android True-DAG Phase 4C5C: Manifest & Rendition Ladder Inspector.
 *
 * Official Android & Media3 Platform Facts:
 * - Media3 ExoPlayer supports HLS, Apple LL-HLS, and DASH containers.
 * - Multivariant adaptation in HLS depends on variant #EXT-X-STREAM-INF entries plus device capabilities.
 * - DASH adaptation relies on Period -> AdaptationSet -> Representation hierarchies.
 * - ExoPlayer network stacks are injected through DataSource factories, but diagnostic ladder
 *   inspection must remain pure, bounded, and decoupled from playback session lifecycles.
 * - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
 *   must remain mandatory so older Android devices and iOS mirrors do not hiccup.
 *
 * Mechanical Invariants:
 * - Manifest-only bounded HTTP GETs (connect/read timeouts, max payload size cap).
 * - MUST NEVER download media segments (.ts, .m4s, .mp4, .webm).
 * - MUST NEVER instantiate ExoPlayer, MediaCodec, Surface, ImageReader, HardwareBuffer, Vulkan,
 *   GLES, or DAG renderer.
 * - Secure XML parsing with external entities and DTD loading disabled.
 * - Returns pure Kotlin maps/lists suitable for MethodChannel serialization.
 */
object AdaptiveStreamingManifestRenditionInspector {

    private const val TAG = "ManifestRenditionInsp"

    const val PHASE = "Phase4C5C"
    const val SERVER_LADDER_POLICY = "add_hevc_av1_renditions_but_keep_avc_fallback"
    const val IOS_MIRROR_NOTE =
        "iOS AVPlayer/AVFoundation manifest selection must maintain H.264/AVC fallback renditions alongside HEVC/AV1."

    private const val CONNECT_TIMEOUT_MS = 8000
    private const val READ_TIMEOUT_MS = 12000
    private const val MAX_MANIFEST_CHARS = 2 * 1024 * 1024 // 2 MB char cap
    private const val MAX_REDIRECTS = 5

    val MEDIA_SEGMENT_EXTENSIONS: Set<String> = setOf(
        "ts",
        "m4s",
        "mp4",
        "webm",
        "m4a",
        "m4v",
        "m4b",
        "m4p",
        "aac",
        "mp3",
        "ogg",
        "oga",
        "opus",
        "flac",
        "wav",
        "f4v",
        "f4f",
        "cmfv",
        "cmfa",
    )

    data class CodecFamilyFlags(
        val hasAvc: Boolean,
        val hasHevc: Boolean,
        val hasAv1: Boolean,
        val detectedFamilies: List<String>,
    )

    /**
     * Rejects obvious media segment / container URIs (.ts, .m4s, .mp4, .webm, etc.)
     * to ensure the manifest inspector never downloads raw media payloads.
     */
    fun isMediaSegmentUri(uriStr: String): Boolean {
        if (uriStr.isBlank()) return false
        val path = try {
            val uri = URI(uriStr)
            uri.path ?: uriStr.substringBefore('?').substringBefore('#')
        } catch (_: Throwable) {
            uriStr.substringBefore('?').substringBefore('#')
        }
        val cleanPath = path.lowercase().trimEnd()
        val lastSlash = cleanPath.lastIndexOf('/')
        val filename = if (lastSlash != -1) cleanPath.substring(lastSlash + 1) else cleanPath
        val dotIndex = filename.lastIndexOf('.')
        if (dotIndex != -1 && dotIndex < filename.length - 1) {
            val ext = filename.substring(dotIndex + 1)
            return ext in MEDIA_SEGMENT_EXTENSIONS
        }
        return false
    }

    /**
     * Inspects a streaming manifest by URI, auto-detecting format if [formatHint] is not provided.
     */
    fun inspectUri(
        uri: String,
        formatHint: String? = null,
        httpHeaders: Map<String, String>? = null,
    ): Map<String, Any?> {
        return try {
            if (isMediaSegmentUri(uri)) {
                throw IOException("media_segment_uri_rejected: $uri")
            }
            val (manifestText, resolvedUri) = fetchText(uri, httpHeaders)
            val format = determineFormat(resolvedUri, manifestText, formatHint)
            when (format) {
                AdaptiveStreamFormat.HLS -> inspectHlsManifest(manifestText, resolvedUri, uri)
                AdaptiveStreamFormat.DASH -> inspectDashManifest(manifestText, resolvedUri, uri)
                else -> inspectHlsManifest(manifestText, resolvedUri, uri)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Failed inspecting manifest at $uri: ${t.message}")
            val formatStr = formatHint ?: "UNKNOWN"
            mapOf(
                "format" to formatStr,
                "uri" to uri,
                "resolvedUri" to uri,
                "fetchSuccess" to false,
                "parseSuccess" to false,
                "isMediaPlaylist" to false,
                "variantCount" to 0,
                "representationCount" to 0,
                "hasAdaptiveLadder" to false,
                "hasAvc" to false,
                "hasHevc" to false,
                "hasAv1" to false,
                "serverPolicyPass" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "variants" to emptyList<Map<String, Any?>>(),
                "representations" to emptyList<Map<String, Any?>>(),
                "raw" to "status=FAIL;reason=fetch_or_parse_exception:${t.javaClass.simpleName}:${t.message}",
            )
        }
    }

    /**
     * Inspects HLS multivariant or media playlist text line-by-line.
     */
    fun inspectHlsManifest(
        manifestText: String,
        resolvedUri: String = "",
        originalUri: String = "",
    ): Map<String, Any?> {
        return try {
            val lines = manifestText.lines().map { it.trim() }
            val variants = mutableListOf<Map<String, Any?>>()

            var hasExtXPart = false
            var hasExtXServerControl = false
            var hasExtXPreloadHint = false
            var hasExtXPartInf = false
            var hasExtInf = false
            var hasTargetDuration = false

            var pendingStreamInfAttr: Map<String, String>? = null

            for (line in lines) {
                if (line.isEmpty()) continue

                if (line.startsWith("#EXT-X-PART:") || line.startsWith("#EXT-X-PART ")) {
                    hasExtXPart = true
                }
                if (line.startsWith("#EXT-X-SERVER-CONTROL:") || line.startsWith("#EXT-X-SERVER-CONTROL ")) {
                    hasExtXServerControl = true
                }
                if (line.startsWith("#EXT-X-PRELOAD-HINT:") || line.startsWith("#EXT-X-PRELOAD-HINT ")) {
                    hasExtXPreloadHint = true
                }
                if (line.startsWith("#EXT-X-PART-INF:") || line.startsWith("#EXT-X-PART-INF ")) {
                    hasExtXPartInf = true
                }
                if (line.startsWith("#EXTINF:") || line.startsWith("#EXTINF ")) {
                    hasExtInf = true
                }
                if (line.startsWith("#EXT-X-TARGETDURATION:") || line.startsWith("#EXT-X-TARGETDURATION ")) {
                    hasTargetDuration = true
                }

                if (line.startsWith("#EXT-X-STREAM-INF:")) {
                    val attrString = line.substringAfter("#EXT-X-STREAM-INF:")
                    pendingStreamInfAttr = parseHlsAttributeList(attrString)
                    continue
                }

                if (pendingStreamInfAttr != null) {
                    if (!line.startsWith("#")) {
                        val variantUri = resolveUri(resolvedUri, line)
                        val attrMap = pendingStreamInfAttr
                        pendingStreamInfAttr = null

                        val bandwidth = attrMap["BANDWIDTH"]?.toLongOrNull() ?: 0L
                        val averageBandwidth = attrMap["AVERAGE-BANDWIDTH"]?.toLongOrNull() ?: bandwidth
                        val resolution = attrMap["RESOLUTION"] ?: ""
                        val (width, height) = parseResolution(resolution)
                        val codecs = attrMap["CODECS"] ?: ""
                        val frameRate = attrMap["FRAME-RATE"]?.toDoubleOrNull()
                        val name = attrMap["NAME"] ?: ""
                        val audio = attrMap["AUDIO"] ?: ""
                        val video = attrMap["VIDEO"] ?: ""
                        val subtitles = attrMap["SUBTITLES"] ?: ""
                        val closedCaptions = attrMap["CLOSED-CAPTIONS"] ?: ""

                        val codecFlags = detectCodecFamilies(codecs)

                        variants.add(
                            mapOf(
                                "index" to variants.size,
                                "uri" to variantUri,
                                "rawUri" to line,
                                "bandwidth" to bandwidth,
                                "averageBandwidth" to averageBandwidth,
                                "resolution" to resolution,
                                "width" to width,
                                "height" to height,
                                "codecs" to codecs,
                                "frameRate" to (frameRate ?: 0.0),
                                "name" to name,
                                "audioGroup" to audio,
                                "videoGroup" to video,
                                "subtitlesGroup" to subtitles,
                                "closedCaptions" to closedCaptions,
                                "hasAvc" to codecFlags.hasAvc,
                                "hasHevc" to codecFlags.hasHevc,
                                "hasAv1" to codecFlags.hasAv1,
                                "detectedFamilies" to codecFlags.detectedFamilies,
                            )
                        )
                    }
                }
            }

            val isMediaPlaylist = variants.isEmpty() && (hasExtInf || hasTargetDuration)
            val variantCount = variants.size
            val hasAdaptiveLadder = variantCount > 1

            val hasAvc = variants.any { it["hasAvc"] == true }
            val hasHevc = variants.any { it["hasHevc"] == true }
            val hasAv1 = variants.any { it["hasAv1"] == true }

            val serverPolicyPass = (!hasHevc && !hasAv1) || hasAvc
            val isLlHls = hasExtXPart || hasExtXServerControl || hasExtXPreloadHint || hasExtXPartInf

            val rawStatus = "status=OK;format=HLS;variantCount=$variantCount;hasAdaptiveLadder=$hasAdaptiveLadder;" +
                "hasAvc=$hasAvc;hasHevc=$hasHevc;hasAv1=$hasAv1;serverPolicyPass=$serverPolicyPass;" +
                "isLlHls=$isLlHls;isMediaPlaylist=$isMediaPlaylist"

            mapOf(
                "format" to "HLS",
                "uri" to originalUri.ifEmpty { resolvedUri },
                "resolvedUri" to resolvedUri,
                "fetchSuccess" to true,
                "parseSuccess" to true,
                "isMediaPlaylist" to isMediaPlaylist,
                "variantCount" to variantCount,
                "representationCount" to variantCount,
                "hasAdaptiveLadder" to hasAdaptiveLadder,
                "hasAvc" to hasAvc,
                "hasHevc" to hasHevc,
                "hasAv1" to hasAv1,
                "serverPolicyPass" to serverPolicyPass,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "llHlsIndicators" to mapOf(
                    "hasExtXPart" to hasExtXPart,
                    "hasExtXServerControl" to hasExtXServerControl,
                    "hasExtXPreloadHint" to hasExtXPreloadHint,
                    "hasExtXPartInf" to hasExtXPartInf,
                    "isLlHls" to isLlHls,
                ),
                "variants" to variants,
                "representations" to variants,
                "raw" to rawStatus,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Failed parsing HLS manifest: ${t.message}")
            mapOf(
                "format" to "HLS",
                "uri" to originalUri.ifEmpty { resolvedUri },
                "resolvedUri" to resolvedUri,
                "fetchSuccess" to true,
                "parseSuccess" to false,
                "isMediaPlaylist" to false,
                "variantCount" to 0,
                "representationCount" to 0,
                "hasAdaptiveLadder" to false,
                "hasAvc" to false,
                "hasHevc" to false,
                "hasAv1" to false,
                "serverPolicyPass" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "variants" to emptyList<Map<String, Any?>>(),
                "representations" to emptyList<Map<String, Any?>>(),
                "raw" to "status=FAIL;reason=hls_parse_exception:${t.javaClass.simpleName}:${t.message}",
            )
        }
    }

    /**
     * Inspects DASH MPD XML manifest using secure standard DOM parser with external entities disabled.
     */
    fun inspectDashManifest(
        manifestXml: String,
        resolvedUri: String = "",
        originalUri: String = "",
    ): Map<String, Any?> {
        return try {
            val factory = DocumentBuilderFactory.newInstance().apply {
                isNamespaceAware = true
                try {
                    setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
                    setFeature("http://xml.org/sax/features/external-general-entities", false)
                    setFeature("http://xml.org/sax/features/external-parameter-entities", false)
                    setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
                    isXIncludeAware = false
                    isExpandEntityReferences = false
                } catch (e: Throwable) {
                    Log.d(TAG, "Secure XML feature setup note: ${e.message}")
                }
            }

            val builder = factory.newDocumentBuilder()
            val doc = builder.parse(manifestXml.byteInputStream(StandardCharsets.UTF_8))
            doc.documentElement.normalize()

            val videoRepresentations = mutableListOf<Map<String, Any?>>()
            val adaptationSetNodes = doc.getElementsByTagName("AdaptationSet")

            for (i in 0 until adaptationSetNodes.length) {
                val asNode = adaptationSetNodes.item(i)
                if (asNode.nodeType != Node.ELEMENT_NODE) continue
                val asElement = asNode as Element

                val asId = asElement.getAttribute("id")
                val asContentType = asElement.getAttribute("contentType")
                val asMimeType = asElement.getAttribute("mimeType")
                val asCodecs = asElement.getAttribute("codecs")
                val asWidth = asElement.getAttribute("width").ifEmpty { asElement.getAttribute("maxWidth") }
                val asHeight = asElement.getAttribute("height").ifEmpty { asElement.getAttribute("maxHeight") }
                val asFrameRate = asElement.getAttribute("frameRate")

                val repNodes = asElement.getElementsByTagName("Representation")
                for (j in 0 until repNodes.length) {
                    val repNode = repNodes.item(j)
                    if (repNode.nodeType != Node.ELEMENT_NODE) continue
                    val repElement = repNode as Element

                    val repId = repElement.getAttribute("id")
                    val repBandwidth = repElement.getAttribute("bandwidth").toLongOrNull() ?: 0L
                    val repWidth = (repElement.getAttribute("width").toIntOrNull()
                        ?: asWidth.toIntOrNull() ?: 0)
                    val repHeight = (repElement.getAttribute("height").toIntOrNull()
                        ?: asHeight.toIntOrNull() ?: 0)
                    val repCodecs = repElement.getAttribute("codecs").ifEmpty { asCodecs }
                    val repMimeType = repElement.getAttribute("mimeType").ifEmpty { asMimeType }
                    val repFrameRate = repElement.getAttribute("frameRate").ifEmpty { asFrameRate }

                    val isVideo = asContentType.equals("video", ignoreCase = true) ||
                        asMimeType.startsWith("video/", ignoreCase = true) ||
                        repMimeType.startsWith("video/", ignoreCase = true) ||
                        (repWidth > 0 && repHeight > 0)

                    if (isVideo) {
                        val codecFlags = detectCodecFamilies(repCodecs)
                        videoRepresentations.add(
                            mapOf(
                                "index" to videoRepresentations.size,
                                "id" to repId,
                                "adaptationSetId" to asId,
                                "bandwidth" to repBandwidth,
                                "width" to repWidth,
                                "height" to repHeight,
                                "codecs" to repCodecs,
                                "mimeType" to repMimeType,
                                "frameRate" to repFrameRate,
                                "hasAvc" to codecFlags.hasAvc,
                                "hasHevc" to codecFlags.hasHevc,
                                "hasAv1" to codecFlags.hasAv1,
                                "detectedFamilies" to codecFlags.detectedFamilies,
                            )
                        )
                    }
                }
            }

            val repCount = videoRepresentations.size
            val hasAdaptiveLadder = repCount > 1

            val hasAvc = videoRepresentations.any { it["hasAvc"] == true }
            val hasHevc = videoRepresentations.any { it["hasHevc"] == true }
            val hasAv1 = videoRepresentations.any { it["hasAv1"] == true }

            val serverPolicyPass = (!hasHevc && !hasAv1) || hasAvc

            val rawStatus = "status=OK;format=DASH;representationCount=$repCount;hasAdaptiveLadder=$hasAdaptiveLadder;" +
                "hasAvc=$hasAvc;hasHevc=$hasHevc;hasAv1=$hasAv1;serverPolicyPass=$serverPolicyPass"

            mapOf(
                "format" to "DASH",
                "uri" to originalUri.ifEmpty { resolvedUri },
                "resolvedUri" to resolvedUri,
                "fetchSuccess" to true,
                "parseSuccess" to true,
                "isMediaPlaylist" to false,
                "variantCount" to repCount,
                "representationCount" to repCount,
                "hasAdaptiveLadder" to hasAdaptiveLadder,
                "hasAvc" to hasAvc,
                "hasHevc" to hasHevc,
                "hasAv1" to hasAv1,
                "serverPolicyPass" to serverPolicyPass,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "representations" to videoRepresentations,
                "variants" to videoRepresentations,
                "raw" to rawStatus,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Failed parsing DASH manifest: ${t.message}")
            mapOf(
                "format" to "DASH",
                "uri" to originalUri.ifEmpty { resolvedUri },
                "resolvedUri" to resolvedUri,
                "fetchSuccess" to true,
                "parseSuccess" to false,
                "isMediaPlaylist" to false,
                "variantCount" to 0,
                "representationCount" to 0,
                "hasAdaptiveLadder" to false,
                "hasAvc" to false,
                "hasHevc" to false,
                "hasAv1" to false,
                "serverPolicyPass" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "representations" to emptyList<Map<String, Any?>>(),
                "variants" to emptyList<Map<String, Any?>>(),
                "raw" to "status=FAIL;reason=dash_parse_exception:${t.javaClass.simpleName}:${t.message}",
            )
        }
    }

    /**
     * Parses HLS comma-separated attribute list with support for quoted strings.
     */
    fun parseHlsAttributeList(attrString: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        var i = 0
        val len = attrString.length
        while (i < len) {
            while (i < len && (attrString[i] == ' ' || attrString[i] == ',' || attrString[i] == '\t' || attrString[i] == '\r' || attrString[i] == '\n')) {
                i++
            }
            if (i >= len) break

            val eqIndex = attrString.indexOf('=', i)
            if (eqIndex == -1) break

            val key = attrString.substring(i, eqIndex).trim()
            i = eqIndex + 1
            if (i >= len) break

            val value: String
            if (attrString[i] == '"') {
                i++ // skip opening quote
                val endQuote = attrString.indexOf('"', i)
                if (endQuote == -1) {
                    value = attrString.substring(i)
                    i = len
                } else {
                    value = attrString.substring(i, endQuote)
                    i = endQuote + 1
                }
            } else {
                val commaIndex = attrString.indexOf(',', i)
                if (commaIndex == -1) {
                    value = attrString.substring(i).trim()
                    i = len
                } else {
                    value = attrString.substring(i, commaIndex).trim()
                    i = commaIndex + 1
                }
            }
            result[key] = value
        }
        return result
    }

    /**
     * Detects codec families (AVC, HEVC, AV1, VP9, Opus, AAC) from a codecs string.
     */
    fun detectCodecFamilies(codecsString: String?): CodecFamilyFlags {
        if (codecsString.isNullOrBlank()) {
            return CodecFamilyFlags(
                hasAvc = false,
                hasHevc = false,
                hasAv1 = false,
                detectedFamilies = emptyList(),
            )
        }
        val codecsList = codecsString.split(",").map { it.trim().lowercase() }
        var hasAvc = false
        var hasHevc = false
        var hasAv1 = false
        val detected = mutableListOf<String>()

        for (c in codecsList) {
            when {
                c.startsWith("avc1") || c.startsWith("avc3") -> {
                    hasAvc = true
                    if ("avc" !in detected) detected.add("avc")
                }
                c.startsWith("hvc1") || c.startsWith("hev1") -> {
                    hasHevc = true
                    if ("hevc" !in detected) detected.add("hevc")
                }
                c.startsWith("av01") -> {
                    hasAv1 = true
                    if ("av1" !in detected) detected.add("av1")
                }
                c.startsWith("vp09") || c.startsWith("vp9") -> {
                    if ("vp9" !in detected) detected.add("vp9")
                }
                c.startsWith("mp4a") || c.startsWith("aac") -> {
                    if ("aac" !in detected) detected.add("aac")
                }
                c.startsWith("opus") -> {
                    if ("opus" !in detected) detected.add("opus")
                }
            }
        }
        return CodecFamilyFlags(
            hasAvc = hasAvc,
            hasHevc = hasHevc,
            hasAv1 = hasAv1,
            detectedFamilies = detected,
        )
    }

    private fun parseResolution(resolutionStr: String): Pair<Int, Int> {
        if (resolutionStr.isBlank()) return Pair(0, 0)
        val parts = resolutionStr.split("x", "X")
        val w = parts.getOrNull(0)?.trim()?.toIntOrNull() ?: 0
        val h = parts.getOrNull(1)?.trim()?.toIntOrNull() ?: 0
        return Pair(w, h)
    }

    private fun resolveUri(baseUri: String, relativeOrAbsolute: String): String {
        return try {
            if (baseUri.isBlank()) relativeOrAbsolute
            else URL(URL(baseUri), relativeOrAbsolute).toString()
        } catch (_: Throwable) {
            relativeOrAbsolute
        }
    }

    private fun determineFormat(
        uri: String,
        manifestText: String,
        formatHint: String?,
    ): AdaptiveStreamFormat {
        val hintUpper = formatHint?.trim()?.uppercase()
        if (hintUpper == "HLS") return AdaptiveStreamFormat.HLS
        if (hintUpper == "DASH") return AdaptiveStreamFormat.DASH

        val lowerUri = uri.lowercase()
        if (lowerUri.contains(".m3u8")) return AdaptiveStreamFormat.HLS
        if (lowerUri.contains(".mpd")) return AdaptiveStreamFormat.DASH

        val trimmed = manifestText.trimStart()
        if (trimmed.startsWith("#EXTM3U")) return AdaptiveStreamFormat.HLS
        if (trimmed.startsWith("<MPD", ignoreCase = true) || trimmed.startsWith("<?xml", ignoreCase = true)) {
            return AdaptiveStreamFormat.DASH
        }
        return AdaptiveStreamFormat.HLS
    }

    private fun fetchText(
        urlStr: String,
        headers: Map<String, String>?,
        maxRedirects: Int = MAX_REDIRECTS,
    ): Pair<String, String> {
        var currentUrl = urlStr
        var redirects = 0
        while (redirects <= maxRedirects) {
            if (isMediaSegmentUri(currentUrl)) {
                throw IOException("media_segment_uri_rejected: $currentUrl")
            }
            val url = URL(currentUrl)
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("User-Agent", "Vanguard-Manifest-Inspector/1.0")
            headers?.forEach { (k, v) -> conn.setRequestProperty(k, v) }

            try {
                conn.connect()
                val status = conn.responseCode
                if (status in 300..399) {
                    val location = conn.getHeaderField("Location")
                        ?: throw IOException("Redirect status $status without Location header")
                    currentUrl = resolveUri(currentUrl, location)
                    redirects++
                    continue
                }
                if (status !in 200..299) {
                    throw IOException("HTTP request failed with status $status: ${conn.responseMessage}")
                }
                val (text, finalUrl) = BufferedReader(InputStreamReader(conn.inputStream, StandardCharsets.UTF_8)).use { reader ->
                    val sb = StringBuilder()
                    val charBuf = CharArray(4096)
                    var totalChars = 0
                    var read: Int
                    while (reader.read(charBuf).also { read = it } != -1) {
                        totalChars += read
                        if (totalChars > MAX_MANIFEST_CHARS) {
                            throw IOException("manifest_exceeds_max_chars")
                        }
                        sb.append(charBuf, 0, read)
                    }
                    Pair(sb.toString(), currentUrl)
                }
                return Pair(text, finalUrl)
            } finally {
                conn.disconnect()
            }
        }
        throw IOException("Too many redirects: $redirects")
    }
}
