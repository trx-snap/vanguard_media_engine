// VGDuetPreviewRenderLoop.swift
// VG-DUET-SLICE-4B-B: Display-link driven render loop for the Duet preview texture.
//
// Responsibilities:
//   - Owns a CADisplayLink (via weak proxy) while the session is actively
//     recording; the link is invalidated before every hold / stop.
//   - Each main-thread tick reads the target source PTS from an injected
//     closure, clamps it to the trim window, and requests at most ONE decode
//     step at a time through the injected decode handler.  Ticks that arrive
//     while a step is in flight are coalesced into a single pending job.
//   - Decoded frames are composited on a private serial render queue and
//     presented on the main thread through the injected present handler.
//   - Held states (initial / paused / seeked) decode one frame and stay
//     passive until asked again.  While actively recording, the loop never
//     goes quiet: once the clamped source target stops changing (e.g. at
//     trimEnd), each tick redraws the held source frame instead of
//     re-decoding, so live foreground (camera / green-screen) samples keep
//     presenting fresh over the held source -- matching Android's continued
//     live-foreground-over-held-source behavior.  It never mutates session
//     state and never loops, seeks, or re-decodes source video once the held
//     frame already covers the target.
//
// Foreground seam (Phase 4A / 4B-A):
//   - foregroundSampleProvider returns ONE retained VGDuetForegroundSample per render
//     pass: the live foreground frame plus an optional matte, each +1, and the
//     provider's `compositeMode`.
//   - Keying is derived from `sample.compositeMode`, never from the layout mode and
//     never from raw matte presence:
//       nil sample     -> no camera frame; the compositor draws its placeholder.
//       .opaque        -> frame is the opaque camera overlay; the matte is not used.
//       .matteKeyed    -> the purified Duet compositor no longer accepts a raw mask
//                         (mask blending now lives in VGLiveGreenScreenCompositor), so
//                         this fails open to the same opaque overlay as `.opaque`; any
//                         matte the sample carries is released, never composited.
//       .straightAlpha -> frame is a pre-keyed straight-alpha foreground composited
//                         source-over; the matte is not used and no refinement runs.
//     Layout mode only drives the rects the coordinator hands to updateLayout.
//   - Each render() call takes the sample on main before crossing the queue boundary,
//     hands frame/matte/mode to the compositor, and releases the sample exactly once
//     after compositing, regardless of mode or which compositor path was taken.
//   - This loop is provider-agnostic: it only consumes whatever sample the injected
//     foregroundSampleProvider hands it.  The current iOS Duet production provider
//     (VGDuetGraphGreenScreenForegroundProvider) is graph-backed and emits
//     straight-alpha samples for GreenScreen.
//
// Explicitly NOT here: Flutter imports, session state, decoder ownership,
// CoreImage drawing (see VGDuetPreviewCompositor).
//
// Threading:
//   - All public methods and displayLinkFired run on the main thread.
//   - Decoder work happens wherever the injected decode handler runs it
//     (the coordinator's decoderQueue); its completion may fire on any thread
//     and is hopped back to main before touching loop state.
//   - Compositing runs on renderQueue; the compositor is immutable after init.

import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

// MARK: - Decode seam types

/// A single decoder request issued by the loop.  `step` advances to the first
/// frame at/after the target (the decoder seeks internally when moving
/// backwards); `seek` forces a reader reposition at the target.
enum VGDuetPreviewDecodeRequest {
    case step(targetPtsMs: Int)
    case seek(targetPtsMs: Int)

    var targetPtsMs: Int {
        switch self {
        case .step(let t), .seek(let t): return t
        }
    }

    var isSeek: Bool {
        if case .seek = self { return true }
        return false
    }
}

/// Result of a decode request.  `presentationTimeMs` is the decoder's last
/// decoded PTS so the loop can avoid redundant re-decodes of a held frame.
struct VGDuetPreviewDecodedFrame {
    let pixelBuffer: CVPixelBuffer?
    let presentationTimeMs: Int
}

// MARK: - CADisplayLink weak proxy

