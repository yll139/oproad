module test (
    input  wire clk,
    input  wire rst_n,
    input  wire [7:0] a,
    input  wire [7:0] b,
    output reg  [8:0] y
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        y <= 0;
    else
        y <= a + b;
end

endmodule
