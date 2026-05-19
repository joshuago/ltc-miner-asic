# LTC-3N Design Review Notes

## FIXED

The following issues have been addressed:

| #  | File | Issue | Resolution |
|----|------|-------|-------------|
| 1  | `sha256_pipelined.sv:108-115` | state_in OOB indexing (`31*N` -> `32*N`) | Fixed: changed stride to 32 |
| 2  | `sha256_pipelined.sv:188` | W[16..31] never computed (`r >= 16` guard) | Fixed: removed guard; W computed from r=0 |
| 3  | `scrypt_core.sv:64` | FSM encoding 4 bits for 18 states | Fixed: widened to `logic [4:0]` (31 states used) |
| 4  | `scrypt_core.sv` | SHA-256 multi-block chaining broken | Fixed: FSM rewritten to wait for `sha_done` between blocks |
| 5  | `scrypt_core.sv` | Final PBKDF2 missing outer HMAC | Fixed: full inner+outer HMAC for final PBKDF2 |
| 6  | `scrypt_core.sv` | Nonce iteration skips prehash | Fixed: NEXT_NONCE -> FSM_PRE_B0 to recompute K' |
| 7  | `romix.sv:60-61` | integerify extracted from wrong half (B[0] vs B[1]) | Re-fixed: see #21 below; correct bits depend on byte order convention |
| 8  | `scrypt_core.sv` | Malformed SHA-256 padding | Partial: see #22 below for the remaining FSM_IN_B1_W misplacement |
| 11 | `scratchpad_dpram.sv` | Named "dpram" but single-port | Fixed: renamed to `scratchpad_spram.sv` |
| 16 | `pll.sv:33-35` | `localparam real` outside `ifdef SIMULATION` | Fixed: moved inside `ifdef` block |
| 21 | `scrypt_core.sv`, `blockmix.sv`, `romix.sv` | PBKDF2 storage order incompatible with BlockMix half-assignment (chip computed non-standard scrypt) | Fixed: pbkdf2_B / romix_in / romix_out now use salsa20-native byte order; SHA<->salsa conversion done at PBKDF2 boundaries; BlockMix swapped to use LOW=B[0], HIGH=B[1]; integerify now reads x_val[521:512] |
| 22 | `scrypt_core.sv:204-210` | SHA-256 padding bit misplaced in FSM_IN_B1_W (pad byte at byte 55 instead of byte 20) | Fixed: swapped `287'd0` and `1'b1` ordering |
| 23 | `romix.sv` (phase 2) | SRAM read race: bmix_in consumed stale sram_rdata one cycle before SRAM produced new data; caused `sim-scrypt-core` to hang | Fixed: inserted `ST_P2_READ` wait state between read issue and BlockMix start. Adds 1 cycle per phase-2 iteration (~2% slowdown). |
| 24 | `pll.sv:7`, `scrypt_top.sv:53` | `parameter VCO_FREQ = 4_800_000_000` overflowed 32-bit literal default (silently truncated to 505,032,704) | Fixed: declared as `parameter longint`, instantiated with `64'd` literals |
| 27 | `uart.sv` | All FSM counters ran on `clk` (= 100 MHz sys_clk) instead of `baud_clk`; UART transmitted at ~6.25 Mbaud, not 115200. RX sample point was also ~9 baud-ticks early. | Fixed: 3-FF synchroniser on `baud_clk` produces `baud_tick`; all counter advances are gated on `baud_tick`. RX FSM rewritten to wait one full bit-period after start-bit edge before sampling mid-bit. Verified end-to-end with new `sim-uart` loopback target (16-byte round trip). |
| 28 | `scrypt_top.sv:160` | UART RX checksum check parsed as `packet_cksum ^ (uart_rx_data == 8'h00)` due to `==` binding tighter than `^`; valid jobs rejected. | Fixed: parenthesised as `(packet_cksum ^ uart_rx_data) == 8'h00`. |
| 29 | `scrypt_top.sv:385,388` | UART TX hash slice started at bit 255 (skipping the first 4 bytes of the hash) and the "nonce" slice started at bit 287 (= hash MSBs). Output was unparseable. | Fixed: hash indexed from bit 287 walking down; nonce indexed from bit 0 walking up so the LSB byte is transmitted first (LE, per protocol spec). |
| 30 | `scrypt_top.sv` (TX_PAYLOAD, TX_PREAMBLE) | `uart_tx_valid` asserted unconditionally at the top of each state's case, so the transition cycle (no payload byte) transmitted a phantom duplicate of the last byte. | Fixed: `uart_tx_valid <= 1'b1` moved inside the branches that produce a byte; the transition branch leaves it at the default of 0. |
| 31 | `scrypt_top.sv:400` | TX_CHECKSUM transmitted `tx_byte_cnt` (i.e. 0) as a placeholder; the host could not validate any response. | Fixed: added `tx_cksum` register; each transmitted byte (magic, cmd, hash, nonce) is XOR-accumulated into it; TX_CHECKSUM transmits the accumulated value. |
| 26 | `scrypt_core.sv:99` | `sha_hash < target_reg` was a BE compare; Bitcoin/Litecoin compare hash and target as LE 256-bit integers. The host would have had to pre-byteswap target. | Fixed: both operands are byte-reversed (`{<<8{...}}`) before the comparison so the host can submit target in its natural byte order. |
| 33 | `scrypt_core.sv:352` | `nonce_range == 0` mined 65,536 nonces (`nonce_left == 1` check never fired after underflow). | Fixed: `FSM_IDLE` rejects jobs with `nonce_range == 16'd0`. |
| 12 | `scrypt_top.sv`, `nonce_manager.sv` | FIFO `wr_en` was asserted whenever the nonce_manager reported a result; a full FIFO silently dropped shares. | Fixed: `nonce_manager` takes `result_fifo_full` as input and holds the latched found events until the FIFO has space; `scrypt_top` additionally AND-gates `wr_en` with `!full` as belt-and-braces. |
| 34 | `nonce_manager.sv` | `core_found[i]` is a one-cycle pulse; the combinational priority arbiter would lose the lower-priority one if two cores asserted on the same cycle. | Fixed: per-core `core_found_latch` SR register set by `core_found[i]` and cleared by the arbiter (with FIFO-full back-pressure). Arbitrates over latches, so concurrent finds drain over multiple cycles. |
| 35 | `scrypt_top.sv` (parser FSM and CDC) | `header_core`/`target_core` were updated one sys_clk cycle *after* `new_job` was asserted, so the synchronised pulse in core_clk arrived ~10 ns before the data was valid. The nonce_manager read combinationally from sys_clk-domain registers without a handshake. | Fixed: parser writes `header_sys`/`target_sys` in state 2 and asserts `new_job` in a new state 3 so the data is stable >= 1 sys_clk cycle before the pulse rises. A core_clk register (`header_core`/`target_core`) samples `header_sys`/`target_sys` on `new_job_pulse`, decoupling all downstream consumers from sys_clk-domain changes. Reset synchronisers added to the sync chain. |
| -- | `scrypt_core.sv` | HMAC key padding swapped (key in wrong half of ipad/opad block) | Fixed: `{sha_hash ^ ipad, ipad}` ordering corrected |
| -- | `scrypt_core.sv` | Syntax: `64'd(144*8)` -> `64'(144*8)` | Fixed: expression literal syntax |
| -- | `sha256_pipelined.sv:144` | Missing `genvar r` declaration | Fixed: added `genvar r` |
| -- | `uart.sv` | `tx_bit_cnt` / `rx_bit_cnt` declared as 4 bits but indexed an 8-bit shift register (Verilator WIDTHTRUNC warning). | Fixed: widths reduced to 3 bits. |

---

## UNRESOLVED

Outstanding action items have moved to [`../TODO.md`](../TODO.md).
That document carries the same item numbers used above, grouped by
category (verification, latent correctness, performance, physical
design, cleanup, documentation) and annotated with priority.

Open items as of this writing: **#9, #10, #13, #14, #15, #17, #18,
#19, #20, #25, #32, #36, #37, #38, #39, #40**.
