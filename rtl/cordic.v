// ============================================================================
//  cordic.v  -  Pipelined CORDIC (circular, rotation mode)
//  Computes cos(angle) and sin(angle) for the parameterized rotation gates.
//
//  Input : angle in Q4.12 (signed, radians, range +/-8)
//  Output: cosv, sinv in Q1.14 (signed, range [-1,1])
//
//  - Argument reduction folds the angle into [-pi/2, pi/2] (CORDIC convergence
//    range) tracking a sign flip, so RX/RY/RZ/P work for any parameter value
//    including the +/- pi/2 shifts produced by the parameter-shift rule.
//  - 16 rotation stages, 32-bit internal datapath (Q4.28) -> ~2e-4 rad accuracy.
//  - Fully pipelined: assert `start` with `angle`; `valid` rises LAT cycles
//    later with the result. Latency LAT = 1 (load) + 16 (stages) + 1 (round).
// ============================================================================
`include "qml_defs.vh"

module cordic #(
    parameter integer NST = 16,      // rotation stages
    parameter integer ZW  = 32,      // internal width
    parameter integer ZF  = 28       // internal fractional bits
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    input  wire signed [`AW-1:0]    angle,   // Q4.12
    output reg                      valid,
    output reg  signed [`DW-1:0]    cosv,    // Q1.14
    output reg  signed [`DW-1:0]    sinv     // Q1.14
);
    localparam integer LAT = NST + 2;

    // ---- arctan(2^-i) table in Q4.28 ------------------------------------
    function signed [ZW-1:0] atant(input integer i);
        case (i)
            0: atant=32'sd210828714; 1: atant=32'sd124459457; 2: atant=32'sd65760959;
            3: atant=32'sd33381290;  4: atant=32'sd16755422;   5: atant=32'sd8385879;
            6: atant=32'sd4193963;   7: atant=32'sd2097109;    8: atant=32'sd1048571;
            9: atant=32'sd524287;    10: atant=32'sd262144;    11: atant=32'sd131072;
            12: atant=32'sd65536;    13: atant=32'sd32768;     14: atant=32'sd16384;
            15: atant=32'sd8192;     default: atant=32'sd0;
        endcase
    endfunction

    localparam signed [ZW-1:0] INVK   = 32'sd163008219;         // 1/K in Q4.28
    localparam signed [ZW-1:0] PI_Z   = 32'sd843314857;         // pi   in Q4.28
    localparam signed [ZW-1:0] HPI_Z  = 32'sd421657428;         // pi/2 in Q4.28

    // ---- argument reduction (combinational, up to 3 steps) --------------
    // convert angle Q4.12 -> Q4.28
    wire signed [ZW-1:0] ang_z = $signed(angle) <<< (ZF-`AF);
    reg  signed [ZW-1:0] r0; reg f0;
    reg  signed [ZW-1:0] r1; reg f1;
    reg  signed [ZW-1:0] r2; reg f2;
    reg  signed [ZW-1:0] r3; reg f3;
    always @* begin
        r0 = ang_z; f0 = 1'b0;
        // step 1
        if      (r0 >  HPI_Z) begin r1 = r0 - PI_Z; f1 = ~f0; end
        else if (r0 < -HPI_Z) begin r1 = r0 + PI_Z; f1 = ~f0; end
        else                  begin r1 = r0;        f1 =  f0; end
        // step 2
        if      (r1 >  HPI_Z) begin r2 = r1 - PI_Z; f2 = ~f1; end
        else if (r1 < -HPI_Z) begin r2 = r1 + PI_Z; f2 = ~f1; end
        else                  begin r2 = r1;        f2 =  f1; end
        // step 3
        if      (r2 >  HPI_Z) begin r3 = r2 - PI_Z; f3 = ~f2; end
        else if (r2 < -HPI_Z) begin r3 = r2 + PI_Z; f3 = ~f2; end
        else                  begin r3 = r2;        f3 =  f2; end
    end

    // ---- pipeline registers ---------------------------------------------
    reg signed [ZW-1:0] xr [0:NST];
    reg signed [ZW-1:0] yr [0:NST];
    reg signed [ZW-1:0] zr [0:NST];
    reg                 fr [0:NST];
    reg                 vr [0:NST];

    integer k;
    // stage load
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xr[0]<=0; yr[0]<=0; zr[0]<=0; fr[0]<=0; vr[0]<=0;
        end else begin
            xr[0] <= INVK;
            yr[0] <= 32'sd0;
            zr[0] <= r3;
            fr[0] <= f3;
            vr[0] <= start;
        end
    end

    // rotation stages
    genvar i;
    generate
        for (i=0; i<NST; i=i+1) begin : stg
            wire signed [ZW-1:0] xs = xr[i] >>> i;
            wire signed [ZW-1:0] ys = yr[i] >>> i;
            wire dneg = zr[i][ZW-1];            // z<0 -> rotate negative
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    xr[i+1]<=0; yr[i+1]<=0; zr[i+1]<=0; fr[i+1]<=0; vr[i+1]<=0;
                end else begin
                    if (dneg) begin              // d = -1
                        xr[i+1] <= xr[i] + ys;
                        yr[i+1] <= yr[i] - xs;
                        zr[i+1] <= zr[i] + atant(i);
                    end else begin               // d = +1
                        xr[i+1] <= xr[i] - ys;
                        yr[i+1] <= yr[i] + xs;
                        zr[i+1] <= zr[i] - atant(i);
                    end
                    fr[i+1] <= fr[i];
                    vr[i+1] <= vr[i];
                end
            end
        end
    endgenerate

    // ---- output stage: sign flip + round to Q1.14 -----------------------
    localparam integer SH = ZF - `QF;                 // 28-14 = 14
    wire signed [ZW-1:0] xf = fr[NST] ? -xr[NST] : xr[NST];
    wire signed [ZW-1:0] yf = fr[NST] ? -yr[NST] : yr[NST];
    // rounding add half LSB
    wire signed [ZW-1:0] xrnd = xf + (1 <<< (SH-1));
    wire signed [ZW-1:0] yrnd = yf + (1 <<< (SH-1));
    wire signed [ZW-1:0] xsh  = xrnd >>> SH;
    wire signed [ZW-1:0] ysh  = yrnd >>> SH;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cosv<=0; sinv<=0; valid<=0;
        end else begin
            // saturate into Q1.14 signed range
            cosv  <= (xsh >  `ONE_Q14) ?  16'sd16384 :
                     (xsh < -`ONE_Q14) ? -16'sd16384 : xsh[`DW-1:0];
            sinv  <= (ysh >  `ONE_Q14) ?  16'sd16384 :
                     (ysh < -`ONE_Q14) ? -16'sd16384 : ysh[`DW-1:0];
            valid <= vr[NST];
        end
    end
endmodule
