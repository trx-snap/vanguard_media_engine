// VGDuetCameraSource.swift
// VG-DUET-CAMERA-INGRESS: compatibility alias.
//
// The front-camera live preview ingress implementation now lives in
// VGLiveGreenScreenCameraSource.swift as a neutral, caller-agnostic camera source: it is
// the real runtime camera ingress for the standalone Live GreenScreen adapter-path
// fallback (VGLiveGreenScreenSessionCoordinator.startCameraPipeline), not for Duet —
// the production Duet foreground path runs a graph-backed provider
// (VGDuetGraphGreenScreenForegroundProvider in VGDuetGreenScreenAdapter.swift) instead.
// This alias exists only so any caller still spelling the historical Duet-scoped name
// keeps compiling; it carries no logic of its own.
typealias VGDuetCameraSource = VGLiveGreenScreenCameraSource
