// PLL Wrapper for TSMC N3
// Generates: core_clk (1.2 GHz), sys_clk (100 MHz), uart_clk (1.8432 MHz)
// From 25 MHz reference crystal

module pll #(
    parameter REF_FREQ  = 25_000_000,
    parameter VCO_FREQ  = 4_800_000_000,
    parameter OUT_DIV   = 4,           // VCO/4 = 1.2 GHz
    parameter SYS_DIV   = 48,          // VCO/48 = 100 MHz
    parameter UART_DIV  = 2600         // VCO/2600 ≈ 1.846 MHz (close to 1.8432)
) (
    input  logic clk_ref,
    input  logic rst_n,
    output logic core_clk,
    output logic sys_clk,
    output logic uart_clk,
    output logic locked
);

    // In synthesis: instantiate TSMC N3 PLL hard macro
    // TSMC_N3_PLL #(
    //     .REFERENCE_FREQUENCY(REF_FREQ),
    //     .OUTPUT_FREQUENCY0(VCO_FREQ/OUT_DIV),
    //     .OUTPUT_FREQUENCY1(VCO_FREQ/SYS_DIV),
    //     .OUTPUT_FREQUENCY2(VCO_FREQ/UART_DIV)
    // ) u_pll_macro (
    //     .CLKREF(clk_ref), .RSTB(rst_n),
    //     .CLKOUT0(core_clk), .CLKOUT1(sys_clk),
    //     .CLKOUT2(uart_clk), .LOCK(locked)
    // );

    `ifdef SIMULATION
        localparam real CORE_PERIOD_PS = 1_000_000_000.0 / (VCO_FREQ / OUT_DIV);
        localparam real SYS_PERIOD_PS  = 1_000_000_000.0 / (VCO_FREQ / SYS_DIV);
        localparam real UART_PERIOD_PS = 1_000_000_000.0 / (VCO_FREQ / UART_DIV);

        logic lock_dly;
        initial begin
            core_clk = 1'b0;
            sys_clk  = 1'b0;
            uart_clk = 1'b0;
            locked   = 1'b0;
            #100000;  // 100us lock time
            locked   = 1'b1;
        end

        always #(CORE_PERIOD_PS/2) if (locked) core_clk = ~core_clk;
        always #(SYS_PERIOD_PS/2)  if (locked) sys_clk  = ~sys_clk;
        always #(UART_PERIOD_PS/2) if (locked) uart_clk = ~uart_clk;
    `else
        assign core_clk = 1'b0;
        assign sys_clk  = 1'b0;
        assign uart_clk = 1'b0;
        assign locked   = 1'b0;
    `endif

endmodule
