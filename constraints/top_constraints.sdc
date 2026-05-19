# ─────────────────────────────────────────────────────────────
#  LTC-3N Timing Constraints - TSMC N3 (3nm)
#  Core clock: 1.2 GHz (833.33 ps period)
# ─────────────────────────────────────────────────────────────

# ── Clock Definitions ──

create_clock -name core_clk -period 0.833 [get_ports {xtal_in}]
# PLL generates core_clk at 1.2 GHz
create_generated_clock -name core_clk_gen -source [get_ports xtal_in] \
  -divide_by 1 -multiply_by 48 [get_pins {u_pll/core_clk}]

# System clock: 100 MHz (derived from PLL)
create_generated_clock -name sys_clk -source [get_ports xtal_in] \
  -divide_by 1 -multiply_by 4 [get_pins {u_pll/sys_clk}]

# UART baud clock: ~1.8432 MHz
create_generated_clock -name uart_clk -source [get_ports xtal_in] \
  -divide_by 2600 -multiply_by 192 [get_pins {u_pll/uart_clk}]

# ── Clock Groups (CDC) ──

set_clock_groups -asynchronous \
  -group {core_clk core_clk_gen} \
  -group {sys_clk} \
  -group {uart_clk}

# ── Input Delays (UART RX, JTAG) ──

set_input_delay -clock sys_clk -max 5.0 [get_ports {uart_rx}]
set_input_delay -clock sys_clk -min 1.0 [get_ports {uart_rx}]

set_input_delay -clock sys_clk -max 5.0 [get_ports {jtag_tck jtag_tms jtag_tdi}]
set_input_delay -clock sys_clk -min 1.0 [get_ports {jtag_tck jtag_tms jtag_tdi}]

# ── Output Delays (UART TX, JTAG TDO, LEDs) ──

set_output_delay -clock sys_clk -max 5.0 [get_ports {uart_tx jtag_tdo}]
set_output_delay -clock sys_clk -min 1.0 [get_ports {uart_tx jtag_tdo}]

set_output_delay -clock sys_clk -max 5.0 [get_ports {led_green led_red}]
set_output_delay -clock sys_clk -min 1.0 [get_ports {led_green led_red}]

# ── False Paths ──

# Asynchronous reset
set_false_path -from [get_ports {rst_ext_n}] -to [all_registers]

# CDC synchronization paths
set_false_path -from [get_cells {u_result_fifo/*sync*}] \
               -to   [get_cells {u_result_fifo/*sync*}]

# ── Critical Path Timing (Salsa20/8 Quarter-Round) ──

# The Salsa20 quarter-round critical path is:
#   32-bit add → rotate → XOR → 32-bit add → rotate → XOR → 
#   32-bit add → rotate → XOR → 32-bit add → rotate → XOR
#
# At 1.2 GHz (833ps), each quarter-round must complete in one cycle.
# With TSMC N3 standard cells:
#   - 32-bit adder: ~120ps (Carry Look-Ahead, ULVT cells)
#   - XOR: ~8ps
#   - Rotation: free (wire routing)
#   Total per step: ~128ps × 4 = ~512ps  (with ~321ps slack)
#
# 4 quarter-rounds in parallel per round → 4 × 512ps = still 512ps (parallel)
# 8 pipeline stages for 8 rounds → each stage: 512ps < 833ps ✓

# ── SRAM Timing ──
# TSMC N3 HD SRAM macro: tCK_min = 600ps @ 0.7V (worst case)
# Our clock: 833ps, well within spec

# ── Multi-cycle Paths ──

# BlockMix state machine: 20-cycle latency, non-critical
set_multicycle_path -setup 20 -from [get_cells {u_blockmix/*}] \
                                 -to   [get_cells {u_blockmix/*}]
set_multicycle_path -hold  19 -from [get_cells {u_blockmix/*}] \
                                 -to   [get_cells {u_blockmix/*}]

# ROMix scratchpad access: 1 cycle, critical
# SRAM read after write: need 1 cycle gap
# Handled by FSM state transitions

# ── Clock Uncertainty ──

set_clock_uncertainty -setup 0.050 [get_clocks {core_clk_gen}]
set_clock_uncertainty -hold  0.020 [get_clocks {core_clk_gen}]

# PLL jitter estimate for TSMC N3: 30ps RMS
# Combined uncertainty: 50ps setup, 20ps hold

# ── Derates (OCV) ──
# TSMC N3 AOCV derates (advanced on-chip variation)

set_timing_derate -early 0.92 -cell_delay
set_timing_derate -late  1.08 -cell_delay

# ── Operating Conditions ──

# Slow corner: 0.63V, 125°C, SSGNP (slow-slow global N-pmos)
# Typical:   0.70V,  85°C, TT
# Fast:      0.77V, -40°C, FFGNP

set_operating_conditions -analysis_type on_chip_variation \
  -library {tcbn03lvt_ssgnp0p63v125c.db}

# ── Area Constraints ──

# Die size: 21mm × 20mm = 420 mm² (target)
# Core utilization: 75% (SRAM dominated)
# SRAM: 512 MB (4096 cores × 128KB) = ~198 mm² with periphery
# Logic: ~100 mm²
# Routing / PLL / I/O overhead: ~122 mm²

set_max_area 420000000  ;# 420 mm² in μm²? Actually depends on lib units

# ── Power Constraints ──

# Estimated: 25W total @ 0.7V, 1.2 GHz
# Per-core: ~4mW (SRAM + Salsa20 + SHA256 + control)
# Leakage at 125C: ~3W

set_max_dynamic_power 25 [current_design]
set_max_leakage_power 5 [current_design]

# ── Fanout Limits ──

set_max_fanout 24 [current_design]
set_max_transition 0.100 [current_design]
set_max_capacitance 0.050 [current_design]
