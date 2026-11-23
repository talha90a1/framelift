// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "Types.h"
namespace veyra::remoteplay {
class Sequence16Extender {
public:
    struct Result {std::uint64_t value=0;bool accepted=false,first=false;std::uint32_t gap=0;};
    Result observe(std::uint16_t) noexcept;
    void reset() noexcept {*this={};}
private:
    bool initialized_=false;std::uint16_t previous_=0;std::uint64_t extended_=0;
};
} // namespace veyra::remoteplay
