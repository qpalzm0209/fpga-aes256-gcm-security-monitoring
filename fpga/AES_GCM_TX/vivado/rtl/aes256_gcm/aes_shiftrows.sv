module aes_shiftrows (
    input  logic [127:0] state_in,
    output logic [127:0] state_out
);
    logic [7:0] b [0:15];
    logic [7:0] y [0:15];
    integer i;

    always_comb begin
        for (i = 0; i < 16; i = i + 1) begin
            b[i] = state_in[127 - (i * 8) -: 8];
            y[i] = 8'h00;
        end

        y[0]  = b[0];
        y[4]  = b[4];
        y[8]  = b[8];
        y[12] = b[12];

        y[1]  = b[5];
        y[5]  = b[9];
        y[9]  = b[13];
        y[13] = b[1];

        y[2]  = b[10];
        y[6]  = b[14];
        y[10] = b[2];
        y[14] = b[6];

        y[3]  = b[15];
        y[7]  = b[3];
        y[11] = b[7];
        y[15] = b[11];

        for (i = 0; i < 16; i = i + 1) begin
            state_out[127 - (i * 8) -: 8] = y[i];
        end
    end
endmodule

