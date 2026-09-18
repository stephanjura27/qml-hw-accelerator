// System testbench: loads a program+params, runs the accelerator, dumps the
// final state vector and the result register (measurement or gradient).
`timescale 1ns/1ps
`include "qml_defs.vh"

module tb_system;
    reg clk=0, rst_n=0, go=0, mode=0;
    reg [7:0] grad_addr=0;
    reg [3:0] nq=1;
    wire busy, done;
    wire signed [31:0] result_q28;
    reg  [`STATE_AW-1:0] dbg_addr=0;
    wire signed [`DW-1:0] dbg_re, dbg_im;

    qml_accelerator #(.PROG_FILE("vectors/prog.hex"),
                      .PARAM_FILE("vectors/param.hex")) dut(
        .clk(clk),.rst_n(rst_n),.go(go),.mode(mode),.grad_addr(grad_addr),
        .nq(nq),.busy(busy),.done(done),.result_q28(result_q28),
        .dbg_addr(dbg_addr),.dbg_re(dbg_re),.dbg_im(dbg_im));

    always #5 clk=~clk;

    integer cfgf, code, i, outf, mode_i, ga_i, nq_i, sz;
    initial begin
        cfgf=$fopen("vectors/cfg.txt","r");
        code=$fscanf(cfgf,"%d %d %d\n", nq_i, mode_i, ga_i);
        $fclose(cfgf);
        nq=nq_i[3:0]; mode=mode_i[0]; grad_addr=ga_i[7:0];
        sz = (1<<nq_i);

        rst_n=0; repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        go<=1'b1; @(posedge clk); go<=1'b0;
        // wait for done
        wait(done==1'b1);
        @(posedge clk);

        outf=$fopen("vectors/sys_rtl.txt","w");
        $fwrite(outf,"result %0d\n", $signed(result_q28));
        for (i=0;i<sz;i=i+1) begin
            dbg_addr = i[`STATE_AW-1:0]; #1;
            $fwrite(outf,"%0d %0d\n", $signed(dbg_re), $signed(dbg_im));
        end
        $fclose(outf);
        $display("TB_SYSTEM done: nq=%0d mode=%0d result=%0d", nq_i, mode_i, $signed(result_q28));
        $finish;
    end

    initial begin  // watchdog
        #2000000;
        $display("TB_SYSTEM TIMEOUT"); $finish;
    end
endmodule
