module aes_addroundkey (
    input  logic [127:0] state_in,
    input  logic [127:0] round_key,
    output logic [127:0] state_out
);
    assign state_out = state_in ^ round_key;
endmodule

