// ============================================================================
//  qml_accelerator.v  -  Top level
//  A general variational-quantum-circuit accelerator:
//    * instruction ROM holds the circuit as a gate program
//    * parameter RAM holds the variational angles
//    * gate_gen builds each gate's matrix (CORDIC for rotations)
//    * qpu_core applies gates to the state vector and measures <Z-string>
//    * a sequencer walks the program; a parameter-shift controller evaluates
//      analytic gradients d<O>/d(theta_k) = (E(+pi/2) - E(-pi/2)) / 2
//
//  mode = 0 : single forward run  -> result_q28 = last measurement E
//  mode = 1 : parameter-shift     -> result_q28 = gradient wrt param[grad_addr]
// ============================================================================
`include "qml_defs.vh"

module qml_accelerator #(
    parameter PROG_FILE  = "prog.hex",
    parameter PARAM_FILE = "param.hex",
    parameter integer IDEPTH = 256,
    parameter integer PDEPTH = 64
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 go,
    input  wire                 mode,       // 0 run, 1 gradient
    input  wire [7:0]           grad_addr,  // param address to differentiate
    input  wire [3:0]           nq,         // active qubits
    output reg                  busy,
    output reg                  done,
    output reg  signed [31:0]   result_q28,
    // state read-back for verification
    input  wire [`STATE_AW-1:0] dbg_addr,
    output wire signed [`DW-1:0] dbg_re,
    output wire signed [`DW-1:0] dbg_im
);
    // ---- memories ---------------------------------------------------------
    reg [`INSTR_W-1:0]   imem [0:IDEPTH-1];
    reg signed [`AW-1:0] pmem [0:PDEPTH-1];
    initial begin
        $readmemh(PROG_FILE,  imem);
        $readmemh(PARAM_FILE, pmem);
    end

    // ---- gate_gen ---------------------------------------------------------
    reg                    gg_start;
    reg  [7:0]             gg_op;
    reg  signed [`AW-1:0]  gg_p0, gg_p1, gg_p2;
    wire                   gg_ready;
    wire [8*`DW-1:0]       gg_m1q;
    wire [32*`DW-1:0]      gg_m2q;
    gate_gen u_gg(.clk(clk),.rst_n(rst_n),.start(gg_start),.op(gg_op),
                  .p0(gg_p0),.p1(gg_p1),.p2(gg_p2),.mready(gg_ready),
                  .m1q(gg_m1q),.m2q(gg_m2q));

    // ---- qpu_core ---------------------------------------------------------
    reg                    qc_start;
    reg  [7:0]             qc_op;
    reg  [3:0]             qc_qa, qc_qb;
    reg  [15:0]            qc_mask;
    wire                   qc_busy, qc_done;
    wire signed [31:0]     qc_exp;
    qpu_core u_core(.clk(clk),.rst_n(rst_n),.cmd_start(qc_start),.cmd_op(qc_op),
                    .cmd_qa(qc_qa),.cmd_qb(qc_qb),.cmd_mask(qc_mask),.nq(nq),
                    .m1q(gg_m1q),.m2q(gg_m2q),.busy(qc_busy),.done(qc_done),
                    .exp_q28(qc_exp),.dbg_addr(dbg_addr),.dbg_re(dbg_re),.dbg_im(dbg_im));

    // ---- parameter-shift override ----------------------------------------
    reg                   ovr_en;
    reg  [7:0]            ovr_addr;
    reg  signed [`AW-1:0] ovr_delta;

    // ---- sequencer FSM ----------------------------------------------------
    reg  run_start, run_done;
    reg  [7:0] pc;
    reg  [7:0] cur_op;
    reg  [3:0] cur_qa, cur_qb;
    reg  [15:0] cur_mask, cur_pidx;
    reg  signed [31:0] meas_reg;

    wire [`INSTR_W-1:0] iw = imem[pc];
    // param reads with optional override on matching address
    wire [7:0] a0 = cur_pidx[7:0];
    wire [7:0] a1 = cur_pidx[7:0] + 8'd1;
    wire [7:0] a2 = cur_pidx[7:0] + 8'd2;
    wire signed [`AW-1:0] pr0 = pmem[a0] + ((ovr_en && a0==ovr_addr)? ovr_delta:16'sd0);
    wire signed [`AW-1:0] pr1 = pmem[a1] + ((ovr_en && a1==ovr_addr)? ovr_delta:16'sd0);
    wire signed [`AW-1:0] pr2 = pmem[a2] + ((ovr_en && a2==ovr_addr)? ovr_delta:16'sd0);

    localparam R_IDLE=0,R_FETCH=1,R_DEC=2,R_GGEN=3,R_APPLY=4,R_WAIT=5,R_NEXT=6,R_HALT=7;
    reg [2:0] rst_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_s<=R_IDLE; pc<=0; run_done<=0; gg_start<=0; qc_start<=0; meas_reg<=0;
        end else begin
            run_done<=1'b0; gg_start<=1'b0; qc_start<=1'b0;
            case (rst_s)
              R_IDLE: if (run_start) begin pc<=0; rst_s<=R_FETCH; end
              R_FETCH: begin
                    cur_op   <= iw[`OPC_HI:`OPC_LO];
                    cur_qa   <= iw[`QA_HI:`QA_LO];
                    cur_qb   <= iw[`QB_HI:`QB_LO];
                    cur_mask <= iw[`MASK_HI:`MASK_LO];
                    cur_pidx <= iw[`PIDX_HI:`PIDX_LO];
                    rst_s <= R_DEC;
              end
              R_DEC: begin
                    if (cur_op==`OP_HALT) rst_s<=R_HALT;
                    else if (cur_op==`OP_NOP) rst_s<=R_NEXT;
                    else if (cur_op==`OP_MEASZ || cur_op==`OP_RESET) begin
                        // no matrix needed
                        qc_op<=cur_op; qc_qa<=cur_qa; qc_qb<=cur_qb; qc_mask<=cur_mask;
                        qc_start<=1'b1; rst_s<=R_WAIT;
                    end else begin
                        // gate: build matrix
                        gg_op<=cur_op; gg_p0<=pr0; gg_p1<=pr1; gg_p2<=pr2;
                        gg_start<=1'b1; rst_s<=R_GGEN;
                    end
              end
              R_GGEN: if (gg_ready) begin
                        qc_op<=cur_op; qc_qa<=cur_qa; qc_qb<=cur_qb; qc_mask<=cur_mask;
                        qc_start<=1'b1; rst_s<=R_WAIT;
                    end
              R_WAIT: if (qc_done) begin
                        if (cur_op==`OP_MEASZ) meas_reg <= qc_exp;
                        rst_s<=R_NEXT;
                    end
              R_NEXT: begin pc<=pc+1; rst_s<=R_FETCH; end
              R_HALT: begin run_done<=1'b1; rst_s<=R_IDLE; end
            endcase
        end
    end

    // ---- parameter-shift controller / top FSM ----------------------------
    reg signed [31:0] e_plus, e_minus;
    localparam P_IDLE=0,P_RUN=1,P_WAITP=2,P_RUNM=3,P_WAITM=4,P_DONE=5;
    reg [2:0] pst;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pst<=P_IDLE; busy<=0; done<=0; run_start<=0;
            ovr_en<=0; ovr_addr<=0; ovr_delta<=0; result_q28<=0;
        end else begin
            done<=1'b0; run_start<=1'b0;
            case (pst)
              P_IDLE: if (go) begin
                    busy<=1'b1;
                    if (mode==1'b0) begin           // single run
                        ovr_en<=1'b0; run_start<=1'b1; pst<=P_WAITP;
                    end else begin                  // gradient: +pi/2 first
                        ovr_en<=1'b1; ovr_addr<=grad_addr; ovr_delta<=`HALFPI_Q412;
                        run_start<=1'b1; pst<=P_WAITP;
                    end
                end
              P_WAITP: if (run_done) begin
                    e_plus <= meas_reg;
                    if (mode==1'b0) begin
                        result_q28 <= meas_reg; pst<=P_DONE;
                    end else begin
                        ovr_delta <= -`HALFPI_Q412; run_start<=1'b1; pst<=P_WAITM;
                    end
                end
              P_WAITM: if (run_done) begin
                    e_minus <= meas_reg;
                    // gradient = (E+ - E-)/2   (parameter-shift, s=pi/2)
                    result_q28 <= ($signed(e_plus) - $signed(meas_reg)) >>> 1;
                    ovr_en<=1'b0;
                    pst<=P_DONE;
                end
              P_DONE: begin busy<=1'b0; done<=1'b1; pst<=P_IDLE; end
            endcase
        end
    end
endmodule
