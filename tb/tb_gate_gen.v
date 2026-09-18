// Testbench for gate_gen.v : drive opcodes/params, dump 2x2 and 4x4 matrices.
`timescale 1ns/1ps
`include "qml_defs.vh"

module tb_gate_gen;
    localparam integer NV = 64;
    reg clk=0, rst_n=0, start=0;
    reg [7:0] op;
    reg signed [`AW-1:0] p0,p1,p2;
    wire mready;
    wire [8*`DW-1:0]  m1q;
    wire [32*`DW-1:0] m2q;

    gate_gen dut(.clk(clk),.rst_n(rst_n),.start(start),.op(op),
                 .p0(p0),.p1(p1),.p2(p2),.mready(mready),.m1q(m1q),.m2q(m2q));
    always #5 clk=~clk;

    // test storage
    reg [7:0]  t_op  [0:NV-1];
    reg [`AW-1:0] t_p0[0:NV-1], t_p1[0:NV-1], t_p2[0:NV-1];
    integer nv, i, j, outf, fd, code;
    reg [8*8-1:0] dummy;

    initial begin
        // load tests
        fd = $fopen("vectors/gate_tests.hex","r");
        nv = 0;
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h %h %h\n", t_op[nv], t_p0[nv], t_p1[nv], t_p2[nv]);
            if (code==4) nv = nv + 1;
        end
        $fclose(fd);

        outf = $fopen("vectors/gate_rtl.txt","w");
        rst_n=0; repeat(3) @(posedge clk); rst_n=1; @(posedge clk);

        for (i=0;i<nv;i=i+1) begin
            op=t_op[i]; p0=t_p0[i]; p1=t_p1[i]; p2=t_p2[i];
            start<=1'b1; @(posedge clk); start<=1'b0;
            // wait for mready
            while (!mready) @(posedge clk);
            // dump 8 m1q then 32 m2q signed decimals
            $fwrite(outf,"%0d",$signed(m1q[0*`DW +: `DW]));
            for (j=1;j<8;j=j+1)  $fwrite(outf," %0d",$signed(m1q[j*`DW +: `DW]));
            for (j=0;j<32;j=j+1) $fwrite(outf," %0d",$signed(m2q[j*`DW +: `DW]));
            $fwrite(outf,"\n");
            @(posedge clk);
        end
        $fclose(outf);
        $display("TB_GATE_GEN done: %0d gates", nv);
        $finish;
    end
endmodule
