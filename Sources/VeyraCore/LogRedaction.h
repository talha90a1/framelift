// SPDX-License-Identifier: GPL-3.0-only
// Framelift: redaction of upstream (chiaki) log lines before they leave the core.
#pragma once
#include <string>
#include <string_view>

namespace framelift {
// Returns false when the line must be dropped (possible key material or a hexdump).
// Otherwise writes a printable, length-capped copy to `out`.
bool redactLogLine(std::string_view line, std::string& out);

// Stateful variant for one stream of lines (use one instance per logging thread). Adds the
// continuation rule: after a line ending in ':' (e.g. "Received presumably invalid Session Id:"),
// following indented, hexdump-like or "offset ..." lines are dropped until the first normal line,
// which is then judged by redactLogLine.
class LogRedactor {
public:
    bool redact(std::string_view line, std::string& out);
private:
    bool afterIntro_ = false;
};
} // namespace framelift
