`timescale 1ns/1ps
module tb_name_banner;
    reg [8:0] pixel_x=0,pixel_y=0;
    reg [9:0] status=0;
    wire region;
    wire [15:0] color;
    integer stage,step_number,horizontal,vertical,white_pixels;
    name_call_banner dut(.x(pixel_x),.y(pixel_y),.status(status),.region(region),.color(color));
    initial begin
        #1;
        if(region) $fatal(1,"Inactive name mode must not cover display");
        for(stage=0;stage<=10;stage=stage+1) begin
            for(step_number=1;step_number<=3;step_number=step_number+1) begin
                status=(stage<<4)|(step_number<<8)|1;
                white_pixels=0;
                for(vertical=8;vertical<64;vertical=vertical+1) begin
                    for(horizontal=0;horizontal<240;horizontal=horizontal+1) begin
                        pixel_x=horizontal;pixel_y=vertical;#1;
                        if(!region) $fatal(1,"Header region missing");
                        if(^color===1'bx) $fatal(1,"Unknown header pixels");
                        if(color==16'hffff)white_pixels=white_pixels+1;
                    end
                end
                if(white_pixels==0) $fatal(1,"Blank guided stage %0d",stage);
            end
        end
        status=10'b0000000011;pixel_x=0;pixel_y=8;#1;
        if(color!==16'hb800) $fatal(1,"Alert override missing");
        status=10'b0000001001;#1;
        if(color!==16'h0320) $fatal(1,"Ready LISTEN fallback missing");
        pixel_y=64;#1;
        if(region) $fatal(1,"Header bounds wrong");
        $display("NAME_BANNER_REGRESSION_PASS stages=11 template_numbers=3");
        $finish;
    end
endmodule
