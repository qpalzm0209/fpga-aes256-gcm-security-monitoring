`timescale 1ns / 1ps
module aes256_key_transform (
    input  logic [31:0] last_word,   // ?댁쟾 ??洹몃９??留덉?留??뚮뱶
    input  logic        use_g,       // 1: G ?⑥닔, 0: U ?⑥닔
    input  logic [ 7:0] rcon_value,  // G ?⑥닔?먯꽌 ?ъ슜??Rcon
    output logic [31:0] transform
);

  logic [31:0] rotated_word;
  logic [31:0] subword_input;
  logic [31:0] subword_output;
  logic [31:0] rcon_word;

  // RotWord: {B0, B1, B2, B3} -> {B1, B2, B3, B0}
  assign rotated_word  = {last_word[23:0], last_word[31:24]};

  // G ?④퀎?먯꽌??RotWord 寃곌낵瑜?SubWord???낅젰
  // U ?④퀎?먯꽌???먮옒 ?뚮뱶瑜?洹몃?濡?SubWord???낅젰
  assign subword_input = use_g ? rotated_word : last_word;

  // 32鍮꾪듃 ?뚮뱶??4諛붿씠?몃? S-box濡?蹂묐젹 移섑솚
  aes_subword32 u_subword32 (
      .word_in (subword_input),
      .word_out(subword_output)
  );

  // Rcon? 理쒖긽??諛붿씠?몄뿉留??꾩튂
  assign rcon_word = {rcon_value, 24'h000000};

  // G: SubWord(RotWord(last_word)) XOR Rcon
  // U: SubWord(last_word)
  assign transform = use_g ? subword_output ^ rcon_word : subword_output;

endmodule

