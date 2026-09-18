// ============================================================================
//  gate_gen.v  -  Gate matrix generator
//  Given an opcode and up to three angle parameters (Q4.12), produces the
//  gate's complex coefficient matrix in Q1.14:
//     m1q : 2x2  (single-qubit gates, incl. controlled variants via mask)
//     m2q : 4x4  (two-qubit gates)
//  Fixed gates use ROM constants; parameterized gates drive the CORDIC to get
//  cos/sin of the required angles (up to 4 sequential evaluations for U3).
//  `mready` pulses when the matrix is valid & held stable.
// ============================================================================
`include "qml_defs.vh"
`include "complex_ops.vh"

module gate_gen (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [7:0]           op,
    input  wire signed [`AW-1:0] p0,      // theta or phi (U2) or lambda (P)
    input  wire signed [`AW-1:0] p1,      // phi
    input  wire signed [`AW-1:0] p2,      // lambda
    output reg                  mready,
    output wire [8*`DW-1:0]     m1q,
    output wire [32*`DW-1:0]    m2q
);
    // ---- CORDIC instance --------------------------------------------------
    reg                    cd_start;
    reg signed [`AW-1:0]   cd_angle;
    wire                   cd_valid;
    wire signed [`DW-1:0]  cd_cos, cd_sin;
    cordic u_cordic(.clk(clk), .rst_n(rst_n), .start(cd_start),
                    .angle(cd_angle), .valid(cd_valid),
                    .cosv(cd_cos), .sinv(cd_sin));

    // storage for computed cos/sin of up to 4 angles
    reg signed [`DW-1:0] cc [0:3];
    reg signed [`DW-1:0] ss [0:3];

    // per-op schedule
    reg  [7:0] op_r;
    reg  signed [`AW-1:0] ang [0:3];
    reg  [2:0] ncalls;
    reg  [2:0] k;         // current call index

    // ---- matrix assembly (combinational) ---------------------------------
    reg signed [`DW-1:0] e1 [0:7];    // 2x2 : U00r,U00i,U01r,U01i,U10r,U10i,U11r,U11i
    reg signed [`DW-1:0] e2 [0:31];   // 4x4 row-major (r,i)
    integer t;

    // shorthands using stored cos/sin
    // single-angle gates use cc[0],ss[0]
    always @* begin
        // default: zero everything
        for (t=0;t<8;t=t+1)  e1[t]=16'sd0;
        for (t=0;t<32;t=t+1) e2[t]=16'sd0;
        case (op_r)
          // ---------- fixed single-qubit ----------
          `OP_I:   begin e1[0]=`ONE_Q14; e1[6]=`ONE_Q14; end
          `OP_X:   begin e1[2]=`ONE_Q14; e1[4]=`ONE_Q14; end
          `OP_Y:   begin e1[3]=-`ONE_Q14; e1[5]=`ONE_Q14; end          // U01=-i,U10=+i
          `OP_Z:   begin e1[0]=`ONE_Q14; e1[6]=-`ONE_Q14; end
          `OP_H:   begin e1[0]=`INVSQRT2; e1[2]=`INVSQRT2;
                         e1[4]=`INVSQRT2; e1[6]=-`INVSQRT2; end
          `OP_S:   begin e1[0]=`ONE_Q14; e1[7]=`ONE_Q14; end           // U11=i
          `OP_SDG: begin e1[0]=`ONE_Q14; e1[7]=-`ONE_Q14; end          // U11=-i
          `OP_T:   begin e1[0]=`ONE_Q14; e1[6]=`COS45; e1[7]=`COS45; end
          `OP_TDG: begin e1[0]=`ONE_Q14; e1[6]=`COS45; e1[7]=-`COS45; end
          `OP_SX:  begin e1[0]=`HALF_Q14; e1[1]=`HALF_Q14;
                         e1[2]=`HALF_Q14; e1[3]=-`HALF_Q14;
                         e1[4]=`HALF_Q14; e1[5]=-`HALF_Q14;
                         e1[6]=`HALF_Q14; e1[7]=`HALF_Q14; end
          `OP_SXDG:begin e1[0]=`HALF_Q14; e1[1]=-`HALF_Q14;
                         e1[2]=`HALF_Q14; e1[3]=`HALF_Q14;
                         e1[4]=`HALF_Q14; e1[5]=`HALF_Q14;
                         e1[6]=`HALF_Q14; e1[7]=-`HALF_Q14; end
          // ---------- parameterized single-qubit ----------
          `OP_RX:  begin e1[0]=cc[0]; e1[3]=-ss[0];
                         e1[5]=-ss[0]; e1[6]=cc[0]; end                // U01=-i s,U10=-i s
          `OP_RY:  begin e1[0]=cc[0]; e1[2]=-ss[0];
                         e1[4]=ss[0];  e1[6]=cc[0]; end
          `OP_RZ:  begin e1[0]=cc[0]; e1[1]=-ss[0];                    // e^-i th/2
                         e1[6]=cc[0]; e1[7]=ss[0]; end                 // e^+i th/2
          `OP_P:   begin e1[0]=`ONE_Q14; e1[6]=cc[0]; e1[7]=ss[0]; end
          `OP_U2:  begin e1[0]=`INVSQRT2; e1[1]=16'sd0;
                         e1[2]=-qmul(`INVSQRT2,cc[1]); e1[3]=-qmul(`INVSQRT2,ss[1]);
                         e1[4]= qmul(`INVSQRT2,cc[0]); e1[5]= qmul(`INVSQRT2,ss[0]);
                         e1[6]= qmul(`INVSQRT2,cc[2]); e1[7]= qmul(`INVSQRT2,ss[2]); end
          `OP_U3:  begin e1[0]=cc[0]; e1[1]=16'sd0;
                         e1[2]=-qmul(ss[0],cc[1]); e1[3]=-qmul(ss[0],ss[1]);
                         e1[4]= qmul(ss[0],cc[2]); e1[5]= qmul(ss[0],ss[2]);
                         e1[6]= qmul(cc[0],cc[3]); e1[7]= qmul(cc[0],ss[3]); end
          // ---------- fixed two-qubit ----------
          `OP_SWAP: begin e2[(0*4+0)*2]=`ONE_Q14; e2[(1*4+2)*2]=`ONE_Q14;
                          e2[(2*4+1)*2]=`ONE_Q14; e2[(3*4+3)*2]=`ONE_Q14; end
          `OP_ISWAP:begin e2[(0*4+0)*2]=`ONE_Q14; e2[(1*4+2)*2+1]=`ONE_Q14;
                          e2[(2*4+1)*2+1]=`ONE_Q14; e2[(3*4+3)*2]=`ONE_Q14; end
          `OP_SQSWAP:begin e2[(0*4+0)*2]=`ONE_Q14;
                          e2[(1*4+1)*2]=`HALF_Q14; e2[(1*4+1)*2+1]=`HALF_Q14;
                          e2[(1*4+2)*2]=`HALF_Q14; e2[(1*4+2)*2+1]=-`HALF_Q14;
                          e2[(2*4+1)*2]=`HALF_Q14; e2[(2*4+1)*2+1]=-`HALF_Q14;
                          e2[(2*4+2)*2]=`HALF_Q14; e2[(2*4+2)*2+1]=`HALF_Q14;
                          e2[(3*4+3)*2]=`ONE_Q14; end
          // ---------- parameterized two-qubit (cc[0]=cos th/2, ss[0]=sin th/2)
          `OP_RXX: begin e2[(0*4+0)*2]=cc[0]; e2[(1*4+1)*2]=cc[0];
                         e2[(2*4+2)*2]=cc[0]; e2[(3*4+3)*2]=cc[0];
                         e2[(0*4+3)*2+1]=-ss[0]; e2[(3*4+0)*2+1]=-ss[0];
                         e2[(1*4+2)*2+1]=-ss[0]; e2[(2*4+1)*2+1]=-ss[0]; end
          `OP_RYY: begin e2[(0*4+0)*2]=cc[0]; e2[(1*4+1)*2]=cc[0];
                         e2[(2*4+2)*2]=cc[0]; e2[(3*4+3)*2]=cc[0];
                         e2[(0*4+3)*2+1]= ss[0]; e2[(3*4+0)*2+1]= ss[0];
                         e2[(1*4+2)*2+1]=-ss[0]; e2[(2*4+1)*2+1]=-ss[0]; end
          `OP_RZZ: begin e2[(0*4+0)*2]=cc[0]; e2[(0*4+0)*2+1]=-ss[0];
                         e2[(1*4+1)*2]=cc[0]; e2[(1*4+1)*2+1]= ss[0];
                         e2[(2*4+2)*2]=cc[0]; e2[(2*4+2)*2+1]= ss[0];
                         e2[(3*4+3)*2]=cc[0]; e2[(3*4+3)*2+1]=-ss[0]; end
          `OP_RZX: begin e2[(0*4+0)*2]=cc[0]; e2[(1*4+1)*2]=cc[0];
                         e2[(2*4+2)*2]=cc[0]; e2[(3*4+3)*2]=cc[0];
                         e2[(0*4+1)*2+1]=-ss[0]; e2[(1*4+0)*2+1]=-ss[0];
                         e2[(2*4+3)*2+1]= ss[0]; e2[(3*4+2)*2+1]= ss[0]; end
          default: begin e1[0]=`ONE_Q14; e1[6]=`ONE_Q14; end   // identity
        endcase
    end

    // pack into buses
    genvar g;
    generate
        for (g=0; g<8;  g=g+1) assign m1q[g*`DW +: `DW] = e1[g];
        for (g=0; g<32; g=g+1) assign m2q[g*`DW +: `DW] = e2[g];
    endgenerate

    // ---- control FSM ------------------------------------------------------
    localparam F_IDLE=0, F_ISSUE=1, F_WAIT=2, F_READY=3;
    reg [1:0] fst;

    // decide schedule for an opcode
    task set_schedule;
        input [7:0] o;
        begin
            case (o)
              `OP_RX,`OP_RY,`OP_RZ,`OP_RXX,`OP_RYY,`OP_RZZ,`OP_RZX: begin
                    ncalls=1; ang[0]=p0>>>1; end
              `OP_P: begin ncalls=1; ang[0]=p0; end
              `OP_U2:begin ncalls=3; ang[0]=p0; ang[1]=p1; ang[2]=p0+p1; end
              `OP_U3:begin ncalls=4; ang[0]=p0>>>1; ang[1]=p2; ang[2]=p1; ang[3]=p1+p2; end
              default: ncalls=0;
            endcase
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fst<=F_IDLE; mready<=0; cd_start<=0; k<=0; op_r<=`OP_I; ncalls<=0;
        end else begin
            mready<=1'b0; cd_start<=1'b0;
            case (fst)
              F_IDLE: if (start) begin
                    op_r <= op;
                    set_schedule(op);
                    k <= 0;
                    if (op==`OP_RX||op==`OP_RY||op==`OP_RZ||op==`OP_RXX||op==`OP_RYY||
                        op==`OP_RZZ||op==`OP_RZX||op==`OP_P||op==`OP_U2||op==`OP_U3)
                         fst <= F_ISSUE;
                    else begin fst<=F_READY; end     // fixed gate, matrix ready next cycle
                end
              F_ISSUE: begin
                    cd_angle <= ang[k];
                    cd_start <= 1'b1;
                    fst <= F_WAIT;
                end
              F_WAIT: if (cd_valid) begin
                    cc[k] <= cd_cos; ss[k] <= cd_sin;
                    if (k+1 >= ncalls) begin fst<=F_READY; end
                    else begin k <= k+1; fst<=F_ISSUE; end
                end
              F_READY: begin mready<=1'b1; fst<=F_IDLE; end
            endcase
        end
    end
endmodule
