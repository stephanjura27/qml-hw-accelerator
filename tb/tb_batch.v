// ===========================================================================
//  tb_batch.v - run many circuits in ONE simulation (fast QML training loop)
//  The circuit structure (prog.hex) is fixed; each job supplies its own
//  parameter set (encoding angles + variational angles) and a (mode,grad_addr).
//  Job j's parameters are the j-th PDEPTH-slice of params.hex.
// ===========================================================================
`timescale 1ns/1ps
`include "qml_defs.vh"

module tb_batch;
    localparam integer PD    = 64;         // must match qml_accelerator PDEPTH
    localparam integer MAXN  = 8192;       // max jobs

    reg clk=0, rst_n=0, go=0, mode=0;
    reg [7:0] grad_addr=0;
    reg [3:0] nq=2;
    wire busy, done;
    wire signed [31:0] result_q28;
    reg  [`STATE_AW-1:0] dbg_addr=0;
    wire signed [`DW-1:0] dbg_re, dbg_im;

    qml_accelerator #(.PROG_FILE("vectors/batch/prog.hex"),
                      .PARAM_FILE("vectors/batch/zero.hex")) dut(
        .clk(clk),.rst_n(rst_n),.go(go),.mode(mode),.grad_addr(grad_addr),
        .nq(nq),.busy(busy),.done(done),.result_q28(result_q28),
        .dbg_addr(dbg_addr),.dbg_re(dbg_re),.dbg_im(dbg_im));

    always #5 clk=~clk;

    reg signed [`AW-1:0] bigp [0:MAXN*PD-1];
    integer jf, rf, N, nqv, j, k, code, jmode, jga;

    initial begin
        $readmemh("vectors/batch/params.hex", bigp);
        rst_n=0; repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);

        jf=$fopen("vectors/batch/jobs.txt","r");
        code=$fscanf(jf,"%d %d\n", N, nqv);
        nq = nqv[3:0];
        rf=$fopen("vectors/batch/results.txt","w");

        for (j=0;j<N;j=j+1) begin
            code=$fscanf(jf,"%d %d\n", jmode, jga);
            // load this job's parameter slice into the accelerator's param RAM
            for (k=0;k<PD;k=k+1) dut.pmem[k] = bigp[j*PD + k];
            mode = jmode[0]; grad_addr = jga[7:0];
            @(posedge clk);
            go<=1'b1; @(posedge clk); go<=1'b0;
            wait(done==1'b1); @(posedge clk);
            $fwrite(rf,"%0d\n", $signed(result_q28));
            @(posedge clk);
        end
        $fclose(rf); $fclose(jf);
        $display("TB_BATCH done: %0d jobs", N);
        $finish;
    end

    initial begin #200000000; $display("TB_BATCH TIMEOUT"); $finish; end
endmodule
