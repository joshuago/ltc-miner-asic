// BlockMix(r=1) for Scrypt
// Input:  128 bytes (B0 || B1), each 64 bytes -> 16 x 32-bit words.
// Output: 128 bytes (Y0 || Y1).
//
// Byte order convention (salsa20-native):
//   - byte 0 of the 128-byte block is at data_in[7:0]
//   - byte 127 is at data_in[1023:1016]
//   - within each 32-bit word, bytes are LE (matching salsa20)
//   => B[0] (bytes 0..63)   occupies bits [511:0]   (LOW half)
//      B[1] (bytes 64..127) occupies bits [1023:512] (HIGH half)
//
// Algorithm (per RFC 7914):
//   X    = B[2r-1] = B[1]
//   Y[0] = Salsa20/8(X ^ B[0])
//   Y[1] = Salsa20/8(Y[0] ^ B[1])
//   output = Y[0] || Y[1]   (Y[0] in LOW half, Y[1] in HIGH half)
//
// Timing: 2*(SALSA_LATENCY) + 2 cycles overhead ~ 20 cycles @ 9-cycle Salsa20.

module blockmix (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [1023:0] data_in,          // 32 x 32-bit words = 128 bytes
    output logic         done,
    output logic [1023:0] data_out
);

    typedef enum logic [1:0] {
        IDLE        = 2'd0,
        PHASE_1     = 2'd1,   // waiting for first Salsa20 result
        PHASE_2     = 2'd2,   // waiting for second Salsa20 result
        OUTPUT      = 2'd3
    } state_t;

    state_t state;

    salsa20_8 u_salsa (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (salsa_req),
        .data_in   (salsa_input),
        .valid_out (salsa_done),
        .data_out  (salsa_result)
    );

    logic         salsa_req;
    logic [511:0] salsa_input;
    logic         salsa_done;
    logic [511:0] salsa_result;

    logic [511:0]  input_reg;
    logic [511:0]  y0_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            input_reg  <= '0;
            y0_reg     <= '0;
            salsa_req  <= 1'b0;
            salsa_input <= '0;
            done       <= 1'b0;
            data_out   <= '0;
        end else begin
            salsa_req <= 1'b0;
            done      <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        // Latch B[1] (HIGH half) for use as the second salsa input.
                        input_reg   <= data_in[1023:512];
                        salsa_req   <= 1'b1;
                        // First salsa input: X ^ B[0] where X = B[1].
                        // (XOR is commutative; this is the same value as before.)
                        salsa_input <= data_in[1023:512] ^ data_in[511:0];
                        state       <= PHASE_1;
                    end
                end

                PHASE_1: begin
                    if (salsa_done) begin
                        y0_reg      <= salsa_result;                // Y[0]
                        salsa_req   <= 1'b1;
                        salsa_input <= salsa_result ^ input_reg;    // Y[0] ^ B[1]
                        state       <= PHASE_2;
                    end
                end

                PHASE_2: begin
                    if (salsa_done) begin
                        done     <= 1'b1;
                        // Y[0] in LOW half, Y[1] in HIGH half (byte-stream order).
                        data_out <= {salsa_result, y0_reg};         // {Y[1], Y[0]}
                        state    <= OUTPUT;
                    end
                end

                OUTPUT: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