/// CADisplayLink retains its target.  The proxy holds the loop weakly so the
/// link can never keep a stopped loop (and its captured closures) alive.
private final class VGDuetDisplayLinkProxy: NSObject {
    weak var loop: VGDuetPreviewRenderLoop?

    init(loop: VGDuetPreviewRenderLoop) {
        self.loop = loop
    }

    @objc func displayLinkFired(_ sender: CADisplayLink) {
        loop?.displayLinkFired(sender)
    }
}

// MARK: - Render loop

final class VGDuetPreviewRenderLoop {

    // MARK: Injected seams

    typealias TargetPtsProvider = () -> Int
    typealias DecodeCompletion  = (VGDuetPreviewDecodedFrame?) -> Void
    typealias DecodeHandler     = (VGDuetPreviewDecodeRequest, @escaping DecodeCompletion) -> Void
    typealias PresentHandler    = (CVPixelBuffer) -> Void

    /// Returns one *retained* foreground sample (live foreground frame + optional
    /// matte, each +1, plus the provider's `compositeMode`), or nil when no camera
    /// frame has arrived yet.  The render loop calls `release()` on it exactly once
    /// after compositing.  May be called from the main thread or the render queue.
    typealias ForegroundSampleProvider = () -> VGDuetForegroundSample?

    private let compositor: VGDuetPreviewCompositor
    private let trimStartMs: Int
    private let trimEndMs: Int
    private let targetPtsProvider: TargetPtsProvider
    private let decodeHandler: DecodeHandler
    private let presentHandler: PresentHandler
    /// Optional foreground sample provider injected by the coordinator.  nil means
    /// no live foreground: the compositor draws its camera placeholder.
    private let foregroundSampleProvider: ForegroundSampleProvider?

    private let renderQueue = DispatchQueue(label: "com.connects.vanguard.duet.preview.render",
                                            qos: .userInteractive)

    // MARK: Main-thread state

    private enum Job {
        /// Decode at the request target, then composite + present if the frame
        /// (or layout, when forceRender) changed.
        case decode(VGDuetPreviewDecodeRequest, forceRender: Bool)
        /// Composite + present the held frame with the current layout rects,
        /// never touching the decoder. Used both for layout-only redraws and
        /// for active-recording ticks whose clamped target has not moved (see
        /// displayLinkFired), so a fresh live foreground sample still reaches
        /// the compositor every tick even while the source frame stays held.
        case redraw
    }

    private var sourceRect: CGRect
    private var cameraRect: CGRect
    /// Preview-only foreground rotation metadata (degrees + normalized pivot
    /// anchor, Dart/top-left space). Updated alongside `cameraRect` in
    /// `updateLayout`; passed to the compositor on every render.
    private var rotationDegrees: CGFloat
    private var anchorX: CGFloat
    private var anchorY: CGFloat

    private var isStopped = false
    private var isActive  = false
    private var displayLink: CADisplayLink?

    /// True from the moment a decode or render is dispatched until its result
    /// has been presented (or dropped) on main.  Guarantees one pipeline in flight.
    private var inFlight = false
    private var pendingJob: Job?

    /// Last frame returned by the decoder; reused for layout-only redraws.
    private var heldSourceFrame: CVPixelBuffer?
    /// Source PTS range (ms) for which `heldSourceFrame` is the correct
    /// "first frame at/after target" answer.  nil until the first decode lands.
    private var coveredRange: ClosedRange<Int>?
    private var hasPresented = false
    /// Last clamped target handed to the decode path from a display tick.
    private var lastTickTargetPtsMs: Int?

    // MARK: - Telemetry (main-thread confined)
    private var displayTickCount: Int = 0
    private var decodeRequestCount: Int = 0
    private var decodedFrameCount: Int = 0
    private var renderPassCount: Int = 0
    private var presentedFrameCount: Int = 0
    private var redrawRequestCount: Int = 0

    private var firstDecodedSourcePtsMs: Int?
    private var lastDecodedSourcePtsMs: Int?
    private var minDecodedSourcePtsMs: Int?
    private var maxDecodedSourcePtsMs: Int?
    private var distinctDecodedSourcePtsCount: Int = 0
    private var lastDistinctPtsMs: Int?

