// scrypt_core verification harness.
//
// Drives the DUT with known-good Litecoin block headers and confirms
// `found_hash` byte-for-byte against a scrypt reference computed offline.
// Closes TODO #25 (conformance) and exercises #15 (non-trivial target,
// `<` comparator, byte-swap path at scrypt_core.sv:105-106).
//
// Reference scrypt PoW hashes were derived from each block's 80-byte
// header using Python's hashlib.scrypt (OpenSSL-backed) with LTC's
// scrypt-1024-1-1 parameters.  To regenerate or add vectors:
//
//   python3 -c "
//   import hashlib, sys
//   hdr = bytes.fromhex(sys.argv[1])
//   print(hashlib.scrypt(hdr, salt=hdr, n=1024, r=1, p=1, dklen=32).hex())
//   " <80-byte-header-hex>
//
// Raw headers were pulled from blockchair's /litecoin/raw/block/<N>
// endpoint and cross-checked by computing double-SHA256(header) and
// matching the published block ID.
//
// Byte/endian conventions at the chip's I/O boundary
// (see scrypt_core.sv:21-23, 105-106, 165-175):
//   - header[639:0]: byte 0 of the 80-byte LTC wire header at bits [639:632]
//   - target[255:0]: byte 0 of the 32-byte target at bits [255:248]
//   - found_hash[255:0]: byte 0 of the scrypt output at bits [255:248]
//   - header_reg[31:0] (= wire offset 76..79) is overwritten by the FSM
//     with `nonce_cur`, big-endian-on-bus.  Because LTC stores its nonce
//     little-endian on the wire, the value of `nonce_cur` that recreates
//     a given block's header is byteswap32(wire_nonce_le).  See
//     scrypt_core.sv:262 / 381.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>

#include "Vscrypt_core.h"
#include "verilated.h"

