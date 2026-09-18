// ============================================================================
//  qpu_core.v  -  State-vector datapath
//  Holds the 2^NQ complex amplitude memory and applies operations:
//    * 1-qubit gate (2x2) to target qa, gated by a control mask (covers all
//      single- and multi-controlled single-qubit gates: X..U3, CX, CRZ, CCX..)
//    * 2-qubit gate (4x4) to (qa,qb), also mask-gated (SWAP/iSWAP/RXX.., CSWAP)
//    * MEAS_Z: expectation <prod of Z over mask> = sum (-1)^parity |amp|^2
//    * RESET : reinitialise to |0..0>
//  Matrix coefficients arrive on flat buses (from gate_gen or a testbench).
//  One amplitude (1Q) / one amplitude-quad (2Q) is processed per clock.
// ============================================================================
`include "qml_defs.vh"

module qpu_core (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 cmd_start,
    input  wire [7:0]           cmd_op,
    input  wire [3:0]           cmd_qa,
    input  wire [3:0]           cmd_qb,
    input  wire [15:0]          cmd_mask,
    input  wire [3:0]           nq,          // active qubit count
    input  wire [8*`DW-1:0]     m1q,         // 2x2 complex (see order below)
    input  wire [32*`DW-1:0]    m2q,         // 4x4 complex row-major (r,i)
    output reg                  busy,
    output reg                  done,        // 1-cycle pulse
    output reg  signed [31:0]   exp_q28,     // expectation, Q4.28 (1.0 = 2^28)
    // debug/verification read-back port
    input  wire [`STATE_AW-1:0] dbg_addr,
    output wire signed [`DW-1:0] dbg_re,
    output wire signed [`DW-1:0] dbg_im
);
    localparam integer SIZE = (1 << `STATE_AW);

    reg signed [`DW-1:0] sr [0:SIZE-1];   // real parts
    reg signed [`DW-1:0] si [0:SIZE-1];   // imag parts

    assign dbg_re = sr[dbg_addr];
    assign dbg_im = si[dbg_addr];

    // ---- unpack 2x2 matrix ------------------------------------------------
    wire signed [`DW-1:0] U00r = m1q[0*`DW +: `DW], U00i = m1q[1*`DW +: `DW];
    wire signed [`DW-1:0] U01r = m1q[2*`DW +: `DW], U01i = m1q[3*`DW +: `DW];
    wire signed [`DW-1:0] U10r = m1q[4*`DW +: `DW], U10i = m1q[5*`DW +: `DW];
    wire signed [`DW-1:0] U11r = m1q[6*`DW +: `DW], U11i = m1q[7*`DW +: `DW];

    // ---- 4x4 matrix entries as continuous nets --------------------------
    // (a function call in a port map would only re-evaluate on its arguments,
    //  not on m2q, so use explicit continuously-driven nets instead)
    wire signed [`DW-1:0] Gm [0:31];
    genvar gi;
    generate for (gi=0; gi<32; gi=gi+1) begin: gmap
        assign Gm[gi] = $signed(m2q[gi*`DW +: `DW]);
    end endgenerate
    // real of (r,c) = Gm[(r*4+c)*2], imag = Gm[(r*4+c)*2+1]

    // ---- addressing -------------------------------------------------------
    reg  [`STATE_AW:0] cnt;              // one extra bit for termination
    wire [`STATE_AW-1:0] tbit = ({{(`STATE_AW-1){1'b0}},1'b1} << cmd_qa);
    wire [`STATE_AW-1:0] abit = ({{(`STATE_AW-1){1'b0}},1'b1} << cmd_qa);
    wire [`STATE_AW-1:0] bbit = ({{(`STATE_AW-1){1'b0}},1'b1} << cmd_qb);
    wire [`STATE_AW:0]   limit = ({{(`STATE_AW){1'b0}},1'b1} << nq);
    wire [`STATE_AW-1:0] idx   = cnt[`STATE_AW-1:0];
    wire [15:0] idx16 = {{(16-`STATE_AW){1'b0}}, idx};
    wire mask_ok = ((idx16 & cmd_mask) == cmd_mask);

    // ---- 1Q butterfly indices & reads ------------------------------------
    wire [`STATE_AW-1:0] i0 = idx & ~tbit;
    wire [`STATE_AW-1:0] i1 = i0 | tbit;
    wire proc_1q = ((idx & tbit) == 0) && mask_ok;
    wire signed [`DW-1:0] a0r=sr[i0], a0i=si[i0], a1r=sr[i1], a1i=si[i1];

    wire signed [`DW-1:0] n0r,n0i,n1r,n1i;
    cmac u_bf0(.m0r(U00r),.m0i(U00i),.a0r(a0r),.a0i(a0i),
               .m1r(U01r),.m1i(U01i),.a1r(a1r),.a1i(a1i),
               .m2r(16'sd0),.m2i(16'sd0),.a2r(16'sd0),.a2i(16'sd0),
               .m3r(16'sd0),.m3i(16'sd0),.a3r(16'sd0),.a3i(16'sd0),
               .outr(n0r),.outi(n0i));
    cmac u_bf1(.m0r(U10r),.m0i(U10i),.a0r(a0r),.a0i(a0i),
               .m1r(U11r),.m1i(U11i),.a1r(a1r),.a1i(a1i),
               .m2r(16'sd0),.m2i(16'sd0),.a2r(16'sd0),.a2i(16'sd0),
               .m3r(16'sd0),.m3i(16'sd0),.a3r(16'sd0),.a3i(16'sd0),
               .outr(n1r),.outi(n1i));

    // ---- 2Q engine indices & reads ---------------------------------------
    wire [`STATE_AW-1:0] q00 =  idx & ~abit & ~bbit;
    wire [`STATE_AW-1:0] q01 =  q00 | bbit;
    wire [`STATE_AW-1:0] q10 =  q00 | abit;
    wire [`STATE_AW-1:0] q11 =  q00 | abit | bbit;
    wire proc_2q = ((idx & abit)==0) && ((idx & bbit)==0) && mask_ok;
    wire signed [`DW-1:0] b0r=sr[q00],b0i=si[q00], b1r=sr[q01],b1i=si[q01];
    wire signed [`DW-1:0] b2r=sr[q10],b2i=si[q10], b3r=sr[q11],b3i=si[q11];

    wire signed [`DW-1:0] m0r,m0i,m1r,m1i,m2r,m2i,m3r,m3i;   // row 0 outputs etc
    // row 0
    cmac u_r0(.m0r(Gm[0]),.m0i(Gm[1]),.a0r(b0r),.a0i(b0i),
              .m1r(Gm[2]),.m1i(Gm[3]),.a1r(b1r),.a1i(b1i),
              .m2r(Gm[4]),.m2i(Gm[5]),.a2r(b2r),.a2i(b2i),
              .m3r(Gm[6]),.m3i(Gm[7]),.a3r(b3r),.a3i(b3i),
              .outr(m0r),.outi(m0i));
    // row 1
    cmac u_r1(.m0r(Gm[8]),.m0i(Gm[9]),.a0r(b0r),.a0i(b0i),
              .m1r(Gm[10]),.m1i(Gm[11]),.a1r(b1r),.a1i(b1i),
              .m2r(Gm[12]),.m2i(Gm[13]),.a2r(b2r),.a2i(b2i),
              .m3r(Gm[14]),.m3i(Gm[15]),.a3r(b3r),.a3i(b3i),
              .outr(m1r),.outi(m1i));
    // row 2
    cmac u_r2(.m0r(Gm[16]),.m0i(Gm[17]),.a0r(b0r),.a0i(b0i),
              .m1r(Gm[18]),.m1i(Gm[19]),.a1r(b1r),.a1i(b1i),
              .m2r(Gm[20]),.m2i(Gm[21]),.a2r(b2r),.a2i(b2i),
              .m3r(Gm[22]),.m3i(Gm[23]),.a3r(b3r),.a3i(b3i),
              .outr(m2r),.outi(m2i));
    // row 3
    cmac u_r3(.m0r(Gm[24]),.m0i(Gm[25]),.a0r(b0r),.a0i(b0i),
              .m1r(Gm[26]),.m1i(Gm[27]),.a1r(b1r),.a1i(b1i),
              .m2r(Gm[28]),.m2i(Gm[29]),.a2r(b2r),.a2i(b2i),
              .m3r(Gm[30]),.m3i(Gm[31]),.a3r(b3r),.a3i(b3i),
              .outr(m3r),.outi(m3i));

    // ---- expectation: signed |amp|^2 -------------------------------------
    wire parity = ^(idx16 & cmd_mask);
    // magnitude of current idx amplitude
    wire signed [`DW-1:0] er = sr[idx];
    wire signed [`DW-1:0] ei = si[idx];
    wire signed [39:0] magsq = er*er + ei*ei;      // Q2.28
    reg  signed [47:0]  acc;

    // ---- FSM --------------------------------------------------------------
    localparam S_IDLE=0, S_1Q=1, S_2Q=2, S_MEAS=3, S_RESET=4, S_DONE=5;
    reg [2:0] st;
    integer w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0; cnt<=0; acc<=0; exp_q28<=0;
        end else begin
            done <= 1'b0;
            case (st)
              S_IDLE: begin
                busy <= 1'b0;
                if (cmd_start) begin
                    busy <= 1'b1; cnt <= 0; acc <= 0;
                    case (cmd_op)
                      `OP_RESET: st <= S_RESET;
                      `OP_MEASZ: st <= S_MEAS;
                      `OP_SWAP,`OP_ISWAP,`OP_SQSWAP,`OP_RXX,`OP_RYY,`OP_RZZ,`OP_RZX:
                                 st <= S_2Q;
                      `OP_NOP,`OP_HALT: st <= S_DONE;
                      default:   st <= S_1Q;   // all single-qubit gates
                    endcase
                end
              end
              S_1Q: begin
                if (proc_1q) begin
                    sr[i0]<=n0r; si[i0]<=n0i;
                    sr[i1]<=n1r; si[i1]<=n1i;
                end
                cnt <= cnt + 1;
                if (cnt + 1 >= limit) st <= S_DONE;
              end
              S_2Q: begin
                if (proc_2q) begin
                    sr[q00]<=m0r; si[q00]<=m0i;
                    sr[q01]<=m1r; si[q01]<=m1i;
                    sr[q10]<=m2r; si[q10]<=m2i;
                    sr[q11]<=m3r; si[q11]<=m3i;
                end
                cnt <= cnt + 1;
                if (cnt + 1 >= limit) st <= S_DONE;
              end
              S_MEAS: begin
                acc <= acc + (parity ? -magsq : magsq);
                cnt <= cnt + 1;
                if (cnt + 1 >= limit) begin
                    exp_q28 <= (acc + (parity ? -magsq : magsq)) >>> 0; // Q?.28
                    st <= S_DONE;
                end
              end
              S_RESET: begin
                if (cnt == 0) begin sr[0]<=`ONE_Q14; si[0]<=16'sd0; end
                else          begin sr[idx]<=16'sd0; si[idx]<=16'sd0; end
                cnt <= cnt + 1;
                if (cnt + 1 >= SIZE) st <= S_DONE;   // clear the whole memory
              end
              S_DONE: begin busy<=1'b0; done<=1'b1; st<=S_IDLE; end
            endcase
        end
    end
endmodule
