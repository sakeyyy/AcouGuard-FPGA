`timescale 1ns / 1ps
module name_call_banner(
    input wire [8:0] x, y,
    input wire [9:0] status,
    output wire region,
    output wire [15:0] color
);
    // [3:0]={ready,enrollment,alert,mode4}; [7:4]=stage; [9:8]=number.
    reg [127:0] title,hint,line_text;
    reg [34:0] glyph;
    reg [7:0] letter;
    reg [3:0] phase;
    reg [1:0] number;
    integer cx,gx,gy,row_y;
    reg ink,bar;
    reg [15:0] background;
    always @* begin
        phase=status[7:4];number=status[9:8];
        if(number==0)number=1;
        if(status[1])phase=8;
        else if(phase==0 && status[3])phase=7;
        title="NAME NOT SET    ";hint="HOLD KEY1 1.2S  ";
        case(phase)
            4'd0:begin title="NAME NOT SET    ";hint="HOLD KEY1 1.2S  ";end
            4'd1:begin title="KEEP QUIET      ";hint="CALIBRATING...  ";end
            4'd2:begin title="SAY NAME 1/3    ";hint="SPEAK ONCE      ";title[55 -: 8]=8'd48+number;end
            4'd3:begin title="RECORD NAME 1/3 ";hint="THEN STAY QUIET ";title[31 -: 8]=8'd48+number;end
            4'd4:begin title="SAY OTHER 1/3   ";hint="A DIFFERENT WORD";title[47 -: 8]=8'd48+number;end
            4'd5:begin title="RECORD OTHER 1/3";hint="THEN STAY QUIET ";title[23 -: 8]=8'd48+number;end
            4'd6:begin title="SAVED           ";hint="WAIT NEXT STEP  ";end
            4'd7:begin title="LISTEN          ";hint="CALL YOUR NAME  ";end
            4'd8:begin title="CALL YOU        ";hint="NAME MATCHED    ";end
            4'd9:begin title="TRY AGAIN       ";hint="WAIT IN SILENCE ";end
            4'd10:begin title="SETUP STOPPED   ";hint="HOLD KEY1 RETRY ";end
            default:begin title="NAME NOT SET    ";hint="HOLD KEY1 1.2S  ";end
        endcase
        background=16'h0188;
        if(phase==3 || phase==5)background=16'h8200;
        if(phase==6 || phase==7)background=16'h0320;
        if(phase==8 || phase==10)background=16'hb800;
        line_text=title;row_y=12;
        if(y>=32)begin line_text=hint;row_y=32;end
        cx=0;gx=0;gy=0;letter=32;glyph=0;ink=0;bar=0;
        if(x>=24 && x<216 && y>=row_y && y<row_y+14)begin
            cx=(x-24)/12;gx=((x-24)%12)/2;gy=(y-row_y)/2;
            letter=line_text[127-cx*8 -: 8];
case(letter)
                "A":glyph={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "C":glyph={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D":glyph={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E":glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "I":glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "L":glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M":glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N":glyph={5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
                "O":glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "R":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S":glyph={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T":glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U":glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "Y":glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "B":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "F":glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "G":glyph={5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
                "H":glyph={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "K":glyph={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "P":glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "Q":glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
                "V":glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "W":glyph={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X":glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "0":glyph={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1":glyph={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2":glyph={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3":glyph={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "/":glyph={5'b00001,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b10000};
                ".":glyph={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00110,5'b00110};
                default:glyph=0;
            endcase
            if(gx<5)ink=glyph[34-(gy*5+gx)];
        end
        if(y>=52 && y<56 && x>=24 && x<216 && status[9:8]!=0)
            bar=(x-24)<(status[9:8]*64);
    end
    assign region=status[0] && y>=8 && y<64;
    assign color=ink?16'hffff:(bar?16'h07e0:background);
endmodule
