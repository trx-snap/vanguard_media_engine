// VGDuetExportTransformPixelProofDiagnostics.swift
//
// This file intentionally declares no symbols.
//
// The `VGDuetExportTransformPixelProofDiagnostics` class actually lives in
// `VGDuetMethodHandler.swift` (see its "Export foreground-transform rotation
// pixel-proof diagnostics" section, below `VGDuetMethodHandler` itself), for
// current iOS project-membership safety: this standalone file was not picked
// up by the existing Xcode/Pods project state, causing a
// "Cannot find 'VGDuetExportTransformPixelProofDiagnostics' in scope" build
// failure at VGDuetMethodHandler.swift's `exportTransformPixelProofDiagnostics`
// property. `VGGreenScreenExportPixelProofDiagnostics` (see
// VGGreenScreenExportMethodHandler.swift) follows the same pattern for the
// same reason.
//
// If this file is later added to the Xcode project's compiled sources (e.g.
// after a project/Pods regeneration), do NOT restore a duplicate
// `VGDuetExportTransformPixelProofDiagnostics` class definition here without
// first removing it from VGDuetMethodHandler.swift -- both files compiling
// the same type name into the same module would be a redeclaration error.
