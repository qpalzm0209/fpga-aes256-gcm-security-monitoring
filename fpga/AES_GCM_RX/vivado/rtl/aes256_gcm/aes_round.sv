module aes_round (
    input  logic [127:0] state_in,
    input  logic [127:0] round_key,
    input  logic         final_round,
    output logic [127:0] state_out
);
    logic [127:0] subbytes_state;
    logic [127:0] shiftrows_state;
    logic [127:0] mixcolumns_state;
    logic [127:0] round_body;

    aes_subbytes u_subbytes (
        .state_in  (state_in),
        .state_out (subbytes_state)
    );

    aes_shiftrows u_shiftrows (
        .state_in  (subbytes_state),
        .state_out (shiftrows_state)
    );

    aes_mixcolumns u_mixcolumns (
        .state_in  (shiftrows_state),
        .state_out (mixcolumns_state)
    );

    assign round_body = final_round ? shiftrows_state : mixcolumns_state;

    aes_addroundkey u_addroundkey (
        .state_in  (round_body),
        .round_key (round_key),
        .state_out (state_out)
    );
endmodule

