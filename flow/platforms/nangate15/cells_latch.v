module $_DLATCH_P_(input E, input D, output Q);
    LHQ_X1 _TECHMAP_REPLACE_ (
        .D(D),
        .E(E),
        .Q(Q)
        );
endmodule

module $_DLATCH_N_(input E, input D, output Q);
    wire EN;

    INV_X1 latch_enable_inv (
        .I(E),
        .ZN(EN)
        );

    LHQ_X1 _TECHMAP_REPLACE_ (
        .D(D),
        .E(EN),
        .Q(Q)
        );
endmodule
