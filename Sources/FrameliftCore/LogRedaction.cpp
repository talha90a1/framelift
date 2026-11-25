// SPDX-License-Identifier: GPL-3.0-only
// Conservative log redaction: upstream lines (registration requests, ctrl hexdumps, RP-Auth /
// RP-Registkey headers) can contain keys, so sensitive lines are dropped, never masked.
#include "LogRedaction.h"
#include <algorithm>
#include <array>
#include <cctype>
#include <vector>

namespace framelift {
namespace {
constexpr std::size_t kMaxLine = 400;   // printed prefix
constexpr std::size_t kMaxScan = 4096;  // prefix checked for sensitive words and dumps

bool isHex(unsigned char c) { return std::isxdigit(c) != 0; }
bool isAlpha(unsigned char c) { return std::isalpha(c) != 0; }

bool containsSensitiveWord(const std::string& lower) {
    static constexpr std::array<std::string_view, 20> substrings = {
        "regist", "morning", "auth", "key", "secret", "rpkey", "hexdump", "credential", "account",
        "psn", "nonce", "token", "cookie", "password", "signature", "ecdh", "crypt", "handshake",
        "online id", "online_id"};
    for (auto word : substrings)
        if (lower.find(word) != std::string::npos) return true;
    // "pin" only as a word: "ping"/"skipping"/"mapping" are harmless.
    for (std::size_t at = lower.find("pin"); at != std::string::npos; at = lower.find("pin", at + 1)) {
        const bool startOk = at == 0 || !isAlpha(static_cast<unsigned char>(lower[at - 1]));
        const bool endOk = at + 3 >= lower.size() || !isAlpha(static_cast<unsigned char>(lower[at + 3]));
        if (startOk && endOk) return true;
    }
    return false;
}

bool isSpace(unsigned char c) { return c == ' ' || c == '\t'; }
bool isLowerHex(unsigned char c) { return std::isdigit(c) || (c >= 'a' && c <= 'f'); }

std::string_view trimmed(std::string_view s) {
    while (!s.empty() && (isSpace(static_cast<unsigned char>(s.front())) || s.front() == '\r' || s.front() == '\n'))
        s.remove_prefix(1);
    while (!s.empty() && (isSpace(static_cast<unsigned char>(s.back())) || s.back() == '\r' || s.back() == '\n'))
        s.remove_suffix(1);
    return s;
}

std::vector<std::string_view> tokens(std::string_view line) {
    std::vector<std::string_view> out;
    std::size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && isSpace(static_cast<unsigned char>(line[i]))) ++i;
        const auto start = i;
        while (i < line.size() && !isSpace(static_cast<unsigned char>(line[i]))) ++i;
        if (i > start) out.push_back(line.substr(start, i - start));
    }
    return out;
}

bool isBytePair(std::string_view t) {
    return t.size() == 2 && isHex(static_cast<unsigned char>(t[0])) && isHex(static_cast<unsigned char>(t[1]));
}

// Hexdump rows of any length, including a final short row such as "    10 64      ...  d":
//  - chiaki_log_hexdump layout: "%6zx" offset, 1..16 byte pairs, optional ASCII column;
//  - lines made mostly of byte pairs and whitespace;
//  - a bare hex string (short chiaki_log_hexdump_raw output).
bool looksLikeDumpRow(std::string_view line) {
    const auto body = trimmed(line);
    if (body.empty()) return false;
    if (body.size() >= 2 && body.size() % 2 == 0 &&
        std::all_of(body.begin(), body.end(), [](char c) { return isHex(static_cast<unsigned char>(c)); }) &&
        (body.size() >= 8 || std::any_of(body.begin(), body.end(), [](char c) { return std::isdigit(static_cast<unsigned char>(c)) != 0; })))
        return true; // "1064", not words such as "FEC" or "feed"
    const auto parts = tokens(body);
    std::size_t pairs = 0, pairChars = 0;
    for (auto t : parts)
        if (isBytePair(t)) {
            ++pairs;
            pairChars += 2;
        }
    if (pairs == 0) return false;
    // offset + hex + ascii columns
    if (parts.size() >= 2 && parts[0].size() <= 8 &&
        std::all_of(parts[0].begin(), parts[0].end(), [](char c) { return isLowerHex(static_cast<unsigned char>(c)); })) {
        std::size_t i = 1;
        while (i < parts.size() && isBytePair(parts[i])) ++i;
        const auto rowPairs = i - 1;
        if (rowPairs >= 1 && rowPairs <= 16 && (i == parts.size() || (i + 1 == parts.size() && parts[i].size() <= 16)))
            return true;
    }
    // Mostly byte pairs or whitespace (measured on the untrimmed line, padding included).
    std::size_t spaces = 0;
    for (char c : line) spaces += isSpace(static_cast<unsigned char>(c)) ? 1 : 0;
    return (spaces + pairChars) * 4 >= line.size() * 3 || pairs * 2 > parts.size();
}

