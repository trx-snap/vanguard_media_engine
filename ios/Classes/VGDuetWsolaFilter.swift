// VGDuetWsolaFilter.swift
//
// Intentionally empty. The GSD-08 `VGDuetWsolaFilter` (mono Float32 WSOLA time-stretcher used
// by `VGDuetMicrophoneCapture`) is implemented as a file-private type inside
// `VGDuetNativeSessionCoordinator.swift`. It was inlined there because the existing example
// Pods project compiled-source list does not include this file, and mutating the Pods project
// (pod install) is out of scope. Keeping this file comment-only means it is harmless whether or
// not a future Pods regeneration picks it up. Do not add a duplicate `VGDuetWsolaFilter` here.
