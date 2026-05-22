`timescale 1ns/1ps

module tb_test;

reg clk;
reg rst_n;
reg [7:0] a;
reg [7:0] b;
wire [8:0] y;

test dut (
    .clk(clk),
    .rst_n(rst_n),
    .a(a),
    .b(b),
    .y(y)
);

always #5 clk = ~clk;

initial begin
    $dumpfile("src/tb/test.vcd");
    $dumpvars(0, tb_test);

    clk = 0;
    rst_n = 0;
    a = 0;
    b = 0;

    #20 rst_n = 1;
    #10 a = 8'd10;  b = 8'd20;
    #10 a = 8'd5;   b = 8'd7;
    #10 a = 8'd100; b = 8'd50;
    #10 a = 8'd255; b = 8'd1;
    #50 $finish;
end

endmodule
