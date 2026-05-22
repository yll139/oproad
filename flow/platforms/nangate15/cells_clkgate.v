module OPENROAD_CLKGATE (CK, E, GCK);
  input CK;
  input E;
  output GCK;

`ifdef OPENROAD_CLKGATE

CLKGATETST_X1 latch (.CLK(CK), .E(E), .TE(1'b0), .Q(GCK));

`else

assign GCK = CK;

`endif

endmodule
