#pragma once
#include <string>

namespace vanguard {
namespace core {

enum class StatusCode {
    kOk = 0,
    kError = 1,
    kUnimplemented = 2
};

class Status {
public:
    Status() : code_(StatusCode::kOk) {}
    Status(StatusCode code, const std::string& message) : code_(code), message_(message) {}
    
    bool ok() const { return code_ == StatusCode::kOk; }
    StatusCode code() const { return code_; }
    const std::string& message() const { return message_; }

    static Status OK() { return Status(); }

private:
    StatusCode code_;
    std::string message_;
};

} // namespace core
} // namespace vanguard
