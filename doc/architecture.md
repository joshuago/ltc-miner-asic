# LTC-3N: Litecoin Miner ASIC for TSMC N3 (3nm)

## Performance vs Antminer L9

The numbers below are derived from the per-core cycle count produced
by Verilator simulation. The microarchitecture (a single Salsa20
pipeline per core, sequential BlockMix calls, single-port scratchpad,
serialized SHA-256 blocks) yields roughly 53,100 cycles per scrypt
hash, which at 1.2 GHz is 22.6 KH/s per core and 92.6 MH/s across
4,096 cores. This is substantially **slower** than the multi-chip
Antminer L9; the design's potential advantage is in J/GH, not absolute
GH/s, and even that advantage depends on the power estimate below
being achievable (see design-review-notes #20).

### System-Level Comparison

| Metric         | Antminer L9 (16Gh) | LTC-3N (this design)         | Ratio          |
|----------------|--------------------|------------------------------|----------------|
| Process        | ~6nm               | TSMC N3 (3nm)                | ~2x shrink     |
| Hashrate       | 16 GH/s            | ~92.6 MH/s                   | ~173x slower   |
| Power (target) | 3,360 W            | ~25 W (estimate, optimistic) | ~134x less     |
| Efficiency     | 210 J/GH           | ~270 J/GH (at 25 W)          | ~1.3x worse    |
| ASIC Chips     | multi-chip         | 1 chip                       | --             |
| Cores per chip | unknown            | 4,096                        | --             |
| Release        | May 2024           | 2025 (paper design)          | --             |
| Interface      | Ethernet           | UART (broken; see review)    | --             |
| Cooling        | Air (2 fans)       | Passive (claimed)            | --             |

### Chip-Level Comparison vs Antminer L3++

| Metric             | Antminer L3++ | LTC-3N (this design) | Ratio        |
|--------------------|---------------|----------------------|--------------|
| Process            | 28nm          | TSMC N3 (3nm)        | 9.3x shrink  |
| Hashrate (chip)    | ~2.0 MH/s     | ~92.6 MH/s           | ~46x         |
| Hashrate (system)  | 580 MH/s      | ~92.6 MH/s           | ~6x slower   |
| ASIC Chips         | 288           | 1 chip               | --           |
| Cores per chip     | ~12-16        | 4,096                | ~273x        |
| Per-Core Hashrate  | ~140 KH/s     | ~22.6 KH/s           | ~6x slower   |
| Core Clock         | ~400 MHz      | 1.2 GHz              | 3x           |
| Per-Core SRAM      | ~128 KB       | 128 KB               | same         |
| Total On-Chip SRAM | --            | 512 MB (implausible) | --           |
| Die Size (est)     | ~7mm^2/chip   | ~420 mm^2            | --           |
| Chip Power (est)   | ~3.3 W/chip   | ~25 W (optimistic)   | ~8x more     |
| Efficiency (est)   | 1,624 J/GH    | ~270 J/GH (at 25 W)  | ~6x better   |

Per-core hashrate is **lower** than the L3++ because each LTC-3N core
runs ROMix sequentially (one BlockMix at a time, one Salsa20 pipeline,
single-port scratchpad). The L3++ achieves higher per-core throughput
by parallelising more within each core.

### Hashrate Breakdown by Clock

| Clock    | Cycles/Hash | Per-Core KH/s | 4096-Core MH/s |
|----------|-------------|---------------|----------------|
| 800 MHz  | ~53,100     | 15.1          | 61.8           |
| 1.0 GHz  | ~53,100     | 18.8          | 77.0           |
| 1.2 GHz  | ~53,100     | 22.6          | 92.6           |

Aggregate = per-core KH/s x 4096 cores / 1000 = MH/s. (Per-core KH/s
x 4096 = ~92,569 KH/s = ~92.6 MH/s, not GH/s.)

Cycles/hash measured via Verilator simulation (ROMix dominates at ~41K cycles).

## Architecture

### Die Floorplan (21mm × 20mm)
```
+------------------------------------------------------------------+
|  PLL  |                 4096 Scrypt Cores (64 x 64 grid)          |
|  VREG |  +-------+-------+-------+-------+-------+-------+-----+  |
|        |  | core0 | core1 | core2 | core3 |  ...   | ...  |core |  |
|  UART  |  +-------+-------+-------+-------+-------+-------+4095 |  |
|  /SPI  |  +-------+-------+-------+-------+-------+-------+-----+  |
|        |  |  ...  |  ...  |  ...  |  ...  |  ...  |  ...  | ... |  |
|  JTAG  |  +-------+-------+-------+-------+-------+-------+-----+  |
|        |  |       |       |       |       |       |       |     |  |
|  Temp  +--+-------+-------+-------+-------+-------+-------+-----+--+
| Sensor |                  Job Dispatch | Nonce Mgr | Result FIFO    |
+------------------------------------------------------------------+
```

### Core Microarchitecture
```
    Block Header (80B) + Nonce (4B)
         │
    ┌────▼──────────────────┐
    │  PBKDF2-HMAC-SHA256    │  SHA-256 pipeline (10 calls, serial)
    │  → 128-byte output     │
    └────────┬───────────────┘
             │
    ┌────────▼───────────────────────────────────────┐
    │  ROMix (N=1024, r=1)                           │
    │  ┌──────────────────────────────────────────┐  │
    │  │ Phase 1: V[i]=X, X=BlockMix(X) [1024×]   │  │
    │  │ Phase 2: X=BlockMix(X^V[j])      [1024×]  │  │
    │  │                                           │  │
    │  │  1024-bit Scratchpad SRAM (128KB)         │  │
    │  │  ┌─ Salsa20/8 Pipeline (9-stage) ──────┐  │  │
    │  │  │ 8 rounds + feedforward               │  │  │
    │  │  │ 1 hash/cycle after pipeline fill      │  │  │
    │  │  └──────────────────────────────────────┘  │  │
    │  └──────────────────────────────────────────┘  │
    └────────┬───────────────────────────────────────┘
             │
    ┌────────▼──────────────┐
    │  PBKDF2-HMAC-SHA256    │  SHA-256 pipeline (6 calls, serial)
    │  → 32-byte hash        │
    └────────┬───────────────┘
             │
    ┌────────▼──────┐
    │  Compare       │  hash < target → FOUND
    │  hash < target │
    └────────────────┘
```

### Salsa20/8 Pipeline
- 8 pipeline stages (1 round/stage, column/row alternating)
- 1 feedforward addition stage
- Total latency: 9 cycles, throughput: 1 hash/cycle
- 4 parallel quarter-rounds per stage
- At 3nm, timing closure at 1.2 GHz with standard cells

### SHA-256 Pipeline
- 64 pipeline stages (1 round/stage)
- Message schedule expansion computed in parallel
- Multi-block chaining: blocks submitted serially with `sha_done` acknowledgment
- 65-cycle latency; serial submission limits throughput to ~1 block/65 cycles per multi-block message
- Can accept back-to-back independent blocks; dependent blocks wait for chaining state

### Scratchpad SRAM
- 1024 entries × 1024 bits = 128 KB per core
- 8 banks × 128-bit single-port SRAM (TSMC N3 HD macros)
- Single-cycle read/write access (not simultaneous; serialized by ROMix FSM)
- Address: 10 bits (0-1023)
- Total on-chip SRAM: 4096 cores × 128 KB = 512 MB

### Power Breakdown (estimated @ 0.7V, 1.2 GHz, 85°C)
| Component                    | Power   |
|------------------------------|---------|
| 4096× SRAM scratchpads       | 8.2 W   |
| 4096× Salsa20 pipelines      | 8.2 W   |
| 4096× SHA-256 pipelines      | 3.3 W   |
| Control + interconnect       | 2.0 W   |
| PLL + clock tree             | 1.0 W   |
| Leakage (125°C)              | 2.0 W   |
| **Total**                    | **~24.7 W** |

## RTL Module Tree

```
scrypt_top.sv
├── pll.sv                     # TSMC N3 PLL wrapper
├── uart.sv                    # UART RX/TX controller
├── sync_fifo.sv               # CDC FIFO for results
├── nonce_manager.sv           # Nonce distribution across 4096 cores
└── scrypt_core.sv (×4096)     # Per-core Scrypt miner
    ├── sha256_pipelined.sv     # 64-stage SHA-256 pipeline
    ├── romix.sv                # ROMix memory-hard mixing (N=1024)
    │   ├── scratchpad_spram.sv  # 128KB banked SRAM (8×1024×128b)
    │   └── blockmix.sv         # BlockMix(r=1): 2 Salsa20 calls
    │       └── salsa20_8.sv    # 9-stage Salsa20/8 pipeline
    │           └── salsa20_quarter_round.sv
    └── (FSM controller)
```

## Key Design Optimizations

1. **Banked Scratchpad**: 8 parallel 128-bit SRAM banks form a 1024-bit wide interface, enabling single-cycle V[j] access without sequential reads
2. **Pipelined Salsa20**: 8 rounds in 8 pipeline stages → 1 hash/cycle throughput. At 3nm, potentially 2 rounds/stage for 4-cycle latency
3. **Massive Parallelism**: 4,096 independent cores, each with dedicated 128KB SRAM, no resource sharing contention
4. **Continuous Operation**: Nonce manager keeps all cores saturated; as soon as one core finishes a nonce range, a new one is assigned
5. **CDC-aware Results**: Async FIFO bridges core_clk (1.2 GHz) to sys_clk (100 MHz) for found-share reporting
6. **Low-Power**: Clock gating per core when idle, dynamic frequency scaling (600-1200 MHz), 0.65-0.9V Vcore range

## Critical Path Analysis

The Salsa20 quarter-round is the timing bottleneck:
```
32b ADD → ROT → XOR → 32b ADD → ROT → XOR → 32b ADD → ROT → XOR → 32b ADD → ROT → XOR
```
- TSMC N3 32-bit adder (ULVT): ~120ps
- XOR: ~8ps
- Rotation: wire routing (0ps)
- Total: ~4 × 128ps = 512ps
- Clock period: 833ps (1.2 GHz)
- **Slack: ~321ps per stage** ✓

SHA-256 round is significantly simpler (mostly adders, no deep chains), well within 833ps.

## Clocking & Reset

- 25 MHz crystal input → PLL → 4.8 GHz VCO
- Core clock: VCO/4 = 1.2 GHz (H-tree distribution)
- System clock: VCO/48 = 100 MHz (UART, control)
- UART baud clock: VCO/2600 ≈ 1.846 MHz (16× 115200 baud)
- Async reset synchronized to each domain
- Each core quadrant (256 cores) independently clock-gated

## Interface Protocol

### Job Submission (UART, 115200 baud, 8N1)
```
Byte 0:   0xA5 (magic)
Byte 1:   0x01 (cmd = new job)
Bytes 2-81:  Header (80 bytes, little-endian fields)
Bytes 82-113: Target (32 bytes)
Byte 114:  Checksum (XOR of bytes 0-113)
```

### Found Share Report
```
Byte 0:   0x5A (magic)
Byte 1:   0x01 (cmd = found share)
Bytes 2-33: Hash (32 bytes)
Bytes 34-37: Nonce (4 bytes, little-endian)
Byte 38:   Checksum
```

## Verification Strategy

1. **Salsa20/8**: Compare pipeline output against DJ Bernstein reference implementation
2. **SHA-256**: Compare against NIST test vectors (short + long messages)
3. **BlockMix**: Verify against Scrypt reference (Colin Percival)
4. **ROMix**: End-to-end test with known Scrypt test vectors
5. **PBKDF2**: Verify HMAC-SHA256 → PBKDF2 chain
6. **Full Core**: Compare against cgminer/bminer scrypt output for known Litecoin blocks
7. **Gate-level**: Post-synthesis simulation with SDF back-annotation

### Build & Simulation

Requires [Verilator](https://verilator.org) 5.028+.

```
make                 # lint all modules
make lint-salsa20    # lint salsa20/8 only
make lint-scrypt-core # lint scrypt_core only

make sim-salsa20     # build + run salsa20/8 pipeline simulation
make sim-scrypt-core  # build + run full scrypt_core simulation (~53K cycles)
make trace-salsa20   # salsa20 simulation with VCD waveform output

make clean           # remove build artifacts (obj_dir, .vcd)
```

C++ test harnesses live in `sim/`. Verilator compiles the RTL to a C++ cycle-accurate model, then links against the harness to produce a standalone executable in `obj_dir/`.

## Comparison with State-of-the-Art

| Miner                | Process | Hashrate    | Power   | Efficiency       | Year |
|----------------------|---------|-------------|---------|------------------|------|
| Antminer L3++        | 28nm    | 580 MH/s    | 942 W   | 1,624 J/GH       | 2017 |
| Antminer L7 (9050M)  | 8nm     | 9.05 GH/s   | 3,260 W | 360 J/GH         | 2021 |
| Goldshell LT5 Pro    | 12nm    | 2.45 GH/s   | 670 W   | 273 J/GH         | 2021 |
| Antminer L9 (16Gh)   | ~6nm    | 16 GH/s     | 3,360 W | 210 J/GH         | 2024 |
| Antminer L9 (17Gh)   | ~6nm    | 17 GH/s     | 3,570 W | 210 J/GH         | 2024 |
| **LTC-3N (this)**    | 3nm     | ~92.6 MH/s  | ~25 W   | ~270 J/GH (best) | 2025 |

The LTC-3N hashrate figure is the simulation cycle count divided into
core_clk; it does **not** make the chip a competitor to the Antminer
L9. In absolute throughput the design is comparable to a single
Antminer L3++ chip and roughly 1/170 of an L9. The only metric on
which it might be competitive is energy efficiency, and that depends
on the 25 W power estimate -- which design-review-notes #20 calls out
as likely 4-10x too low. If actual power is 100-300 W, the chip is
worse than the L7 on J/GH and probably worse than the L3++.
