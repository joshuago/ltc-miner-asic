// ROMix - Scrypt memory-hard mixing function (N=1024, r=1, p=1)
// Phase 1: V[i]=X, X=BlockMix(X) for 1024 iterations
// Phase 2: X=BlockMix(X ^ V[integerify(X)&0x3FF]) for 1024 iterations

module romix (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [1023:0] data_in,
    output logic         done,
    output logic [1023:0] data_out
);

    localparam N_ITER = 1024;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_P1_WRITE,       // Write X to V[iter]. Also start BlockMix.
        ST_P1_WAIT,        // Wait for BlockMix to complete.
        ST_P1_TO_P2,       // Transition: phase 1 complete, start phase 2 read.
        ST_P2_READ,        // Issue SRAM read for V[j].
        ST_P2_START,       // SRAM read complete. Start BlockMix(X^V[j]).
        ST_P2_WAIT,        // Wait for BlockMix in phase 2.
        ST_DONE            // Output ready.
    } state_t;

    state_t st;

    scratchpad_spram u_sram (
        .clk   (clk),
        .rst_n (rst_n),
        .cs    (sram_cs),
        .we    (sram_we),
        .addr  (sram_addr),
        .wdata (sram_wdata),
        .rdata (sram_rdata)
    );

    blockmix u_blockmix (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (bmix_start),
        .data_in  (bmix_in),
        .done     (bmix_done),
        .data_out (bmix_out)
    );

    logic         sram_cs, sram_we;
    logic [9:0]   sram_addr;
    logic [1023:0] sram_wdata, sram_rdata;

    logic         bmix_start, bmix_done;
    logic [1023:0] bmix_in, bmix_out;

    logic [9:0]    iter;
    logic [1023:0] x_val;

    // integerify(X): low 10 bits of the first 32-bit word of B[1]
    // B[1] occupies bits [511:0] of the 1024-bit value.
    // Within B[1], word 0 is at bits [31:0]. Low 10 bits = bits [9:0].
    wire [9:0] j_curr = x_val[9:0];               // j from current x_val
    wire [9:0] j_next = bmix_out[9:0];             // j from bmix_out

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            iter      <= '0;
            x_val     <= '0;
            sram_cs   <= 1'b0;
            sram_we   <= 1'b0;
            sram_addr <= '0;
            sram_wdata <= '0;
            bmix_start <= 1'b0;
            bmix_in   <= '0;
            done      <= 1'b0;
            data_out  <= '0;
        end else begin
            sram_cs    <= 1'b0;
            bmix_start <= 1'b0;
            done       <= 1'b0;

            case (st)
                ST_IDLE: begin
                    if (start) begin
                        x_val     <= data_in;
                        iter      <= 10'd0;
                        st        <= ST_P1_WRITE;
                    end
                end

                ST_P1_WRITE: begin
                    sram_cs    <= 1'b1;
                    sram_we    <= 1'b1;
                    sram_addr  <= iter;
                    sram_wdata <= x_val;
                    bmix_start <= 1'b1;
                    bmix_in    <= x_val;
                    st <= ST_P1_WAIT;
                end

                ST_P1_WAIT: begin
                    if (bmix_done) begin
                        x_val <= bmix_out;
                        if (iter == 10'(N_ITER - 1)) begin
                            st        <= ST_P1_TO_P2;
                        end else begin
                            iter <= iter + 10'd1;
                            st   <= ST_P1_WRITE;
                        end
                    end
                end

                ST_P1_TO_P2: begin
                    // j_curr works here because x_val was just updated
                    // from the last phase 1 BlockMix at the start of this cycle
                    sram_cs   <= 1'b1;
                    sram_we   <= 1'b0;
                    sram_addr <= j_curr;
                    iter      <= 10'd0;
                    st        <= ST_P2_START;
                end

                ST_P2_START: begin
                    bmix_start <= 1'b1;
                    bmix_in    <= x_val ^ sram_rdata;
                    st <= ST_P2_WAIT;
                end

                ST_P2_WAIT: begin
                    if (bmix_done) begin
                        x_val <= bmix_out;
                        if (iter == 10'(N_ITER - 1)) begin
                            st <= ST_DONE;
                        end else begin
                            iter <= iter + 10'd1;
                            // Use j_next (j from the new X = bmix_out)
                            // j_next is combinational from bmix_out
                            sram_cs   <= 1'b1;
                            sram_we   <= 1'b0;
                            sram_addr <= j_next;
                            st        <= ST_P2_START;
                        end
                    end
                end

                ST_DONE: begin
                    data_out <= x_val;
                    done     <= 1'b1;
                    st       <= ST_IDLE;
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
