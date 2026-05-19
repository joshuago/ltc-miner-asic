// Salsa20/8 - 8-round pipelined core
// 8 pipeline stages, 1 round per stage (alternating column/row)
// Feedforward addition at output: result = state_after_8_rounds + original_input
// Throughput: 1 output per cycle after pipeline fill (9 cycle latency)

module salsa20_8 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [511:0] data_in,        // 16 x 32-bit words, little-endian
    output logic        valid_out,
    output logic [511:0] data_out
);

    localparam N_ROUNDS = 8;
    localparam STAGE_DW = 512;

    logic [N_ROUNDS:0][STAGE_DW-1:0] state_pipe;
    logic [N_ROUNDS:0][STAGE_DW-1:0] orig_pipe;
    logic [N_ROUNDS:0] valid_pipe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_pipe[0] <= '0;
            orig_pipe[0]  <= '0;
            valid_pipe[0] <= 1'b0;
        end else begin
            valid_pipe[0] <= valid_in;
            if (valid_in) begin
                state_pipe[0] <= data_in;
                orig_pipe[0]  <= data_in;
            end
        end
    end

    genvar r;
    generate
        for (r = 0; r < N_ROUNDS; r++) begin : gen_round
            localparam integer NEXT = r + 1;
            logic [15:0][31:0] st_in, st_out;
            assign st_in = state_pipe[r];

            wire [31:0] qr_a_in  [0:3];
            wire [31:0] qr_b_in  [0:3];
            wire [31:0] qr_c_in  [0:3];
            wire [31:0] qr_d_in  [0:3];
            wire [31:0] qr_a_out [0:3];
            wire [31:0] qr_b_out [0:3];
            wire [31:0] qr_c_out [0:3];
            wire [31:0] qr_d_out [0:3];

            if (r % 2 == 0) begin : col_round_inputs
                assign qr_a_in[0] = st_in[ 0]; assign qr_b_in[0] = st_in[ 4];
                assign qr_c_in[0] = st_in[ 8]; assign qr_d_in[0] = st_in[12];
                assign qr_a_in[1] = st_in[ 5]; assign qr_b_in[1] = st_in[ 9];
                assign qr_c_in[1] = st_in[13]; assign qr_d_in[1] = st_in[ 1];
                assign qr_a_in[2] = st_in[10]; assign qr_b_in[2] = st_in[14];
                assign qr_c_in[2] = st_in[ 2]; assign qr_d_in[2] = st_in[ 6];
                assign qr_a_in[3] = st_in[15]; assign qr_b_in[3] = st_in[ 3];
                assign qr_c_in[3] = st_in[ 7]; assign qr_d_in[3] = st_in[11];

                assign st_out[ 0] = qr_a_out[0]; assign st_out[ 4] = qr_b_out[0];
                assign st_out[ 8] = qr_c_out[0]; assign st_out[12] = qr_d_out[0];
                assign st_out[ 5] = qr_a_out[1]; assign st_out[ 9] = qr_b_out[1];
                assign st_out[13] = qr_c_out[1]; assign st_out[ 1] = qr_d_out[1];
                assign st_out[10] = qr_a_out[2]; assign st_out[14] = qr_b_out[2];
                assign st_out[ 2] = qr_c_out[2]; assign st_out[ 6] = qr_d_out[2];
                assign st_out[15] = qr_a_out[3]; assign st_out[ 3] = qr_b_out[3];
                assign st_out[ 7] = qr_c_out[3]; assign st_out[11] = qr_d_out[3];
            end else begin : row_round_inputs
                assign qr_a_in[0] = st_in[ 0]; assign qr_b_in[0] = st_in[ 1];
                assign qr_c_in[0] = st_in[ 2]; assign qr_d_in[0] = st_in[ 3];
                assign qr_a_in[1] = st_in[ 5]; assign qr_b_in[1] = st_in[ 6];
                assign qr_c_in[1] = st_in[ 7]; assign qr_d_in[1] = st_in[ 4];
                assign qr_a_in[2] = st_in[10]; assign qr_b_in[2] = st_in[11];
                assign qr_c_in[2] = st_in[ 8]; assign qr_d_in[2] = st_in[ 9];
                assign qr_a_in[3] = st_in[15]; assign qr_b_in[3] = st_in[12];
                assign qr_c_in[3] = st_in[13]; assign qr_d_in[3] = st_in[14];

                assign st_out[ 0] = qr_a_out[0]; assign st_out[ 1] = qr_b_out[0];
                assign st_out[ 2] = qr_c_out[0]; assign st_out[ 3] = qr_d_out[0];
                assign st_out[ 5] = qr_a_out[1]; assign st_out[ 6] = qr_b_out[1];
                assign st_out[ 7] = qr_c_out[1]; assign st_out[ 4] = qr_d_out[1];
                assign st_out[10] = qr_a_out[2]; assign st_out[11] = qr_b_out[2];
                assign st_out[ 8] = qr_c_out[2]; assign st_out[ 9] = qr_d_out[2];
                assign st_out[15] = qr_a_out[3]; assign st_out[12] = qr_b_out[3];
                assign st_out[13] = qr_c_out[3]; assign st_out[14] = qr_d_out[3];
            end

            genvar q;
            for (q = 0; q < 4; q++) begin : gen_qr
                salsa20_quarter_round u_qr (
                    .a_in (qr_a_in [q]),
                    .b_in (qr_b_in [q]),
                    .c_in (qr_c_in [q]),
                    .d_in (qr_d_in [q]),
                    .a_out(qr_a_out[q]),
                    .b_out(qr_b_out[q]),
                    .c_out(qr_c_out[q]),
                    .d_out(qr_d_out[q])
                );
            end

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    state_pipe[NEXT] <= '0;
                    orig_pipe[NEXT]  <= '0;
                    valid_pipe[NEXT] <= 1'b0;
                end else begin
                    state_pipe[NEXT] <= st_out;
                    orig_pipe[NEXT]  <= orig_pipe[r];
                    valid_pipe[NEXT] <= valid_pipe[r];
                end
            end
        end
    endgenerate

    // Feedforward addition: result[i] = state_after_8_rounds[i] + original_input[i]
    logic [15:0][31:0] state_final, orig_final, result;
    assign state_final = state_pipe[N_ROUNDS];
    assign orig_final  = orig_pipe[N_ROUNDS];

    genvar w;
    generate
        for (w = 0; w < 16; w++) begin : gen_ff
            assign result[w] = state_final[w] + orig_final[w];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out  <= '0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_pipe[N_ROUNDS];
            data_out  <= result;
        end
    end

endmodule