    // MARK: - Init

    init(compositor: VGDuetPreviewCompositor,
         trimStartMs: Int,
         trimEndMs: Int,
         sourceRect: CGRect,
         cameraRect: CGRect,
         rotationDegrees: CGFloat = 0.0,
         anchorX: CGFloat = 0.5,
         anchorY: CGFloat = 0.5,
         targetPtsProvider: @escaping TargetPtsProvider,
         decodeHandler: @escaping DecodeHandler,
         presentHandler: @escaping PresentHandler,
         foregroundSampleProvider: ForegroundSampleProvider? = nil) {
        self.compositor               = compositor
        self.trimStartMs              = trimStartMs
        self.trimEndMs                = max(trimStartMs, trimEndMs)
        self.sourceRect               = sourceRect
        self.cameraRect               = cameraRect
        self.rotationDegrees          = rotationDegrees
        self.anchorX                  = anchorX
        self.anchorY                  = anchorY
        self.targetPtsProvider        = targetPtsProvider
        self.decodeHandler            = decodeHandler
        self.presentHandler           = presentHandler
        self.foregroundSampleProvider = foregroundSampleProvider
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Public API (main thread)

    /// Decodes and presents the frame at the current target PTS (trimStart on
    /// a fresh session, the held cursor otherwise).  Does not start the link.
    func renderInitialFrame() {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        let target = clamp(targetPtsProvider())
        submit(.decode(.step(targetPtsMs: target), forceRender: true))
    }

    /// Starts the display link.  Idempotent while already active.
    func startActive() {
        assert(Thread.isMainThread)
        guard !isStopped, !isActive else { return }
        isActive = true
        lastTickTargetPtsMs = nil
        installDisplayLink()
    }

    /// Stops the display link and holds the frame at/after `targetPtsMs`.
    func pauseAndHold(targetPtsMs: Int) {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        isActive = false
        tearDownDisplayLink()
        submit(.decode(.step(targetPtsMs: clamp(targetPtsMs)), forceRender: false))
    }

    /// Stops the display link, repositions the decoder at `targetPtsMs` and
    /// holds that frame.
    func seekAndHold(targetPtsMs: Int) {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        isActive = false
        tearDownDisplayLink()
        submit(.decode(.seek(targetPtsMs: clamp(targetPtsMs)), forceRender: false))
    }

    /// Applies new layout rects (plus preview-only foreground rotation metadata)
    /// and redraws the held/current frame.  While active, subsequent ticks pick
    /// up the new rects/rotation automatically.  Keying is not a layout property
    /// here: it follows the provider's next sample.
    func updateLayout(sourceRect: CGRect,
                      cameraRect: CGRect,
                      rotationDegrees: CGFloat = 0.0,
                      anchorX: CGFloat = 0.5,
                      anchorY: CGFloat = 0.5,
                      targetPtsMs: Int) {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        self.sourceRect      = sourceRect
        self.cameraRect      = cameraRect
        self.rotationDegrees = rotationDegrees
        self.anchorX         = anchorX
        self.anchorY         = anchorY
        submit(.decode(.step(targetPtsMs: clamp(targetPtsMs)), forceRender: true))
    }

    /// Terminal.  Invalidates the display link, drops pending work and the
    /// held frame.  Every later call (and every in-flight completion) is a no-op.
    func stop() {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        isStopped = true
        isActive  = false
        tearDownDisplayLink()
        pendingJob      = nil
        heldSourceFrame = nil
        coveredRange    = nil
    }

    /// Main-thread read-only telemetry snapshot.
    func diagnosticsSnapshot() -> [String: Any] {
        assert(Thread.isMainThread)
        var snapshot: [String: Any] = [
            "displayTickCount": displayTickCount,
            "decodeRequestCount": decodeRequestCount,
            "decodedFrameCount": decodedFrameCount,
            "renderPassCount": renderPassCount,
            "presentedFrameCount": presentedFrameCount,
            "redrawRequestCount": redrawRequestCount,
            "distinctDecodedSourcePtsCount": distinctDecodedSourcePtsCount,
            "isActive": isActive,
            "isStopped": isStopped,
            "hasPresented": hasPresented,
            "trimStartMs": trimStartMs,
            "trimEndMs": trimEndMs,
        ]
        if let first = firstDecodedSourcePtsMs {
            snapshot["firstDecodedSourcePtsMs"] = first
        }
        if let last = lastDecodedSourcePtsMs {
            snapshot["lastDecodedSourcePtsMs"] = last
        }
        if let minPts = minDecodedSourcePtsMs {
            snapshot["minDecodedSourcePtsMs"] = minPts
        }
        if let maxPts = maxDecodedSourcePtsMs {
            snapshot["maxDecodedSourcePtsMs"] = maxPts
        }
        if let minPts = minDecodedSourcePtsMs, let maxPts = maxDecodedSourcePtsMs {
            snapshot["sourcePtsSpanMs"] = maxPts - minPts
        }
        return snapshot
    }

    // MARK: - Display link

    private func installDisplayLink() {
        if let existing = displayLink {
            existing.isPaused = false
            return
        }
        let proxy = VGDuetDisplayLinkProxy(loop: self)
        let link = CADisplayLink(target: proxy,
                                 selector: #selector(VGDuetDisplayLinkProxy.displayLinkFired(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
        } else {
            link.preferredFramesPerSecond = 60
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func displayLinkFired(_ sender: CADisplayLink) {
        guard !isStopped, isActive else { return }
        displayTickCount += 1
        let target = clamp(targetPtsProvider())
        guard target != lastTickTargetPtsMs else {
            // Source PTS target has not moved (e.g. the clock has clamped at
            // trimEnd). The source/background frame stays held exactly as-is --
            // this never decodes, seeks, or otherwise touches the decoder for an
            // unchanged target -- but an active recording must keep presenting
            // fresh live foreground (camera / green-screen) samples over that
            // held frame every tick, matching Android's continued live rendering
            // once its source hold begins. Submitting .redraw (never .decode)
            // routes straight to render(frame:), which re-samples
            // foregroundSampleProvider on every call.
            submit(.redraw)
            return
        }
        lastTickTargetPtsMs = target
        submit(.decode(.step(targetPtsMs: target), forceRender: false))
    }

    // MARK: - Job pipeline (main thread)

    private func submit(_ job: Job) {
        guard !isStopped else { return }
        if inFlight {
            pendingJob = VGDuetPreviewRenderLoop.merge(pendingJob, job)
            return
        }
        run(job)
    }

    private func run(_ job: Job) {
        switch job {
        case .redraw:
            redrawRequestCount += 1
            render(frame: heldSourceFrame)

        case .decode(let request, let forceRender):
            let target = request.targetPtsMs
            if let covered = coveredRange, covered.contains(target), heldSourceFrame != nil {
                // Held frame already answers this target; skip the decoder.
                if forceRender { render(frame: heldSourceFrame) }
                return
            }
            decode(request, forceRender: forceRender)
        }
    }

    private func decode(_ request: VGDuetPreviewDecodeRequest, forceRender: Bool) {
        decodeRequestCount += 1
        inFlight = true
        decodeHandler(request) { [weak self] decoded in
            DispatchQueue.main.async {
                self?.didDecode(request, decoded, forceRender: forceRender)
            }
        }
    }

    private func didDecode(_ request: VGDuetPreviewDecodeRequest,
                           _ decoded: VGDuetPreviewDecodedFrame?,
                           forceRender: Bool) {
        guard !isStopped else { return }

        let target = request.targetPtsMs
        var changed = forceRender

        if let decoded = decoded, let buffer = decoded.pixelBuffer {
            decodedFrameCount += 1
            let pts = decoded.presentationTimeMs
            if firstDecodedSourcePtsMs == nil {
                firstDecodedSourcePtsMs = pts
            }
            lastDecodedSourcePtsMs = pts
            if let currentMin = minDecodedSourcePtsMs {
                minDecodedSourcePtsMs = min(currentMin, pts)
            } else {
                minDecodedSourcePtsMs = pts
            }
            if let currentMax = maxDecodedSourcePtsMs {
                maxDecodedSourcePtsMs = max(currentMax, pts)
            } else {
                maxDecodedSourcePtsMs = pts
            }
            if lastDistinctPtsMs != pts {
                distinctDecodedSourcePtsCount += 1
                lastDistinctPtsMs = pts
            }

            if buffer !== heldSourceFrame { changed = true }
            heldSourceFrame = buffer
            coveredRange = min(target, pts)...max(target, pts)
        } else {
            // Decoder unavailable or produced nothing: keep whatever we hold and
            // remember the target so we do not spin on it.
            coveredRange = target...target
        }

        if changed || !hasPresented {
            render(frame: heldSourceFrame)
        } else {
            finish()
        }
    }

    private func render(frame: CVPixelBuffer?) {
        renderPassCount += 1
        inFlight = true
        let sRect       = sourceRect
        let cRect       = cameraRect
        let rotationDeg = rotationDegrees
        let anchorXVal  = anchorX
        let anchorYVal  = anchorY
        let compositor  = self.compositor
        // Take ONE foreground sample *before* crossing the queue boundary.  Frame and
        // matte are each +1; the sample is released exactly once after compositing,
        // whatever its compositeMode.
        let sample: VGDuetForegroundSample? = foregroundSampleProvider?()
        let cameraBuffer: CVPixelBuffer? = sample.map { $0.frame.takeUnretainedValue() }
        // Keying follows `sample.compositeMode`, never the layout mode and never raw
        // matte presence.  The purified Duet compositor accepts no raw mask, so
        // `.matteKeyed` fails open to the same opaque path as `.opaque`.
        var usesStraightAlpha = false
        if let sample = sample {
            switch sample.compositeMode {
            case .opaque, .matteKeyed:
                // Opaque camera overlay.  Any matte the sample carries is released
                // below, never composited.
                break
            case .straightAlpha:
                // Pre-keyed foreground: the frame already carries straight alpha.  No
                // matte is passed and no mask refinement runs in the compositor.
                usesStraightAlpha = true
            }
        }
        renderQueue.async { [weak self] in
            let output = compositor.composite(sourceFrame: frame,
                                              sourceRect: sRect,
                                              cameraRect: cRect,
                                              cameraFrame: cameraBuffer,
                                              cameraFrameUsesStraightAlpha: usesStraightAlpha,
                                              cameraRotationDegrees: rotationDeg,
                                              cameraAnchorX: anchorXVal,
                                              cameraAnchorY: anchorYVal)
            // Release the retained sample now that compositing is done (all modes).
            sample?.release()
            DispatchQueue.main.async {
                self?.didRender(output)
            }
        }
    }

    private func didRender(_ output: CVPixelBuffer?) {
        guard !isStopped else { return }
        if let output = output {
            presentedFrameCount += 1
            presentHandler(output)
            hasPresented = true
        }
        finish()
    }

    private func finish() {
        inFlight = false
        guard !isStopped, let next = pendingJob else { return }
        pendingJob = nil
        run(next)
    }

    /// Coalesces a newly submitted job into the single pending slot.
    /// Rules: seek beats step; any redraw request survives as forceRender;
    /// otherwise the newest request wins.
    private static func merge(_ pending: Job?, _ incoming: Job) -> Job {
        guard let pending = pending else { return incoming }
        switch (pending, incoming) {
        case (.redraw, .redraw):
            return .redraw
        case (.redraw, .decode(let request, _)):
            return .decode(request, forceRender: true)
        case (.decode(let request, _), .redraw):
            return .decode(request, forceRender: true)
        case (.decode(let oldRequest, let oldForce), .decode(let newRequest, let newForce)):
            let force = oldForce || newForce
            if oldRequest.isSeek && !newRequest.isSeek {
                return .decode(oldRequest, forceRender: force)
            }
            return .decode(newRequest, forceRender: force)
        }
    }

    // MARK: - Helpers

    private func clamp(_ ptsMs: Int) -> Int {
        return max(trimStartMs, min(trimEndMs, ptsMs))
    }
}
