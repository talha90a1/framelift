// SPDX-License-Identifier: GPL-3.0-only
// libFuzzer target for the reused Veyra core (no chiaki): inspectAnnexB, VideoIngress,
// AudioIngress, SessionInbox token/lifecycle ordering, and the log redactor.
// Built by Tests/core_fuzz.sh with Homebrew LLVM (-fsanitize=fuzzer,address,undefined).
#include "LogRedaction.h"
#include "veyra/remoteplay/SessionInbox.h"
#include "veyra/remoteplay/VideoIngress.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

using namespace veyra::remoteplay;

namespace {
#define CHECK(cond)                                                                       \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            std::fprintf(stderr, "invariant failed: %s (%s:%d)\n", #cond, __FILE__, __LINE__); \
            std::abort();                                                                 \
        }                                                                                 \
    } while (0)

struct Reader {
    const uint8_t* data;
    size_t size, pos = 0;
    bool empty() const { return pos >= size; }
    uint8_t u8() { return pos < size ? data[pos++] : 0; }
    uint16_t u16() { return uint16_t(u8() | (u8() << 8)); }
    std::span<const uint8_t> bytes(size_t n) {
        n = std::min(n, size - std::min(pos, size));
        std::span<const uint8_t> out(data + pos, n);
        pos += n;
        return out;
    }
};

// Builds an Annex-B buffer whose NAL types come from the input, so the deeper
// config/IDR/P-frame paths are reachable. Mode 0: raw bytes (malformed input).
std::vector<uint8_t> makeAnnexB(Reader& r, Codec codec) {
    std::vector<uint8_t> out;
    const auto mode = r.u8() % 4;
    if (mode == 0) {
        auto raw = r.bytes(r.u8());
        out.assign(raw.begin(), raw.end());
        return out;
    }
    const auto nals = 1 + r.u8() % 4;
    for (unsigned i = 0; i < nals; ++i) {
        if (r.u8() & 1) out.push_back(0);
        out.insert(out.end(), {0, 0, 1});
        const auto pick = r.u8();
        if (codec == Codec::H264) {
            static constexpr uint8_t types[] = {7, 8, 5, 1, 6, 9, 0, 24};
            out.push_back(uint8_t(0x60 | types[pick % 8]));
        } else {
            static constexpr uint8_t types[] = {32, 33, 34, 19, 20, 1, 21, 39, 63};
            out.push_back(uint8_t(types[pick % 9] << 1));
            out.push_back(pick & 0x80 ? 0 : 1); // temporal id 0 is invalid
        }
        auto body = r.bytes(r.u8() % 24);
        out.insert(out.end(), body.begin(), body.end());
        if (mode == 3 && !out.empty()) out.back() = 0; // trailing zero / truncated start code
    }
    return out;
}

// Independent oracle for chiaki_log_hexdump rows: "%6zx" offset, 1..16 byte pairs, optional ASCII.
bool looksLikeHexRow(const std::string& line) {
    std::vector<std::string> parts;
    std::string cur;
    for (char c : line) {
        if (c == ' ' || c == '\t') {
            if (!cur.empty()) parts.push_back(cur), cur.clear();
        } else cur.push_back(c);
    }
    if (!cur.empty()) parts.push_back(cur);
    if (parts.size() < 2 || parts[0].size() > 8) return false;
    for (char c : parts[0])
        if (!std::isdigit(static_cast<unsigned char>(c)) && !(c >= 'a' && c <= 'f')) return false;
    std::size_t i = 1;
    auto pair = [](const std::string& t) {
        return t.size() == 2 && std::isxdigit(static_cast<unsigned char>(t[0])) && std::isxdigit(static_cast<unsigned char>(t[1]));
    };
    while (i < parts.size() && pair(parts[i])) ++i;
    return i > 1 && i - 1 <= 16 && (i == parts.size() || (i + 1 == parts.size() && parts[i].size() <= 16));
}

