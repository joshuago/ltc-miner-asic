// SHA-256 fully pipelined core - 64 rounds, 1 round per pipeline stage
// Post-pipeline-fill throughput: 1 output per cycle (65 cycle latency)
// Input: 512-bit message block + 256-bit initial hash state
// Output: 256-bit resulting hash
// Supports back-to-back blocks (chaining input for multi-block messages)

module sha256_pipelined (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic        first_block,       // 1 = use initial H values; 0 = chain from prev output
    input  logic [511:0] block_in,          // 512-bit message block
    input  logic [255:0] state_in,          // chaining state from previous block
    output logic        valid_out,
    output logic [255:0] hash_out
);

    localparam N_ROUNDS = 64;

    // Initial hash values (SHA-256 IV)
    localparam [31:0] H0_INIT = 32'h6a09e667;
    localparam [31:0] H1_INIT = 32'hbb67ae85;
    localparam [31:0] H2_INIT = 32'h3c6ef372;
    localparam [31:0] H3_INIT = 32'ha54ff53a;
    localparam [31:0] H4_INIT = 32'h510e527f;
    localparam [31:0] H5_INIT = 32'h9b05688c;
    localparam [31:0] H6_INIT = 32'h1f83d9ab;
    localparam [31:0] H7_INIT = 32'h5be0cd19;

    // Round constants K[0..63]
    localparam [31:0] K [0:63] = '{
        32'h428a2f98, 32'h71374491, 32'hb5c0fbcf, 32'he9b5dba5,
        32'h3956c25b, 32'h59f111f1, 32'h923f82a4, 32'hab1c5ed5,
        32'hd807aa98, 32'h12835b01, 32'h243185be, 32'h550c7dc3,
        32'h72be5d74, 32'h80deb1fe, 32'h9bdc06a7, 32'hc19bf174,
        32'he49b69c1, 32'hefbe4786, 32'h0fc19dc6, 32'h240ca1cc,
        32'h2de92c6f, 32'h4a7484aa, 32'h5cb0a9dc, 32'h76f988da,
        32'h983e5152, 32'ha831c66d, 32'hb00327c8, 32'hbf597fc7,
        32'hc6e00bf3, 32'hd5a79147, 32'h06ca6351, 32'h14292967,
        32'h27b70a85, 32'h2e1b2138, 32'h4d2c6dfc, 32'h53380d13,
        32'h650a7354, 32'h766a0abb, 32'h81c2c92e, 32'h92722c85,
        32'ha2bfe8a1, 32'ha81a664b, 32'hc24b8b70, 32'hc76c51a3,
        32'hd192e819, 32'hd6990624, 32'hf40e3585, 32'h106aa070,
        32'h19a4c116, 32'h1e376c08, 32'h2748774c, 32'h34b0bcb5,
        32'h391c0cb3, 32'h4ed8aa4a, 32'h5b9cca4f, 32'h682e6ff3,
        32'h748f82ee, 32'h78a5636f, 32'h84c87814, 32'h8cc70208,
        32'h90befffa, 32'ha4506ceb, 32'hbef9a3f7, 32'hc67178f2
    };

    // Function declarations
    function automatic [31:0] ROTR;
        input [31:0] x;
        input [4:0]  n;
        ROTR = (x >> n) | (x << (32 - n));
    endfunction

    function automatic [31:0] CH;
        input [31:0] x, y, z;
        CH = (x & y) ^ (~x & z);
    endfunction

    function automatic [31:0] MAJ;
        input [31:0] x, y, z;
        MAJ = (x & y) ^ (x & z) ^ (y & z);
    endfunction

    function automatic [31:0] SUM0;
        input [31:0] x;
        SUM0 = ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22);
    endfunction

    function automatic [31:0] SUM1;
        input [31:0] x;
        SUM1 = ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25);
    endfunction

    function automatic [31:0] sigma0;
        input [31:0] x;
        sigma0 = ROTR(x, 7) ^ ROTR(x, 18) ^ (x >> 3);
    endfunction

    function automatic [31:0] sigma1;
        input [31:0] x;
        sigma1 = ROTR(x, 17) ^ ROTR(x, 19) ^ (x >> 10);
    endfunction

    // Message expansion pipeline - compute W[t] for t=0..63
    wire [31:0] message_words [0:15];
    genvar i;
    generate
        for (i = 0; i < 16; i++) begin : gen_msg_words
            assign message_words[i] = block_in[(15-i)*32 +: 32];
        end
    endgenerate

    // W pipeline registers: W_stage[s][t] = W[t] as known by stage s
    // Stage s "knows" W[0..s+15] (W[s+15] computed just before stage s)
    logic [N_ROUNDS-1:0][63:0][31:0] W_pipe;
    logic [N_ROUNDS:0][31:0] A, B, C, D, E, F, G, H_state;
    logic [N_ROUNDS:0] valid_pipe;
    logic [N_ROUNDS:0][255:0] chain_state_pipe;
    logic [N_ROUNDS:0] first_block_pipe;

    // Stage -1 / input registration: compute initial state
    // Initial state comes from either IV (first_block) or chaining (state_in)
    wire [31:0] init_a, init_b, init_c, init_d, init_e, init_f, init_g, init_h;

    assign init_a = first_block ? H0_INIT : state_in[32*7 +: 32];
    assign init_b = first_block ? H1_INIT : state_in[32*6 +: 32];
    assign init_c = first_block ? H2_INIT : state_in[32*5 +: 32];
    assign init_d = first_block ? H3_INIT : state_in[32*4 +: 32];
    assign init_e = first_block ? H4_INIT : state_in[32*3 +: 32];
    assign init_f = first_block ? H5_INIT : state_in[32*2 +: 32];
    assign init_g = first_block ? H6_INIT : state_in[32*1 +: 32];
    assign init_h = first_block ? H7_INIT : state_in[32*0 +: 32];

    // Stage 0: register inputs and initialize state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            A[0] <= '0; B[0] <= '0; C[0] <= '0; D[0] <= '0;
            E[0] <= '0; F[0] <= '0; G[0] <= '0; H_state[0] <= '0;
            valid_pipe[0] <= 1'b0;
            chain_state_pipe[0] <= '0;
            first_block_pipe[0] <= 1'b0;
            for (int j = 0; j < 16; j++) W_pipe[0][j] <= '0;
        end else begin
            valid_pipe[0] <= valid_in;
            chain_state_pipe[0] <= state_in;
            first_block_pipe[0] <= first_block;
            if (valid_in) begin
                A[0] <= init_a;          B[0] <= init_b;
                C[0] <= init_c;          D[0] <= init_d;
                E[0] <= init_e;          F[0] <= init_f;
                G[0] <= init_g;          H_state[0] <= init_h;
                for (int j = 0; j < 16; j++) W_pipe[0][j] <= message_words[j];
            end
        end
    end

    // Pipeline stages 0 through 63 - one round each
    // Stage s computes round s:
    //   T1 = h + SUM1(e) + CH(e,f,g) + K[s] + W[s]
    //   T2 = SUM0(a) + MAJ(a,b,c)
    //   h'=g, g'=f, f'=e, e'=d+T1, d'=c, c'=b, b'=a, a'=T1+T2
    genvar r;
    generate
        for (r = 0; r < N_ROUNDS; r++) begin : gen_round_stage
            localparam integer NEXT = r + 1;
            logic [31:0] sum0_val, sum1_val, ch_val, maj_val, t1, t2;
            logic [31:0] w_val;

            // W value for this round: either direct from message (r<16) or computed
            if (r < 16) begin : w_direct
                assign w_val = W_pipe[r][r];
            end else begin : w_computed
                assign w_val = W_pipe[r][r-16] + W_pipe[r][r-7] +
                               sigma0(W_pipe[r][r-15]) + sigma1(W_pipe[r][r-2]);
            end

            assign sum1_val = SUM1(E[r]);
            assign ch_val   = CH(E[r], F[r], G[r]);
            assign sum0_val = SUM0(A[r]);
            assign maj_val  = MAJ(A[r], B[r], C[r])
            ;
            assign t1 = H_state[r] + sum1_val + ch_val + K[r] + w_val;
            assign t2 = sum0_val + maj_val;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    A[NEXT] <= '0; B[NEXT] <= '0; C[NEXT] <= '0;
                    D[NEXT] <= '0; E[NEXT] <= '0; F[NEXT] <= '0;
                    G[NEXT] <= '0; H_state[NEXT] <= '0;
                    valid_pipe[NEXT] <= 1'b0;
                    chain_state_pipe[NEXT] <= '0;
                    first_block_pipe[NEXT] <= 1'b0;
                    if (NEXT < N_ROUNDS)
                        for (int j = 0; j < 64; j++) W_pipe[NEXT][j] <= '0;
                end else begin
                    valid_pipe[NEXT] <= valid_pipe[r];
                    chain_state_pipe[NEXT] <= chain_state_pipe[r];
                    first_block_pipe[NEXT] <= first_block_pipe[r];
                    if (valid_pipe[r]) begin
                        A[NEXT]        <= t1 + t2;
                        B[NEXT]        <= A[r];
                        C[NEXT]        <= B[r];
                        D[NEXT]        <= C[r];
                        E[NEXT]        <= D[r] + t1;
                        F[NEXT]        <= E[r];
                        G[NEXT]        <= F[r];
                        H_state[NEXT]  <= G[r];

                        // Propagate W words and compute new W for future rounds
                        if (NEXT < N_ROUNDS) begin
                            for (int j = 0; j < 64; j++) begin
                                if (j == r + 16)
                                    W_pipe[NEXT][j] <= sigma1(W_pipe[r][j-2]) +
                                                       W_pipe[r][j-7] +
                                                       sigma0(W_pipe[r][j-15]) +
                                                       W_pipe[r][j-16];
                                else
                                    W_pipe[NEXT][j] <= W_pipe[r][j];
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // Chaining addition: H[i] = initial_H[i] + result_A[i] (for non-first blocks, use chain_state)
    wire [31:0] chain_h0, chain_h1, chain_h2, chain_h3, chain_h4, chain_h5, chain_h6, chain_h7;
    assign chain_h0 = chain_state_pipe[N_ROUNDS][32*7 +: 32];
    assign chain_h1 = chain_state_pipe[N_ROUNDS][32*6 +: 32];
    assign chain_h2 = chain_state_pipe[N_ROUNDS][32*5 +: 32];
    assign chain_h3 = chain_state_pipe[N_ROUNDS][32*4 +: 32];
    assign chain_h4 = chain_state_pipe[N_ROUNDS][32*3 +: 32];
    assign chain_h5 = chain_state_pipe[N_ROUNDS][32*2 +: 32];
    assign chain_h6 = chain_state_pipe[N_ROUNDS][32*1 +: 32];
    assign chain_h7 = chain_state_pipe[N_ROUNDS][32*0 +: 32];

    wire [31:0] result_a, result_b, result_c, result_d, result_e, result_f, result_g, result_h;
    assign result_a = A[N_ROUNDS];         assign result_b = B[N_ROUNDS];
    assign result_c = C[N_ROUNDS];         assign result_d = D[N_ROUNDS];
    assign result_e = E[N_ROUNDS];         assign result_f = F[N_ROUNDS];
    assign result_g = G[N_ROUNDS];         assign result_h = H_state[N_ROUNDS];

    // Output: for first_block, add IV; for subsequent blocks, add chain input state
    wire [31:0] out_h0, out_h1, out_h2, out_h3, out_h4, out_h5, out_h6, out_h7;
    wire first_block_out = first_block_pipe[N_ROUNDS];
    assign out_h0 = result_a + (first_block_out ? H0_INIT : chain_h0);
    assign out_h1 = result_b + (first_block_out ? H1_INIT : chain_h1);
    assign out_h2 = result_c + (first_block_out ? H2_INIT : chain_h2);
    assign out_h3 = result_d + (first_block_out ? H3_INIT : chain_h3);
    assign out_h4 = result_e + (first_block_out ? H4_INIT : chain_h4);
    assign out_h5 = result_f + (first_block_out ? H5_INIT : chain_h5);
    assign out_h6 = result_g + (first_block_out ? H6_INIT : chain_h6);
    assign out_h7 = result_h + (first_block_out ? H7_INIT : chain_h7);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hash_out  <= '0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_pipe[N_ROUNDS];
            hash_out  <= {out_h0, out_h1, out_h2, out_h3, out_h4, out_h5, out_h6, out_h7};
        end
    end

endmodule
