// Salsa20 Quarter-Round: fully combinational, 1 cycle
// QR(a,b,c,d):
//   b ^= rotl(a + d,  7)
//   c ^= rotl(b + a,  9)
//   d ^= rotl(c + b, 13)
//   a ^= rotl(d + c, 18)

module salsa20_quarter_round (
    input  logic [31:0] a_in, b_in, c_in, d_in,
    output logic [31:0] a_out, b_out, c_out, d_out
);

    logic [31:0] a0, b0, c0, d0;

    logic [31:0] sum0, sum1, sum2, sum3;

    assign sum0 = a_in + d_in;
    assign sum1 = b0   + a_in;
    assign sum2 = c0   + b0;
    assign sum3 = d0   + c0;

    assign b0 = b_in ^ {sum0[24:0], sum0[31:25]};  // rotl by 7
    assign c0 = c_in ^ {sum1[22:0], sum1[31:23]};  // rotl by 9
    assign d0 = d_in ^ {sum2[18:0], sum2[31:19]};  // rotl by 13
    assign a0 = a_in ^ {sum3[13:0], sum3[31:14]};  // rotl by 18

    assign a_out = a0;
    assign b_out = b0;
    assign c_out = c0;
    assign d_out = d0;

endmodule