void checkPopped(const QueuedVideo& unit, Codec codec) {
    CHECK(unit.sample.payload.paddingIsZero());
    const auto nal = inspectAnnexB(unit.sample.payload.bytes(), codec);
    CHECK(nal.valid && nal.hasPicture);
    if (unit.resetDecoder) {
        CHECK(unit.configBefore != nullptr);
        CHECK(nal.idr);
        CHECK(inspectAnnexB(unit.configBefore->payload.bytes(), codec).hasConfig);
    }
}
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    Reader r{data, size};
    const auto codec = static_cast<Codec>(r.u8() % 3);
    QueueLimits limits;
    limits.maxFrames = 1 + r.u8() % 6;
    VideoIngress ingress(limits);
    AudioIngress audio(10 + r.u8() % 190);
    SessionInbox inbox(limits);
    int wakes = 0;
    inbox.setWakeHook([](void* user) noexcept { ++*static_cast<int*>(user); }, &wakes);
    Generation generation = 1;
    ingress.begin(generation);
    audio.begin(generation);
    std::optional<SessionInbox::Token> token = inbox.begin(0);
    std::optional<SessionInbox::Token> stale;
    HostTime now = 1000;
    uint64_t audioSample = 0;

    while (!r.empty()) {
        const auto op = r.u8() % 12;
        now += r.u8() * 1000; // up to 25 ms per step; the 100 ms age limit is reachable
        switch (op) {
        case 0: { // pure parser
            auto buf = makeAnnexB(r, codec);
            const auto nal = inspectAnnexB(buf, codec);
            if (!nal.valid) CHECK(!nal.hasPicture && !nal.hasConfig && !nal.idr);
            break;
        }
        case 1:
        case 2:
        case 3: { // VideoIngress push
            VideoSample s;
            s.generation = (r.u8() % 16) ? generation : generation + 1;
            s.codec = codec;
            s.kind = (r.u8() & 1) ? SampleKind::AccessUnit : SampleKind::CodecConfig;
            const auto res = r.u8();
            s.width = res % 5 ? 1920 : 1280;
            s.height = res % 5 ? 1080 : (res & 1 ? 720 : 1080);
            s.framesLost = (r.u8() % 8 == 0) ? int32_t(r.u8()) - 8 : 0;
            s.referenceRecovered = r.u8() % 16 == 0;
            if (r.u8() & 1) s.wireFrameIndex = r.u16();
            s.arrival100ns = now - HostTime(r.u8()) * 10000;
            auto buf = makeAnnexB(r, codec);
            s.payload = PaddedBytes::copy(buf);
            (void)ingress.push(std::move(s), now);
            break;
        }
        case 4:
            while (auto unit = ingress.tryPop(now)) checkPopped(*unit, codec);
            break;
        case 5:
            (void)ingress.takeIdrRequest(now);
            if (r.u8() & 1) ingress.requireKeyframe();
            break;
        case 6: { // generation change / close
            const auto what = r.u8() % 3;
            if (what == 0) ingress.close();
            else if (what == 1) ingress.begin(++generation);
            else audio.begin(generation);
            break;
        }
        case 7: { // audio
            PcmBlock b;
            b.generation = (r.u8() % 16) ? generation : generation + 1;
            b.channels = r.u8() % 3;
            b.rate = (r.u8() & 1) ? 48000 : r.u16();
            const auto frames = r.u8() * 8u;
            b.firstSample = (r.u8() % 8 == 0) ? audioSample - (audioSample ? 1 : 0) : audioSample;
            audioSample = b.firstSample + frames;
            b.arrival100ns = now;
            b.samples.assign(size_t(frames) * b.channels, int16_t(r.u16()));
            (void)audio.push(std::move(b));
            while (auto out = audio.tryPop()) CHECK(out->valid());
            break;
        }
        case 8: { // inbox token traffic (current or stale generation)
            auto& t = (r.u8() & 3) == 0 && stale ? stale : token;
            if (!t) break;
            VideoSample s;
            s.generation = t->generation();
            s.codec = codec;
            s.kind = (r.u8() & 1) ? SampleKind::AccessUnit : SampleKind::CodecConfig;
            s.width = 1920;
            s.height = 1080;
            s.arrival100ns = monotonic100ns();
            s.payload = PaddedBytes::copy(makeAnnexB(r, codec));
            // The Chiaki callback's answer: false only for a payload that is not Annex-B.
            const bool wellFormed = !s.payload.bytes().empty() && inspectAnnexB(s.payload.bytes(), codec).valid;
            const auto delivery = deliverChiakiVideo(*t, std::move(s));
            CHECK(chiakiVideoCallbackResult(delivery) == wellFormed);
            CHECK((delivery == VideoDelivery::Malformed) == !wellFormed);
            const auto ev = r.u8() % 8;
            if (ev == 0) t->connected();
            else if (ev == 1) t->loginPinRequired();
            else if (ev == 2) t->failed(2000 + r.u8() % 14);
            else if (ev == 3) t->wake();
            break;
        }
        case 9: // inbox consumer
            while (auto unit = inbox.tryVideo(monotonic100ns())) checkPopped(*unit, codec);
            (void)inbox.tryAudio();
            (void)inbox.takeIdrRequest(monotonic100ns());
            if (token) inbox.decodeFailed(token->generation());
            (void)inbox.status();
            (void)inbox.snapshot();
            break;
        case 10: // inbox lifecycle in the documented order; keep the old token as stale
            inbox.invalidate();
            inbox.finishStop();
            stale = token;
            token = inbox.begin(monotonic100ns());
            break;
        case 11: { // log redaction
            auto raw = r.bytes(r.u8());
            std::string line(raw.begin(), raw.end());
            std::string out;
            if (framelift::redactLogLine(line, out)) {
                CHECK(out.size() <= 403);
                size_t hexRun = 0;
                for (char c : out) {
                    hexRun = std::isxdigit(static_cast<unsigned char>(c)) ? hexRun + 1 : 0;
                    CHECK(hexRun < 16);
                    CHECK(c >= 0x20 && c < 0x7f);
                }
                // No surviving line may be a hexdump row: offset + byte pairs (+ ASCII column).
                CHECK(!looksLikeHexRow(out));
            }
            // Stateful redactor over '\n'-separated lines: stricter than the stateless one, and
            // no indented line survives directly after a line ending in ':'.
            framelift::LogRedactor redactor;
            bool afterIntro = false;
            std::size_t start = 0;
            while (start <= line.size()) {
                auto end = line.find('\n', start);
                if (end == std::string::npos) end = line.size();
                const std::string part = line.substr(start, end - start);
                std::string a, b;
                const bool kept = redactor.redact(part, a);
                if (kept) {
                    CHECK(framelift::redactLogLine(part, b) && a == b);
                    CHECK(!(afterIntro && !part.empty() && (part[0] == ' ' || part[0] == '\t')));
                }
                afterIntro = false; // only the line right after the intro is checked here
                std::string_view tail(part);
                while (!tail.empty() && (tail.back() == ' ' || tail.back() == '\t' || tail.back() == '\r')) tail.remove_suffix(1);
                if (tail.ends_with(':')) afterIntro = true;
                start = end + 1;
            }
            break;
        }
        }
        const auto stats = ingress.stats();
        CHECK(stats.depth <= limits.maxFrames);
    }
    inbox.invalidate();
    return 0;
}
