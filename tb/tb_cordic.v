// Testbench for cordic.v : drive angles from a hex file, dump cos/sin (Q1.14).
`timescale 1ns/1ps
`include "qml_defs.vh"

module tb_cordic;
    localparam integer NV  = 256;   // upper bound on vector count
    localparam integer LAT = 18;    // cordic latency (NST+2)

    reg clk=0, rst_n=0, start=0;
    reg  signed [`AW-1:0] angle=0;
    wire valid;
    wire signed [`DW-1:0] cosv, sinv;

    cordic dut(.clk(clk), .rst_n(rst_n), .start(start),
               .angle(angle), .valid(valid), .cosv(cosv), .sinv(sinv));

    always #5 clk = ~clk;

    reg [`AW-1:0] mem [0:NV-1];
    integer nvec, i, outf;

    initial begin
        for (i=0;i<NV;i=i+1) mem[i]=16'hxxxx;
        $readmemh("vectors/cordic_angles.hex", mem);
        // count valid entries
        nvec=0;
        for (i=0;i<NV;i=i+1) if (mem[i]!==16'hxxxx) nvec=nvec+1;

        outf = $fopen("vectors/cordic_rtl.txt","w");
        rst_n=0; repeat(3) @(posedge clk); rst_n=1;
        @(posedge clk);

        // feed one angle per cycle, then drain LAT cycles
        fork
            begin : feed
                for (i=0;i<nvec;i=i+1) begin
                    angle <= mem[i]; start <= 1'b1; @(posedge clk);
                end
                start <= 1'b0;
                repeat(LAT+4) @(posedge clk);
            end
            begin : collect
                integer got; got=0;
                while (got < nvec) begin
                    @(posedge clk);
                    if (valid) begin
                        $fwrite(outf, "%0d %0d\n", $signed(cosv), $signed(sinv));
                        got = got + 1;
                    end
                end
            end
        join
        $fclose(outf);
        $display("TB_CORDIC done: %0d vectors", nvec);
        $finish;
    end
endmodule
