`timescale 1ns/1ps

package gcm_protocol_pkg;
  // Standard-MTU record format: 16-byte AAD + 1440-byte payload + 16-byte
  // TAG = 1472-byte UDP payload, or exactly 1500 bytes including IPv4/UDP.
  localparam logic [31:0] GCM_MAGIC = 32'h5043414d; // "PCAM"
  localparam logic [3:0]  GCM_VERSION = 4'h1;
  localparam logic [15:0] LAST_PACKET_INDEX = 16'd1279;
  localparam logic [127:0] GCM_LENGTH_BLOCK = {64'd128, 64'd11520};

  // AXI byte lane 0 is the first transmitted/stored byte.  AES-GCM notation
  // places that byte in bits [127:120], so the boundary conversion is a byte
  // reversal.  The same function converts in both directions.
  function automatic logic [127:0] axis_to_gcm(input logic [127:0] axis_word);
    integer i;
    begin
      for (i = 0; i < 16; i = i + 1)
        axis_to_gcm[127-(i*8)-:8] = axis_word[(i*8)+:8];
    end
  endfunction

  function automatic logic [127:0] gcm_to_axis(input logic [127:0] gcm_word);
    gcm_to_axis = axis_to_gcm(gcm_word);
  endfunction

  // flags[0]=encrypted, flags[1]=SOF, flags[2]=EOF, flags[15:8]=version.
  function automatic logic [15:0] make_flags(
      input logic encrypted,
      input logic sof,
      input logic eof
  );
    make_flags = {GCM_VERSION, 9'b0, eof, sof, encrypted};
  endfunction

  function automatic logic [127:0] make_aad(
      input logic [31:0] magic,
      input logic [31:0] session_id,
      input logic [31:0] frame_id,
      input logic [15:0] packet_index,
      input logic [15:0] flags
  );
    make_aad = {magic, session_id, frame_id, packet_index, flags};
  endfunction

  function automatic logic [95:0] make_nonce(
      input logic [31:0] session_id,
      input logic [31:0] frame_id,
      input logic [15:0] packet_index
  );
    make_nonce = {session_id, frame_id, 16'h0000, packet_index};
  endfunction
endpackage