bool looksLikeDump(std::string_view line) {
    if (line.starts_with("offset 0")) return true; // chiaki_log_hexdump header
    if (looksLikeDumpRow(line)) return true;
    std::size_t hexRun = 0, digitRun = 0, b64Run = 0, pairTokens = 0;
    bool b64Digit = false, b64Upper = false, b64Lower = false;
    for (std::size_t i = 0; i < line.size(); ++i) {
        const auto c = static_cast<unsigned char>(line[i]);
        hexRun = isHex(c) ? hexRun + 1 : 0;
        digitRun = std::isdigit(c) ? digitRun + 1 : 0;
        if (hexRun >= 16 || digitRun >= 12) return true; // raw hex blob / decimal account id
        if (std::isalnum(c) || c == '+' || c == '/' || c == '=' || c == '_' || c == '-') {
            ++b64Run;
            b64Digit |= std::isdigit(c) != 0;
            b64Upper |= std::isupper(c) != 0;
            b64Lower |= std::islower(c) != 0;
            if (b64Run >= 20 && b64Digit && b64Upper && b64Lower) return true;
        } else {
            b64Run = 0;
            b64Digit = b64Upper = b64Lower = false;
        }
        // "xx xx xx ..." byte pairs (chiaki_log_hexdump body).
        if (i + 2 <= line.size() && isHex(c) && isHex(static_cast<unsigned char>(line[i + 1])) &&
            (i == 0 || line[i - 1] == ' ') && (i + 2 == line.size() || line[i + 2] == ' ')) {
            if (++pairTokens >= 6) return true;
            ++i;
        } else if (c != ' ') {
            pairTokens = 0;
        }
    }
    return false;
}
} // namespace

bool redactLogLine(std::string_view line, std::string& out) {
    out.clear();
    if (line.empty()) return false;
    const auto scanned = line.substr(0, kMaxScan);
    std::string lower(scanned);
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (containsSensitiveWord(lower) || looksLikeDump(scanned)) return false;
    const auto n = std::min(line.size(), kMaxLine);
    out.reserve(n + 3);
    for (std::size_t i = 0; i < n; ++i) {
        const auto c = static_cast<unsigned char>(line[i]);
        out.push_back(c >= 0x20 && c < 0x7f ? static_cast<char>(c) : '?');
    }
    if (line.size() > kMaxLine) out += "...";
    // Judge the printable copy as well: '?' replacing control bytes can merge tokens into a dump row.
    if (looksLikeDump(out)) {
        out.clear();
        return false;
    }
    return true;
}

bool LogRedactor::redact(std::string_view line, std::string& out) {
    out.clear();
    const auto scanned = line.substr(0, kMaxScan);
    if (afterIntro_) {
        const bool continuation = scanned.empty() || isSpace(static_cast<unsigned char>(scanned.front())) ||
                                  trimmed(scanned).starts_with("offset ") || looksLikeDump(scanned);
        if (continuation) return false; // still inside the dump introduced by "...:"
        afterIntro_ = false;
    }
    afterIntro_ = trimmed(scanned).ends_with(':');
    return redactLogLine(line, out);
}
} // namespace framelift
