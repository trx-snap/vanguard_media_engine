// hardware_buffer_import.h
// Phase 2C: AHardwareBuffer import foundation - public shared opaque types.
//
// Frozen API contract:
//   - ASCII-only, C++17.
//   - No Android, Vulkan, JNI, dlfcn, or unistd headers.
//   - All types in namespace vanguard::render.

#pragma once
#include <cstdint>

namespace vanguard {
namespace render {

// Opaque handle identifying an imported AHardwareBuffer inside the backend.
// 0 is always invalid.
using HardwareBufferHandle = uint64_t;
constexpr HardwareBufferHandle kInvalidHardwareBufferHandle = 0;

// Descriptor populated by importHardwareBuffer on success.
// Mirrors the relevant fields of AHardwareBuffer_Desc.
struct HardwareBufferDescriptor {
    uint32_t width;
    uint32_t height;
    uint32_t layers;
    uint32_t format;  // AHARDWAREBUFFER_FORMAT_* value
    uint32_t stride;  // row stride in pixels (0 if not applicable)
    uint64_t usage;   // AHARDWAREBUFFER_USAGE_* bitmask
};

// Result codes returned by importHardwareBuffer / releaseHardwareBuffer /
// hasHardwareBuffer. Negative values are reserved for future extension.
enum class HardwareBufferImportResult : int32_t {
    kSuccess                   = 0,
    kUnavailable               = 1,  // backend or platform does not support this
    kBackendNotInitialized     = 2,  // importHardwareBuffer called before initialize()
    kInvalidArgument           = 3,  // null pointer, zero dimensions, unsupported usage, etc.
    kDuplicateImport           = 4,  // same AHardwareBuffer* already has an active import
    kIncompatibleBuffer        = 5,  // buffer format/usage rejected by Vulkan
    kVulkanFunctionUnavailable = 6,  // required vkGet*ProcAddr symbol not present
    kVulkanFailure             = 7,  // a Vulkan API call returned an error
    kUnknownHandle             = 8,  // releaseHardwareBuffer called with unrecognised handle
};

} // namespace render
} // namespace vanguard
