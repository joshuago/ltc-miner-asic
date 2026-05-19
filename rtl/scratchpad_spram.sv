// Scratchpad - 128 KB banked SRAM (8 banks × 1024 entries × 128-bit)
// 1024-bit wide read/write interface for single-cycle V[i] access
// TSMC N3 HD SRAM macros: 8 instances of 1024x128 single-port SRAM

module scratchpad_spram (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        cs,
    input  logic        we,
    input  logic [9:0]  addr,             // 10-bit address: 0..1023
    input  logic [1023:0] wdata,
    output logic [1023:0] rdata
);

    localparam N_BANKS  = 8;
    localparam BANK_DW  = 128;
    localparam DEPTH    = 1024;

    genvar b;
    generate
        for (b = 0; b < N_BANKS; b++) begin : gen_bank
            logic [BANK_DW-1:0] mem [0:DEPTH-1];
            logic [BANK_DW-1:0] rdata_reg;

            always_ff @(posedge clk) begin
                if (cs && we)
                    mem[addr] <= wdata[b*BANK_DW +: BANK_DW];
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    rdata_reg <= '0;
                else if (cs && !we)
                    rdata_reg <= mem[addr];
            end

            assign rdata[b*BANK_DW +: BANK_DW] = rdata_reg;
        end
    endgenerate

endmodule
