// Dual-clock asynchronous FIFO
// Write domain (wr_clk) → Read domain (rd_clk)
// Depth must be a power of 2

module sync_fifo #(
    parameter DWIDTH = 32,
    parameter DEPTH  = 16,
    parameter AWIDTH = $clog2(DEPTH)
) (
    input  logic               wr_clk,
    input  logic               wr_rst_n,
    input  logic               wr_en,
    input  logic [DWIDTH-1:0]  wr_data,
    output logic               full,

    input  logic               rd_clk,
    input  logic               rd_rst_n,
    input  logic               rd_en,
    output logic [DWIDTH-1:0]  rd_data,
    output logic               empty
);

    logic [DWIDTH-1:0] mem [0:DEPTH-1];
    logic [AWIDTH:0]   wr_ptr, wr_ptr_gray, wr_ptr_gray_sync1, wr_ptr_gray_sync2;
    logic [AWIDTH:0]   rd_ptr, rd_ptr_gray, rd_ptr_gray_sync1, rd_ptr_gray_sync2;

    // Write pointer
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr <= '0;
        end else if (wr_en && !full) begin
            mem[wr_ptr[AWIDTH-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // Write pointer to Gray code
    assign wr_ptr_gray = wr_ptr ^ (wr_ptr >> 1);

    // Sync write pointer Gray to read domain
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    // Read pointer
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr <= '0;
        end else if (rd_en && !empty) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // Read data
    assign rd_data = mem[rd_ptr[AWIDTH-1:0]];

    // Read pointer to Gray code
    assign rd_ptr_gray = rd_ptr ^ (rd_ptr >> 1);

    // Sync read pointer Gray to write domain
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= '0;
            rd_ptr_gray_sync2 <= '0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    // Gray code to binary conversion function
    function automatic [AWIDTH:0] gray_to_bin;
        input [AWIDTH:0] gray;
        gray_to_bin = gray;
        for (int i = AWIDTH-1; i >= 0; i--)
            gray_to_bin[i] = gray_to_bin[i+1] ^ gray[i];
    endfunction

    wire [AWIDTH:0] wr_ptr_sync_bin = gray_to_bin(wr_ptr_gray_sync2);
    wire [AWIDTH:0] rd_ptr_sync_bin = gray_to_bin(rd_ptr_gray_sync2);

    // Full: write pointer catches up to synchronized read pointer
    assign full  = (wr_ptr[AWIDTH] != rd_ptr_sync_bin[AWIDTH]) &&
                   (wr_ptr[AWIDTH-1:0] == rd_ptr_sync_bin[AWIDTH-1:0]);

    // Empty: read pointer catches up to synchronized write pointer
    assign empty = (rd_ptr == wr_ptr_sync_bin);

endmodule
