// Shared fixed-point helpers (Q1.14) --------------------------------------
`ifndef COMPLEX_OPS_VH
`define COMPLEX_OPS_VH
`include "qml_defs.vh"

// signed Q1.14 * Q1.14 -> Q1.14 with rounding + saturation
function signed [`DW-1:0] qmul;
    input signed [`DW-1:0] a;
    input signed [`DW-1:0] b;
    reg   signed [2*`DW-1:0] p;
    reg   signed [2*`DW-1:0] r;
    begin
        p = a * b;                                   // Q2.28
        r = (p + (1 <<< (`QF-1))) >>> `QF;           // round -> Q?.14
        if (r >  ((1<<<(`DW-1))-1)) qmul =  ((1<<<(`DW-1))-1);
        else if (r < -(1<<<(`DW-1))) qmul = -(1<<<(`DW-1));
        else qmul = r[`DW-1:0];
    end
endfunction
`endif
