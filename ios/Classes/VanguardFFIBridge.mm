// VanguardFFIBridge.mm
//
// This file exists solely to compile the shared C++ core (../src/)
// into the vanguard_media_engine iOS pod so that the FFI symbols
// (vanguard_engine_create, etc.) are statically linked into Runner.app.
//
// This is the standard Flutter FFI plugin pattern — the forwarder file
// approach is used because CocoaPods does not reliably resolve `../` paths
// in s.source_files.
//
// IMPORTANT: Do NOT add any logic here. The actual implementation lives in
// ../../src/vanguard_media_engine.cpp.

#include "../../src/vanguard_media_engine.cpp"
