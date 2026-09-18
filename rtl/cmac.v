// ============================================================================
//  cmac.v  -  Complex multiply-accumulate (combinational)
//  Computes  out = sum_{j=0..3} M_j * A_j   for complex M_j, A_j in Q1.14,
//  with a single rounding step (no intermediate rounding) and saturation.
//  Unused terms are fed with M_j = 0.  This is the core datapath cell shared
//  by the 1-qubit butterfly (2 active terms) and the 2-qubit engine (4 terms).
// ============================================================================
`include "qml_defs.vh"

module cmac (
    input  wire signed [`DW-1:0] m0r, m0i, a0r, a0i,
    input  wire signed [`DW-1:0] m1r, m1i, a1r, a1i,
    input  wire signed [`DW-1:0] m2r, m2i, a2r, a2i,
    input  wire signed [`DW-1:0] m3r, m3i, a3r, a3i,
    output wire signed [`DW-1:0] outr,
    output wire signed [`DW-1:0] outi
);
    // products are 32-bit (Q2.28); accumulate in 40-bit to leave headroom
    wire signed [39:0] pr0 = m0r*a0r - m0i*a0i;
    wire signed [39:0] pr1 = m1r*a1r - m1i*a1i;
    wire signed [39:0] pr2 = m2r*a2r - m2i*a2i;
    wire signed [39:0] pr3 = m3r*a3r - m3i*a3i;
    wire signed [39:0] pi0 = m0r*a0i + m0i*a0r;
    wire signed [39:0] pi1 = m1r*a1i + m1i*a1r;
    wire signed [39:0] pi2 = m2r*a2i + m2i*a2r;
    wire signed [39:0] pi3 = m3r*a3i + m3i*a3r;

    wire signed [39:0] accr = pr0 + pr1 + pr2 + pr3;   // Q2.28
    wire signed [39:0] acci = pi0 + pi1 + pi2 + pi3;

    // round: add half LSB then arithmetic shift right by QF
    wire signed [39:0] rr = (accr + (40'sd1 <<< (`QF-1))) >>> `QF;  // -> Q?.14
    wire signed [39:0] ri = (acci + (40'sd1 <<< (`QF-1))) >>> `QF;

    // saturate to signed DW-bit
    localparam signed [39:0] SMAX = (40'sd1 <<< (`DW-1)) - 1;
    localparam signed [39:0] SMIN = -(40'sd1 <<< (`DW-1));
    assign outr = (rr > SMAX) ? SMAX[`DW-1:0] :
                  (rr < SMIN) ? SMIN[`DW-1:0] : rr[`DW-1:0];
    assign outi = (ri > SMAX) ? SMAX[`DW-1:0] :
                  (ri < SMIN) ? SMIN[`DW-1:0] : ri[`DW-1:0];
endmodule