namespace {

constexpr uint64_t kTimeoutCycles = 2'000'000;
constexpr uint32_t kNonceWindow   = 2;   // sweep [chip_nonce - W, chip_nonce + W]

struct ScryptVector {
    const char* name;
    uint8_t  header[80];         // wire bytes, byte 0 first
    uint8_t  expected_hash[32];  // scrypt output, byte 0 first
    uint32_t chip_nonce;         // value of `nonce_cur` that recreates `header`
    uint32_t wire_nonce_le;      // informational: nonce as the LTC protocol stores it
};

// LTC block 0 (genesis). Block ID 12a765e3...; wire nonce 2084524493.
constexpr ScryptVector kVecGenesis = {
    "LTC block 0 (genesis)",
    /* header = */ {
        0x01,0x00,0x00,0x00,                                            // version (1)
        0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,                       // prev_block
        0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
        0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
        0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
        0xd9,0xce,0xd4,0xed, 0x11,0x30,0xf7,0xb7,                       // merkle root
        0xfa,0xad,0x9b,0xe2, 0x53,0x23,0xff,0xaf,
        0xa3,0x32,0x32,0xa1, 0x7c,0x3e,0xdf,0x6c,
        0xfd,0x97,0xbe,0xe6, 0xba,0xfb,0xdd,0x97,
        0xb9,0xaa,0x8e,0x4e,                                            // time   1317972665
        0xf0,0xff,0x0f,0x1e,                                            // bits   0x1e0ffff0
        0xcd,0x51,0x3f,0x7c                                             // nonce  2084524493
    },
    /* expected_hash = */ {
        0x00,0x1e,0x67,0xb0, 0x13,0x72,0x6f,0xd7,
        0x38,0x2e,0x9a,0xcb, 0x69,0x16,0x5b,0x4b,
        0x63,0x16,0x22,0x7f, 0xb3,0x15,0x6b,0x5b,
        0x41,0x4b,0xa6,0x34, 0x0c,0x05,0x00,0x00
    },
    /* chip_nonce   = */ 0xcd513f7cu,   // bswap32(0x7c3f51cd)
    /* wire_nonce_le= */ 2084524493u,
};

// LTC block 31337. Block ID 77b6abdc...; wire nonce 12532.
constexpr ScryptVector kVec31337 = {
    "LTC block 31337",
    /* header = */ {
        0x01,0x00,0x00,0x00,                                            // version (1)
        0x38,0x6b,0x76,0xe3, 0x31,0x18,0x65,0x40,                       // prev_block
        0x97,0x4e,0xed,0x86, 0x89,0xd0,0xe7,0x9d,
        0x8f,0x09,0x3c,0xca, 0x00,0x2d,0xcb,0xb3,
        0xb6,0x38,0x76,0x56, 0xf3,0x3b,0x18,0x76,
        0x93,0xd7,0xcc,0x4d, 0xa1,0xd9,0x79,0x7c,                       // merkle root
        0x50,0x79,0x13,0x03, 0xca,0x2f,0x78,0x48,
        0x97,0x55,0xb2,0x77, 0xda,0x7b,0x38,0xda,
        0xb8,0x5f,0x6b,0x08, 0xc9,0xa5,0x9b,0x22,
        0x95,0xee,0xbf,0x4e,                                            // time   1321201301
        0x5b,0xa9,0x01,0x1d,                                            // bits   0x1d01a95b
        0xf4,0x30,0x00,0x00                                             // nonce  12532
    },
    /* expected_hash = */ {
        0xa6,0x40,0x6f,0x0f, 0xbd,0x3f,0x41,0xd3,
        0x65,0x5a,0x3b,0x54, 0x0b,0xd2,0x96,0x95,
        0x63,0x1d,0xb3,0xeb, 0x7d,0xb6,0x58,0xa2,
        0x01,0x58,0x51,0x08, 0x00,0x00,0x00,0x00
    },
    /* chip_nonce   = */ 0xf4300000u,   // bswap32(0x000030f4)
    /* wire_nonce_le= */ 12532u,
};

void tick(Vscrypt_core& top) {
    top.clk = 0; top.eval();
    top.clk = 1; top.eval();
}

void reset(Vscrypt_core& top, int cycles = 10) {
    top.rst_n = 0;
    for (int i = 0; i < cycles; ++i) tick(top);
    top.rst_n = 1;
    tick(top);
}

// Pack 80 wire bytes into the 640-bit `header` bus: byte 0 at bits [639:632].
// Word w (Verilator's split) covers bits [w*32+31 : w*32] and holds wire
// bytes 4*(19-w) .. 4*(19-w)+3, big-endian within the word.
void load_header(Vscrypt_core& top, const uint8_t hdr[80]) {
    for (int w = 0; w < 20; ++w) {
        const uint8_t* p = hdr + 4 * (19 - w);
        top.header[w] = (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
                        (uint32_t(p[2]) <<  8) |  uint32_t(p[3]);
    }
}

// Pack 32 target bytes into the 256-bit `target` bus: byte 0 at bits [255:248].
void load_target(Vscrypt_core& top, const uint8_t tgt[32]) {
    for (int w = 0; w < 8; ++w) {
        const uint8_t* p = tgt + 4 * (7 - w);
        top.target[w] = (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
                        (uint32_t(p[2]) <<  8) |  uint32_t(p[3]);
    }
}

// Read the 256-bit `found_hash` bus back into 32 wire bytes (byte 0 first).
void unload_hash(const Vscrypt_core& top, uint8_t out[32]) {
    for (int w = 0; w < 8; ++w) {
        uint32_t word = top.found_hash[w];
        uint8_t* p = out + 4 * (7 - w);
        p[0] = uint8_t(word >> 24);
        p[1] = uint8_t(word >> 16);
        p[2] = uint8_t(word >>  8);
        p[3] = uint8_t(word);
    }
}

// out = expected + 1, where both are treated as little-endian 256-bit
// integers (byte 0 is the LSB).  Mirrors scrypt_core.sv:105-106, which
// {<<8}-reverses both target and hash before the `<` comparison.  The
// resulting target is the tightest value that will fire on `expected`
// and reject every other 256-bit hash.
bool target_plus_one_le(const uint8_t expected[32], uint8_t out[32]) {
    uint16_t carry = 1;
    for (int i = 0; i < 32; ++i) {
        uint16_t s = uint16_t(expected[i]) + carry;
        out[i] = uint8_t(s & 0xff);
        carry  = uint16_t(s >> 8);
    }
    return carry == 0;  // false only if expected == 2^256 - 1 (impossible)
}

void hex_dump(const char* label, const uint8_t* data, size_t n) {
    std::printf("  %-14s ", label);
    for (size_t i = 0; i < n; ++i) std::printf("%02x", data[i]);
    std::printf("\n");
}

// Submit one job to a fresh DUT, wait for the first `found_valid` (or
// the job to drain), and return whether a hash was captured.
struct JobResult {
    bool     fired;
    uint32_t found_nonce;
    uint8_t  found_hash_bytes[32];
    uint64_t cycles;
    uint16_t nonces_done;
};

JobResult run_job(const uint8_t header[80],
                  const uint8_t target[32],
                  uint32_t      nonce_base,
                  uint16_t      nonce_range) {
    JobResult r{};
    auto top = std::make_unique<Vscrypt_core>();
    top->clk = 0; top->rst_n = 0; top->job_valid = 0;
    top->nonce_base = 0; top->nonce_range = 0;
    for (int i = 0; i < 20; ++i) top->header[i] = 0;
    for (int i = 0; i < 8;  ++i) top->target[i] = 0;
    top->eval();
    reset(*top);

    load_header(*top, header);
    load_target(*top, target);
    top->nonce_base  = nonce_base;
    top->nonce_range = nonce_range;
    top->job_valid   = 1;
    tick(*top);
    top->job_valid   = 0;

    while (r.cycles < kTimeoutCycles) {
        tick(*top);
        ++r.cycles;
        if (top->found_valid) {
            r.fired       = true;
            r.found_nonce = top->found_nonce;
            unload_hash(*top, r.found_hash_bytes);
            break;
        }
        if (r.cycles % 50000 == 0) {
            std::printf("  ... %llu cycles, busy=%u, nonces_done=%u\n",
                        static_cast<unsigned long long>(r.cycles),
                        static_cast<unsigned>(top->busy),
                        static_cast<unsigned>(top->nonces_done));
        }
        if (!top->busy && r.cycles > 5) break;
    }
    r.nonces_done = top->nonces_done;
    top->final();
    return r;
}

// Drive one vector through the chip and confirm `found_hash` matches.
// Returns true on PASS.  On any failure, re-runs the same header with the
// max target so we can see what the chip actually produced for the
// winning nonce -- the diff vs `expected_hash` is what TODO #25 wants
// us to look at when chasing PBKDF2-boundary endian bugs.
bool run_vector(const ScryptVector& v) {
    std::printf("\n[VECTOR] %s\n", v.name);
    std::printf("  wire nonce (LE) : %u  (chip_nonce = 0x%08x)\n",
                v.wire_nonce_le, v.chip_nonce);

    uint8_t tight_target[32];
    if (!target_plus_one_le(v.expected_hash, tight_target)) {
        std::printf("[FAIL] target arithmetic overflowed\n");
        return false;
    }

    JobResult r = run_job(v.header, tight_target,
                          v.chip_nonce - kNonceWindow,
                          uint16_t(2 * kNonceWindow + 1));

    bool ok = false;
    if (r.fired) {
        bool nonce_ok = (r.found_nonce == v.chip_nonce);
        bool hash_ok  = (std::memcmp(r.found_hash_bytes, v.expected_hash, 32) == 0);
        std::printf("  cycles to hit  : %llu\n",
                    static_cast<unsigned long long>(r.cycles));
        std::printf("  found_nonce    : 0x%08x %s\n",
                    r.found_nonce, nonce_ok ? "OK" : "MISMATCH");
        if (hash_ok) {
            hex_dump("hash:", r.found_hash_bytes, 32);
            ok = nonce_ok;
        } else {
            hex_dump("expected hash:", v.expected_hash,    32);
            hex_dump("actual hash:",   r.found_hash_bytes, 32);
        }
    } else {
        std::printf("[FAIL] tight target produced no match in %llu cycles "
                    "(nonces_done=%u)\n",
                    static_cast<unsigned long long>(r.cycles),
                    static_cast<unsigned>(r.nonces_done));
    }

    // Diagnostic: re-run with max target and a single-nonce range so the
    // chip is forced to report whatever hash it computes for the winning
    // nonce.  This lets us see the byte-level diff against expected.
    if (!ok) {
        std::printf("  -- diagnostic: re-running chip_nonce with max target --\n");
        uint8_t max_target[32];
        std::memset(max_target, 0xff, 32);
        JobResult d = run_job(v.header, max_target, v.chip_nonce, 1);
        if (d.fired) {
            std::printf("  diag found_nonce : 0x%08x %s\n",
                        d.found_nonce,
                        d.found_nonce == v.chip_nonce ? "OK" : "MISMATCH");
            hex_dump("expected hash:",  v.expected_hash,      32);
            hex_dump("chip hash:",      d.found_hash_bytes,   32);
        } else {
            std::printf("  diag: chip never asserted found_valid even with max target "
                        "(cycles=%llu)\n",
                        static_cast<unsigned long long>(d.cycles));
        }
    }

    std::printf("%s\n", ok ? "[PASS]" : "[FAIL]");
    return ok;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    std::printf("=== scrypt_core conformance against LTC reference vectors ===\n");

    bool ok = true;
    ok &= run_vector(kVecGenesis);
    ok &= run_vector(kVec31337);

    std::printf("\n%s\n", ok ? "ALL PASS" : "FAILED");
    return ok ? 0 : 1;
}
