`timescale 1ns / 1ps

module lcd_test #(
    // 两组对向麦克风的中心间距，单位 mm
    parameter integer FRONT_BACK_MM = 60,
    parameter integer LEFT_RIGHT_MM = 60,

    // 高通滤波：1 开启，0 旁路
    parameter integer HP_ENABLE = 1,

    // 当前采样率下：
    // SHIFT=4：约 500 Hz
    // SHIFT=5：约 250 Hz，默认
    // SHIFT=6：约 120 Hz
    parameter integer HP_SHIFT = 5,

    // 10 = 1024 点；11 = 2048 点
    parameter integer FRAME_LOG2 = 10,

    // Q8 增益：256 表示 1 倍
    parameter integer GAIN_FRONT_Q8 = 256,
    parameter integer GAIN_LEFT_Q8  = 256,
    parameter integer GAIN_RIGHT_Q8 = 256,
    parameter integer GAIN_BACK_Q8  = 256,

    // 滤波后四通道平均绝对幅度的触发/释放阈值
    parameter [15:0] SOUND_ON_LEVEL  = 16'd35,
    parameter [15:0] SOUND_OFF_LEVEL = 16'd17,

    // 归一化正相关系数平方，Q16 格式
    parameter integer MIN_Q = 4096,

    // 单位：1/4 采样点
    parameter integer MIN_VECTOR_Q2 = 2,

    parameter integer CONFIRM_BLOCKS = 2,
    parameter integer QUIET_BLOCKS   = 6,
    parameter integer UNSURE_BLOCKS  = 4,

    parameter integer CHECK_AMBIG = 1,

    // 仅当实际方向整体反转时修改
    parameter integer FLIP_FB = 0,
    parameter integer FLIP_LR = 0,

    // 安全默认: 电机关闭; 确认供电/接线正确后才改为 1
    parameter integer ENABLE_MOTORS = 1
)(
    input wire clk_50m,
    input wire [31:0] ps_control,

    input wire mic_front_sd,
    input wire mic_left_sd,
    input wire mic_right_sd,
    input wire mic_back_sd,

    output reg mic_sck = 0,
    output reg mic_ws  = 0,

    output reg lcd_cs   = 1,
    output reg lcd_rst  = 0,
    output reg lcd_dc   = 0,
    output reg lcd_mosi = 0,
    output reg lcd_sck  = 0,

    output wire [3:0] motor_pwm,
    // Internal BD signals; do NOT make these package-pin ports.
    output reg audio_frame_valid=0,
    output reg [95:0] audio_frame_pcm=0,
    output wire [3:0] audio_direction,
    output wire audio_direction_valid
);

    localparam [3:0]
        DIR_LEFT        = 0,
        DIR_FRONT       = 1,
        DIR_RIGHT       = 2,
        DIR_BACK        = 3,
        DIR_QUIET       = 4,
        DIR_UNSURE      = 5,
        DIR_FRONT_LEFT  = 6,
        DIR_FRONT_RIGHT = 7,
        DIR_BACK_LEFT   = 8,
        DIR_BACK_RIGHT  = 9;

    // =====================================================
    // LCD SPI：保留原发送方式
    // =====================================================

    reg [3:0] spi_div = 0;
    reg [7:0] spi_shift = 0;
    reg [2:0] spi_bit = 0;

    reg spi_high  = 0;
    reg spi_busy  = 0;
    reg spi_done  = 0;
    reg spi_start = 0;
    reg spi_dc    = 0;

    reg [7:0] spi_data = 0;

    always @(posedge clk_50m) begin
        spi_done <= 0;

        if (!spi_busy) begin
            if (spi_start) begin
                spi_busy  <= 1;
                spi_div   <= 0;
                spi_high  <= 0;
                spi_bit   <= 7;
                spi_shift <= spi_data;

                lcd_cs   <= 0;
                lcd_dc   <= spi_dc;
                lcd_mosi <= spi_data[7];
                lcd_sck  <= 0;
            end
        end else begin
            spi_div <= spi_div + 1'b1;

            if (spi_div == 1) begin
                spi_div <= 0;

                if (!spi_high) begin
                    lcd_sck  <= 1;
                    spi_high <= 1;
                end else begin
                    lcd_sck  <= 0;
                    spi_high <= 0;

                    if (spi_bit == 0) begin
                        spi_busy <= 0;
                        spi_done <= 1;
                    end else begin
                        spi_bit   <= spi_bit - 1'b1;
                        spi_shift <= {spi_shift[6:0],1'b0};
                        lcd_mosi  <= spi_shift[6];
                    end
                end
            end
        end
    end

    // =====================================================
    // LCD 初始化，MADCTL=C0 保留 180° 旋转
    // =====================================================

    function [8:0] init_entry;
        input [4:0] n;
        begin
            case (n)
                 0: init_entry = {1'b0,8'h11};
                 1: init_entry = {1'b0,8'h36};
                 2: init_entry = {1'b1,8'hC0};
                 3: init_entry = {1'b0,8'h3A};
                 4: init_entry = {1'b1,8'h55};
                 5: init_entry = {1'b0,8'h20};
                 6: init_entry = {1'b0,8'h2A};
                 7: init_entry = {1'b1,8'h00};
                 8: init_entry = {1'b1,8'h00};
                 9: init_entry = {1'b1,8'h00};
                10: init_entry = {1'b1,8'hEF};
                11: init_entry = {1'b0,8'h2B};
                12: init_entry = {1'b1,8'h00};
                13: init_entry = {1'b1,8'h00};
                14: init_entry = {1'b1,8'h01};
                15: init_entry = {1'b1,8'h3F};
                16: init_entry = {1'b0,8'h29};
                17: init_entry = {1'b0,8'h2C};
                default: init_entry = {1'b0,8'h00};
            endcase
        end
    endfunction

    // =====================================================
    // 四路 INMP441 接收
    // BCLK = 50 MHz / 16 = 3.125 MHz
    // Fs = BCLK / 64 = 48828.125 Hz
    // =====================================================

    reg [2:0] mic_clkdiv = 0;
    reg [5:0] mic_bit = 0;

    (* ASYNC_REG="TRUE" *) reg [3:0] sd_meta = 0;
    (* ASYNC_REG="TRUE" *) reg [3:0] sd_sync = 0;

    always @(posedge clk_50m) begin
        sd_meta <= {
            mic_back_sd,
            mic_right_sd,
            mic_left_sd,
            mic_front_sd
        };
        sd_sync <= sd_meta;

        if (mic_clkdiv == 7) begin
            mic_clkdiv <= 0;
            mic_sck <= ~mic_sck;

            if (mic_sck) begin
                mic_bit <= mic_bit + 1'b1;

                if (mic_bit == 31)
                    mic_ws <= 1;

                if (mic_bit == 63)
                    mic_ws <= 0;
            end
        end else begin
            mic_clkdiv <= mic_clkdiv + 1'b1;
        end
    end

    // 所有 L/R 接地，只接收左声道时隙。
    // 跳过 I2S 的延迟位，接收 slot 1..24。
    // 延后于 BCLK 上升沿采样已同步的数据。
    wire rx_sample_tick =
        mic_sck &&
        (mic_clkdiv == 2) &&
        (mic_bit >= 1) &&
        (mic_bit <= 24);

    wire word_valid = rx_sample_tick && (mic_bit == 24);

    reg [23:0] f_shift = 0;
    reg [23:0] l_shift = 0;
    reg [23:0] r_shift = 0;
    reg [23:0] b_shift = 0;

    // 包括当前最后一位，避免漏掉第 24 位
    wire [23:0] f_word = {f_shift[22:0],sd_sync[0]};
    wire [23:0] l_word = {l_shift[22:0],sd_sync[1]};
    wire [23:0] r_word = {r_shift[22:0],sd_sync[2]};
    wire [23:0] b_word = {b_shift[22:0],sd_sync[3]};

    always @(posedge clk_50m) begin
        if (rx_sample_tick) begin
            f_shift <= f_word;
            l_shift <= l_word;
            r_shift <= r_word;
            b_shift <= b_word;
        end
    end

    // =====================================================
    // 四路相同的高通滤波和增益处理
    // 取 24 位有符号数据的高 16 位
    // =====================================================

    wire pcm_valid;
    wire signed [15:0] pcm_f;
    wire signed [15:0] pcm_l;
    wire signed [15:0] pcm_r;
    wire signed [15:0] pcm_b;

    audio_hp_q8 #(
        .ENABLE(HP_ENABLE),
        .SHIFT(HP_SHIFT),
        .GAIN_Q8(GAIN_FRONT_Q8)
    ) hp_f (
        .clk(clk_50m),
        .valid_in(word_valid),
        .sample_in(f_word[23:8]),
        .valid_out(pcm_valid),
        .sample_out(pcm_f)
    );

    audio_hp_q8 #(
        .ENABLE(HP_ENABLE),
        .SHIFT(HP_SHIFT),
        .GAIN_Q8(GAIN_LEFT_Q8)
    ) hp_l (
        .clk(clk_50m),
        .valid_in(word_valid),
        .sample_in(l_word[23:8]),
        .valid_out(),
        .sample_out(pcm_l)
    );

    audio_hp_q8 #(
        .ENABLE(HP_ENABLE),
        .SHIFT(HP_SHIFT),
        .GAIN_Q8(GAIN_RIGHT_Q8)
    ) hp_r (
        .clk(clk_50m),
        .valid_in(word_valid),
        .sample_in(r_word[23:8]),
        .valid_out(),
        .sample_out(pcm_r)
    );

    audio_hp_q8 #(
        .ENABLE(HP_ENABLE),
        .SHIFT(HP_SHIFT),
        .GAIN_Q8(GAIN_BACK_Q8)
    ) hp_b (
        .clk(clk_50m),
        .valid_in(word_valid),
        .sample_in(b_word[23:8]),
        .valid_out(),
        .sample_out(pcm_b)
    );

    // Tap raw signed 24-bit words before the existing 16-bit HP/DOA path.
    // CH0 FRONT, CH1 LEFT, CH2 RIGHT, CH3 BACK, same sampling instant.
    always @(posedge clk_50m) begin
        audio_frame_valid<=word_valid;
        if(word_valid) audio_frame_pcm<={b_word,r_word,l_word,f_word};
    end

    wire [3:0] detected_dir;
    wire [15:0] detected_level;
    wire [63:0] debug_levels;
    wire signed [11:0] debug_x;
    wire signed [11:0] debug_y;
    wire [31:0] debug_quality;
    wire [3:0] debug_mask;
    wire [3:0] debug_status;
    assign audio_direction=detected_dir;
    assign audio_direction_valid=(debug_status==2) &&
        (detected_dir!=4) && (detected_dir!=5);


    doa4_core #(
        .FB_MM(FRONT_BACK_MM),
        .LR_MM(LEFT_RIGHT_MM),
        .FRAME_LOG2(FRAME_LOG2),
        .ON_LEVEL(SOUND_ON_LEVEL),
        .OFF_LEVEL(SOUND_OFF_LEVEL),
        .MIN_Q(MIN_Q),
        .MIN_VECTOR_Q2(MIN_VECTOR_Q2),
        .CONFIRM(CONFIRM_BLOCKS),
        .QUIET_N(QUIET_BLOCKS),
        .UNSURE_N(UNSURE_BLOCKS),
        .CHECK_AMBIG(CHECK_AMBIG),
        .FLIP_FB(FLIP_FB),
        .FLIP_LR(FLIP_LR)
    ) u_doa (
        .clk(clk_50m),
        .valid(pcm_valid),
        .f(pcm_f),
        .l(pcm_l),
        .r(pcm_r),
        .b(pcm_b),
        .detected_dir(detected_dir),
        .detected_level(detected_level),
        .levels(debug_levels),
        .delay_x(debug_x),
        .delay_y(debug_y),
        .qualities(debug_quality),
        .channel_ok(debug_mask),
        .status(debug_status)
    );

    // =====================================================
    // 电机输出，默认关闭
    // =====================================================

    reg [17:0] motor_count = 0;

    always @(posedge clk_50m) begin
        if (motor_count == 249999)
            motor_count <= 0;
        else
            motor_count <= motor_count + 1'b1;
    end

    wire motor_phase = (motor_count < 125000);
    reg [3:0] motor_sel;

    always @* begin
        case (detected_dir)
            DIR_FRONT:       motor_sel = 4'b0001;
            DIR_LEFT:        motor_sel = 4'b0010;
            DIR_RIGHT:       motor_sel = 4'b0100;
            DIR_BACK:        motor_sel = 4'b1000;
            DIR_FRONT_LEFT:  motor_sel = 4'b0011;
            DIR_FRONT_RIGHT: motor_sel = 4'b0101;
            DIR_BACK_LEFT:   motor_sel = 4'b1010;
            DIR_BACK_RIGHT:  motor_sel = 4'b1100;
            default:         motor_sel = 0;
        endcase
    end

    // New PS bits do not change the lower capture/classification contract.
    reg [9:0] name_meta=0,name_status=0;
    always @(posedge clk_50m) begin
        name_meta<=ps_control[23:14];name_status<=name_meta;
    end
    // Distinct two-pulse alert, then live direction tracking while alert is held.
    reg [26:0] call_count=0;
    always @(posedge clk_50m) begin
        if(!name_status[0] || !name_status[1])call_count<=0;
        else if(call_count<27'd100000000)call_count<=call_count+1'b1;
    end
    wire call_pulse=(call_count<27'd7500000) ||
                    (call_count>=27'd15000000 && call_count<27'd22500000);
    wire [3:0] call_motors=(call_count<27'd22500000)?
                              (call_pulse?4'b1111:4'b0000):motor_sel;
    assign motor_pwm =
        (ENABLE_MOTORS != 0 && motor_phase) ?
        (name_status[0]?(name_status[1]?call_motors:4'b0000):motor_sel) : 4'b0000;

    // PS control shared with capture module (internal AXI GPIO branch only).
    // [0] capture enable; [11:8] confirmed model class; [12] result valid.
    reg [3:0] frame_class=9;
    reg frame_icon_mode=0;
    reg frame_result_valid=0;
    reg [3:0] direction=DIR_QUIET;
    reg [8:0] pixel_x=0,pixel_y=0;
    wire live_result_valid=ps_control[0] && ps_control[12] && ps_control[11:8]<=8;
    wire [3:0] live_class=live_result_valid?ps_control[11:8]:4'd9;
    wire [3:0] footer_index=(!frame_icon_mode)?((direction<=9)?direction:4'd5):
        (!frame_result_valid)?4'd11:(frame_class==0)?4'd10:((direction<=9)?direction:4'd5);
    wire [3:0] picture_class=frame_icon_mode?frame_class:(direction==4?4'd0:4'd9);
    reg [9:0] icon_addr,text_addr;
    reg [6:0] icon_x;
    reg [7:0] text_x;
    reg icon_region,text_region;
    reg [15:0] text_color,base_color;
    integer ux,uy,dx,dy,v,w,aw,arrow_scale;
    reg arrow_on;
    wire [3:0] icon_index;
    wire text_on;
    sound_ui_rom u_ui_rom(.clk(clk_50m),.icon_addr(icon_addr),.icon_x(icon_x),
        .text_addr(text_addr),.text_x(text_x),.icon_index(icon_index),.text_on(text_on));

    function [15:0] palette_color;
        input [3:0] index;
        begin
            case(index)
                4'd0:palette_color=16'h08e5;
                4'd1:palette_color=16'hf7df;
                4'd2:palette_color=16'h36b9;
                4'd3:palette_color=16'hfe8c;
                4'd4:palette_color=16'hfacd;
                4'd5:palette_color=16'h44bd;
                4'd6:palette_color=16'h9557;
                4'd7:palette_color=16'hed93;
                4'd8:palette_color=16'hbbc8;
                4'd9:palette_color=16'h1906;
                4'd10:palette_color=16'h76d3;
                4'd11:palette_color=16'hf477;
                4'd12:palette_color=16'h122b;
                4'd13:palette_color=16'h6a66;
                4'd14:palette_color=16'hc77e;
                4'd15:palette_color=16'he548;
                default:palette_color=16'h08e5;
            endcase
        end
    endfunction
    always @* begin
        icon_addr=0;icon_x=0;text_addr=0;text_x=0;
        icon_region=0;text_region=0;text_color=16'hffff;
        base_color=palette_color(0);
        ux=0;uy=0;dx=$signed({1'b0,pixel_x})-120;dy=$signed({1'b0,pixel_y})-142;
        v=0;w=0;aw=0;arrow_scale=1;arrow_on=0;
        case(direction)
            0:begin ux=-1;uy=0;end
            1:begin ux=0;uy=-1;end
            2:begin ux=1;uy=0;end
            3:begin ux=0;uy=1;end
            6:begin ux=-1;uy=-1;end
            7:begin ux=1;uy=-1;end
            8:begin ux=-1;uy=1;end
            9:begin ux=1;uy=1;end
            default:begin end
        endcase
        v=((ux==1)?dx:(ux==-1)?-dx:0)+((uy==1)?dy:(uy==-1)?-dy:0);
        w=((ux==1)?dy:(ux==-1)?-dy:0)-((uy==1)?dx:(uy==-1)?-dx:0);
        aw=(w<0)?-w:w;arrow_scale=(ux!=0 && uy!=0)?2:1;
        if(!frame_icon_mode && (ux!=0 || uy!=0))begin
            if(v>=-44*arrow_scale && v<=18*arrow_scale && aw<=9*arrow_scale)arrow_on=1;
            if(v>=12*arrow_scale && v<=65*arrow_scale && aw<=(65*arrow_scale-v)/2)arrow_on=1;
        end
        if(arrow_on)base_color=palette_color(2);
        if((frame_icon_mode || direction==4 || direction==5 || direction>9) &&
           pixel_x>=24 && pixel_x<216 && pixel_y>=48 && pixel_y<240) begin
            icon_region=1;
            icon_addr=picture_class*10'd96+((pixel_y-48)>>1);
            icon_x=(pixel_x-24)>>1;
        end
        if(pixel_x>=8 && pixel_x<232) begin
            text_x=pixel_x-8;
            if(pixel_y>=12 && pixel_y<44) begin
                text_region=1;text_addr=(frame_icon_mode?10'd320:10'd736)+(pixel_y-12);
            end else if(pixel_y>=244 && pixel_y<276) begin
                text_region=1;text_addr=(frame_icon_mode?frame_class*10'd32:(10'd11+footer_index)*10'd32)+(pixel_y-244);
            end else if(frame_icon_mode && pixel_y>=284 && pixel_y<316) begin
                text_region=1;text_addr=(10'd11+footer_index)*10'd32+(pixel_y-284);
                text_color=16'h3699;
            end
        end
    end
    reg icon_region_q=0,text_region_q=0;
    reg [15:0] text_color_q=0,base_color_q=0;
    always @(posedge clk_50m) begin
        icon_region_q<=icon_region;text_region_q<=text_region;text_color_q<=text_color;base_color_q<=base_color;
    end
    wire name_region;
    wire [15:0] name_color;
    reg name_region_q=0;
    reg [15:0] name_color_q=0;
    name_call_banner u_name_banner(.x(pixel_x),.y(pixel_y),.status(name_status),
        .region(name_region),.color(name_color));
    always @(posedge clk_50m)begin
        name_region_q<=name_region;name_color_q<=name_color;
    end
    wire [15:0] pixel_pipeline=name_region_q?name_color_q:
        (text_region_q && text_on)?text_color_q:
        icon_region_q?palette_color(icon_index):base_color_q;

    // =====================================================
    // LCD 控制状态机
    // =====================================================

    localparam [3:0]
        S_POWER_WAIT=0,
        S_RESET_LOW=1,
        S_RESET_HIGH=2,
        S_INIT_SEND=3,
        S_INIT_WAIT=4,
        S_SLEEP_WAIT=5,
        S_ON_WAIT=6,
        S_PIXEL_SEND=7,
        S_PIXEL_WAIT=8,
        S_COLOR_HOLD=9,
        S_RAMWR_SEND=10,
        S_RAMWR_WAIT=11,
        S_PIXEL_PREP=12;

    reg [3:0] state=S_POWER_WAIT;
    reg [25:0] delay_count=0;
    reg [4:0] init_index=0;
    reg [17:0] pixel_byte=0;
    reg [1:0] pixel_wait=0;

    wire [15:0] color_word=pixel_pipeline;
    wire [8:0] init_word=init_entry(init_index);

    always @(posedge clk_50m) begin
        spi_start<=0;

        case (state)
            S_POWER_WAIT:begin
                lcd_rst<=0;

                if (delay_count==999999) begin
                    delay_count<=0;
                    state<=S_RESET_LOW;
                end else delay_count<=delay_count+1'b1;
            end

            S_RESET_LOW:begin
                lcd_rst<=0;

                if (delay_count==999999) begin
                    lcd_rst<=1;
                    delay_count<=0;
                    state<=S_RESET_HIGH;
                end else delay_count<=delay_count+1'b1;
            end

            S_RESET_HIGH:begin
                if (delay_count==5999999) begin
                    delay_count<=0;
                    state<=S_INIT_SEND;
                end else delay_count<=delay_count+1'b1;
            end

            S_INIT_SEND:begin
                spi_dc<=init_word[8];
                spi_data<=init_word[7:0];
                spi_start<=1;
                state<=S_INIT_WAIT;
            end

            S_INIT_WAIT:begin
                if (spi_done) begin
                    if (init_index==0) begin
                        delay_count<=0;
                        state<=S_SLEEP_WAIT;
                    end else if (init_index==16) begin
                        delay_count<=0;
                        state<=S_ON_WAIT;
                    end else if (init_index==17) begin
                        frame_class<=live_class;
                        frame_result_valid<=live_result_valid;
                        frame_icon_mode<=ps_control[13];
                        direction<=detected_dir;
                        pixel_byte<=0;
                        pixel_x<=0;
                        pixel_y<=0;
                        state<=S_PIXEL_PREP;
                    end else begin
                        init_index<=init_index+1'b1;
                        state<=S_INIT_SEND;
                    end
                end
            end

            S_SLEEP_WAIT:begin
                if (delay_count==5999999) begin
                    delay_count<=0;
                    init_index<=1;
                    state<=S_INIT_SEND;
                end else delay_count<=delay_count+1'b1;
            end

            S_ON_WAIT:begin
                if (delay_count==999999) begin
                    delay_count<=0;
                    init_index<=17;
                    state<=S_INIT_SEND;
                end else delay_count<=delay_count+1'b1;
            end

            S_PIXEL_PREP:begin
                if (pixel_wait==2) begin
                    pixel_wait<=0;
                    state<=S_PIXEL_SEND;
                end else pixel_wait<=pixel_wait+1'b1;
            end

            S_PIXEL_SEND:begin
                spi_dc<=1;
                spi_data<=
                    (!pixel_byte[0])?
                    color_word[15:8]:color_word[7:0];
                spi_start<=1;
                state<=S_PIXEL_WAIT;
            end

            S_PIXEL_WAIT:begin
                if (spi_done) begin
                    if (pixel_byte==153599) begin
                        pixel_byte<=0;
                        delay_count<=0;
                        state<=S_COLOR_HOLD;
                    end else begin
                        pixel_byte<=pixel_byte+1'b1;

                        if (pixel_byte[0]) begin
                            if (pixel_x==239) begin
                                pixel_x<=0;
                                pixel_y<=pixel_y+1'b1;
                            end else pixel_x<=pixel_x+1'b1;
                        end

                        state<=S_PIXEL_PREP;
                    end
                end
            end

            S_COLOR_HOLD:begin
                if (delay_count==4999999) begin
                    delay_count<=0;
                    direction<=detected_dir;
                    frame_class<=live_class;
                    frame_result_valid<=live_result_valid;
                        frame_icon_mode<=ps_control[13];
                    state<=S_RAMWR_SEND;
                end else delay_count<=delay_count+1'b1;
            end

            S_RAMWR_SEND:begin
                spi_dc<=0;
                spi_data<=8'h2C;
                spi_start<=1;
                state<=S_RAMWR_WAIT;
            end

            S_RAMWR_WAIT:begin
                if (spi_done) begin
                    pixel_byte<=0;
                    pixel_x<=0;
                    pixel_y<=0;
                    state<=S_PIXEL_PREP;
                end
            end

            default:state<=S_POWER_WAIT;
        endcase
    end

endmodule


// =========================================================
// 四麦克风定位核心
// 轴 0：FRONT / BACK
// 轴 1：RIGHT / LEFT
// =========================================================

module doa4_core #(
    parameter integer FB_MM=60,
    parameter integer LR_MM=60,
    parameter integer FRAME_LOG2=10,

    parameter integer ON_LEVEL=35,
    parameter integer OFF_LEVEL=17,

    parameter integer MIN_Q=4096,
    parameter integer MIN_VECTOR_Q2=2,

    parameter integer CONFIRM=2,
    parameter integer QUIET_N=6,
    parameter integer UNSURE_N=4,

    parameter integer CHECK_AMBIG=1,

    // 越大，越不容易把另一个峰判为歧义。
    parameter integer ALT_RATIO_Q8=240,

    parameter integer FLIP_FB=0,
    parameter integer FLIP_LR=0,

    parameter integer WARM_CYCLES=50000000
)(
    input wire clk,
    input wire valid,
    input wire signed [15:0] f,l,r,b,

    output reg [3:0] detected_dir=4,
    output reg [15:0] detected_level=0,

    output reg [63:0] levels=0,
    output reg signed [11:0] delay_x=0,
    output reg signed [11:0] delay_y=0,

    output reg [31:0] qualities=0,
    output reg [3:0] channel_ok=0,
    output reg [3:0] status=0
);

    // 声速按 343000 mm/s 估算。
    // 采样率与顶层保持一致，约 48828 Hz。
    localparam integer LF=(FB_MM*48828+342999)/343000;
    localparam integer LR=(LR_MM*48828+342999)/343000;

    localparam integer ML=((LF>LR)?LF:LR)+1;
    localparam integer LC=2*ML+1;

    localparam integer FRAME_N=(1<<FRAME_LOG2);
    localparam integer NC=FRAME_N-2*ML;

    localparam [3:0]
        IDLE=0,
        MAC=1,
        NORM=2,
        DIVIDE=3,
        SCORE=4,
        INTERP=5,
        SCAN=6,
        AXIS_DONE=7,
        PREP=8,
        ANGLE=9,
        DECIDE=10;

    function [15:0] abs16;
        input signed [15:0] x;
        begin
            abs16=x[15]?(~x+16'd1):x;
        end
    endfunction

    wire [15:0] amplitude[0:3];

    assign amplitude[0]=abs16(f);
    assign amplitude[1]=abs16(l);
    assign amplitude[2]=abs16(r);
    assign amplitude[3]=abs16(b);

    reg [31:0] sums[0:3];
    wire [31:0] sums_next[0:3];

    genvar g;
    generate
        for (g=0;g<4;g=g+1) begin:SUM
            assign sums_next[g]=sums[g]+amplitude[g];
        end
    endgenerate

    wire [31:0] total_next=
        sums_next[0]+sums_next[1]+
        sums_next[2]+sums_next[3];

    reg [31:0] warm=0;

    always @(posedge clk) begin
        if (warm<WARM_CYCLES)
            warm<=warm+1'b1;
    end

    // 两个音频缓冲区交替使用
    reg signed [15:0] mf[0:2*FRAME_N-1];
    reg signed [15:0] ml[0:2*FRAME_N-1];
    reg signed [15:0] mr[0:2*FRAME_N-1];
    reg signed [15:0] mb[0:2*FRAME_N-1];

    reg bank=0;
    reg ready_bank=0;
    reg block_ready=0;

    reg [FRAME_LOG2-1:0] wi=0;
    reg [15:0] ready_level=0;
    reg [15:0] work_level=0;
    reg [3:0] ready_mask=0;
    reg [3:0] work_mask=0;

    integer j;

    initial begin
        for (j=0;j<4;j=j+1)
            sums[j]=0;
    end

    always @(posedge clk) begin
        block_ready<=0;

        if (valid && warm>=WARM_CYCLES) begin
            mf[{bank,wi}]<=f;
            ml[{bank,wi}]<=l;
            mr[{bank,wi}]<=r;
            mb[{bank,wi}]<=b;

            wi<=wi+1'b1;

            if (wi==FRAME_N-1) begin
                ready_bank<=bank;
                bank<=~bank;
                block_ready<=1;

                // 四通道、整帧的平均绝对幅度
                ready_level<=total_next >> (FRAME_LOG2+2);

                for (j=0;j<4;j=j+1) begin
                    levels[j*16+:16]<=sums_next[j] >> FRAME_LOG2;

                    // 只表示本帧有非零幅度，不是硬件自检
                    ready_mask[j]<=(sums_next[j]>=FRAME_N);
                    sums[j]<=0;
                end
            end else begin
                for (j=0;j<4;j=j+1)
                    sums[j]<=sums_next[j];
            end
        end
    end

    reg [3:0] st=IDLE;
    reg rb=0;
    reg axis=0;

    reg [5:0] ki=0;
    reg [5:0] bi=0;
    reg [5:0] scan_i=0;
    reg [FRAME_LOG2-1:0] ni=0;

    reg signed [43:0] c_acc=0;
    reg signed [43:0] c_final=0;

    reg [43:0] ea_acc=0;
    reg [43:0] eb_acc=0;
    reg [43:0] ea_final=0;
    reg [43:0] eb_final=0;

    wire signed [11:0] lag=$signed({6'b0,ki})-ML;

    wire [FRAME_LOG2-1:0] ref_i=ni+ML;

    wire signed [FRAME_LOG2+1:0] mov_i=
        $signed({2'b0,ref_i})+lag;

    wire [FRAME_LOG2:0] aa={rb,ref_i};
    wire [FRAME_LOG2:0] bb={rb,mov_i[FRAME_LOG2-1:0]};

    wire signed [15:0] a=axis?mr[aa]:mf[aa];
    wire signed [15:0] z=axis?ml[bb]:mb[bb];

    wire signed [31:0] product=a*z;
    wire [31:0] a_square=a*a;
    wire [31:0] z_square=z*z;

    wire signed [43:0] c_next=
        c_acc+{{12{product[31]}},product};

    wire [43:0] ea_next=ea_acc+{12'b0,a_square};
    wire [43:0] eb_next=eb_acc+{12'b0,z_square};

    // 正相关的能量归一化平方：
    // score = 65536 * C*C / (EA*EB)
    wire [87:0] c_square=
        $signed(c_final)*$signed(c_final);

    wire [87:0] energy_product=ea_final*eb_final;

    reg [87:0] divisor=0;
    reg [103:0] number=0;
    reg [103:0] quotient=0;
    reg [88:0] remainder=0;
    reg [6:0] div_count=0;

    wire [88:0] rem_shift=
        {remainder[87:0],number[103]};

    wire ge=(rem_shift>={1'b0,divisor});

    wire [88:0] rem_next=
        ge?(rem_shift-{1'b0,divisor}):rem_shift;

    wire [103:0] quotient_next=
        {quotient[102:0],ge};

    reg [15:0] this_score=0;
    reg [15:0] best_score=0;
    reg [15:0] scores[0:LC-1];

    reg signed [11:0] lag_fb=0;
    reg signed [11:0] lag_rl=0;

    reg [15:0] q_fb=0;
    reg [15:0] q_rl=0;

    reg amb=0;
    reg amb_fb=0;
    reg amb_rl=0;

    // 峰值附近的四分之一采样点插值
    wire [15:0] left_score=
        (bi==0)?best_score:scores[bi-1'b1];

    wire [15:0] right_score=
        (bi==LC-1)?best_score:scores[bi+1'b1];

    wire signed [18:0] curvature=
        ($signed({3'b0,best_score})<<<1)
        -$signed({3'b0,left_score})
        -$signed({3'b0,right_score});

    wire signed [18:0] asymmetry=
        $signed({3'b0,right_score})
        -$signed({3'b0,left_score});

    wire [18:0] abs_asym=
        asymmetry[18]?-asymmetry:asymmetry;

    reg signed [3:0] frac;

    always @* begin
        frac=0;

        if (bi!=0 && bi!=LC-1 && curvature>0) begin
            if ((abs_asym<<2)>=curvature*3)
                frac=asymmetry[18]?-4'sd2:4'sd2;
            else if ((abs_asym<<2)>=curvature)
                frac=asymmetry[18]?-4'sd1:4'sd1;
        end
    end

    wire signed [11:0] integer_lag=
        $signed({6'b0,bi})-ML;

    wire signed [11:0] refined_lag=
        (integer_lag<<<2)+frac;

    // 只检查与主峰分离的另一个局部峰
    wire [15:0] local_left=
        (scan_i==0)?scores[scan_i]:scores[scan_i-1'b1];

    wire [15:0] local_right=
        (scan_i==LC-1)?scores[scan_i]:scores[scan_i+1'b1];

    wire local_peak=
        (scores[scan_i]>=local_left) &&
        (scores[scan_i]>=local_right) &&
        ((scores[scan_i]>local_left) ||
         (scores[scan_i]>local_right));

    wire separated=
        (scan_i+2<bi)||(scan_i>bi+2);

    wire close_peak=
        (scores[scan_i]*256>=best_score*ALT_RATIO_Q8);

    reg signed [11:0] use_x=0,use_y=0;
    reg [31:0] nx=0,ny=0;

    reg data_ok=0;
    reg q_ok=0;
    reg range_ok=0;
    reg vector_ok=0;
    reg ambiguous=0;

    wire signed [11:0] corrected_x=
        FLIP_LR?-lag_rl:lag_rl;

    wire signed [11:0] corrected_y=
        FLIP_FB?-lag_fb:lag_fb;

    wire [11:0] ax=
        corrected_x[11]?-corrected_x:corrected_x;

    wire [11:0] ay=
        corrected_y[11]?-corrected_y:corrected_y;

    // 八方向边界约为 22.5° 和 67.5°
    wire diagonal=
        (nx!=0)&&(ny!=0)&&
        (nx*256>=ny*106)&&
        (ny*256>=nx*106);

    reg [3:0] candidate;

    always @* begin
        if (diagonal) begin
            if (use_y>0)
                candidate=(use_x>0)?7:6;
            else
                candidate=(use_x>0)?9:8;
        end else if (ny>=nx) begin
            candidate=(use_y>0)?1:3;
        end else begin
            candidate=(use_x>0)?2:0;
        end
    end

    reg [3:0] chosen=4;
    reg [3:0] reason=0;
    reg [3:0] pending=4;

    reg chosen_ok=0;
    reg [7:0] votes=0;
    reg [7:0] quiet_count=0;
    reg [7:0] bad_count=0;

    always @(posedge clk) begin
        case (st)
            IDLE:begin
                if (block_ready) begin
                    rb<=ready_bank;
                    work_level<=ready_level;
                    work_mask<=ready_mask;

                    axis<=0;
                    ki<=0;
                    bi<=ML;
                    ni<=0;

                    c_acc<=0;
                    ea_acc<=0;
                    eb_acc<=0;
                    best_score<=0;

                    st<=MAC;
                end
            end

            MAC:begin
                if (ni==NC-1) begin
                    c_final<=c_next;
                    ea_final<=ea_next;
                    eb_final<=eb_next;
                    st<=NORM;
                end else begin
                    ni<=ni+1'b1;
                    c_acc<=c_next;
                    ea_acc<=ea_next;
                    eb_acc<=eb_next;
                end
            end

            NORM:begin
                if (c_final<=0 || ea_final==0 || eb_final==0) begin
                    this_score<=0;
                    st<=SCORE;
                end else begin
                    divisor<=energy_product;
                    number<={c_square,16'b0};
                    quotient<=0;
                    remainder<=0;
                    div_count<=0;
                    st<=DIVIDE;
                end
            end

            DIVIDE:begin
                remainder<=rem_next;
                number<={number[102:0],1'b0};
                quotient<=quotient_next;

                if (div_count==103) begin
                    this_score<=
                        (|quotient_next[103:16])?
                        16'hFFFF:quotient_next[15:0];

                    st<=SCORE;
                end else div_count<=div_count+1'b1;
            end

            SCORE:begin
                scores[ki]<=this_score;

                if (this_score>best_score) begin
                    best_score<=this_score;
                    bi<=ki;
                end

                if (ki==LC-1) begin
                    st<=INTERP;
                end else begin
                    ki<=ki+1'b1;
                    ni<=0;
                    c_acc<=0;
                    ea_acc<=0;
                    eb_acc<=0;
                    st<=MAC;
                end
            end

            INTERP:begin
                if (!axis) begin
                    lag_fb<=refined_lag;
                    q_fb<=best_score;
                end else begin
                    lag_rl<=refined_lag;
                    q_rl<=best_score;
                end

                scan_i<=0;
                amb<=0;
                st<=SCAN;
            end

            SCAN:begin
                if (separated && local_peak &&
                    close_peak && scores[scan_i]>=MIN_Q)
                    amb<=1;

                if (scan_i==LC-1)
                    st<=AXIS_DONE;
                else
                    scan_i<=scan_i+1'b1;
            end

            AXIS_DONE:begin
                if (!axis) begin
                    amb_fb<=amb;

                    axis<=1;
                    ki<=0;
                    bi<=ML;
                    ni<=0;

                    c_acc<=0;
                    ea_acc<=0;
                    eb_acc<=0;
                    best_score<=0;

                    st<=MAC;
                end else begin
                    amb_rl<=amb;
                    st<=PREP;
                end
            end

            PREP:begin
                use_x<=corrected_x;
                use_y<=corrected_y;

                // 比较 |dx|/LR_MM 和 |dy|/FB_MM
                nx<=ax*FB_MM;
                ny<=ay*LR_MM;

                data_ok<=(work_mask==4'b1111);
                q_ok<=(q_fb>=MIN_Q && q_rl>=MIN_Q);

                range_ok<=
                    (ax<=LR*4+2 && ay<=LF*4+2);

                vector_ok<=
                    (ax>=MIN_VECTOR_Q2 ||
                     ay>=MIN_VECTOR_Q2);

                ambiguous<=
                    (CHECK_AMBIG!=0)&&(amb_fb||amb_rl);

                delay_x<=corrected_x;
                delay_y<=corrected_y;

                qualities<={q_fb,q_rl};
                channel_ok<=work_mask;

                st<=ANGLE;
            end

            ANGLE:begin
                chosen<=candidate;

                chosen_ok<=
                    data_ok && q_ok && range_ok &&
                    vector_ok && !ambiguous;

                if (!data_ok)
                    reason<=5;
                else if (!q_ok)
                    reason<=3;
                else if (!range_ok)
                    reason<=8;
                else if (ambiguous)
                    reason<=6;
                else if (!vector_ok)
                    reason<=4;
                else
                    reason<=2;

                st<=DECIDE;
            end

            DECIDE:begin
                st<=IDLE;
                detected_level<=work_level;

                if (work_level>=ON_LEVEL) begin
                    quiet_count<=0;

                    if (chosen_ok) begin
                        bad_count<=0;

                        if (chosen==detected_dir) begin
                            status<=2;
                            votes<=0;
                            pending<=chosen;

                        end else if (chosen==pending) begin
                            if (votes>=CONFIRM-1) begin
                                detected_dir<=chosen;
                                votes<=0;
                                status<=2;
                            end else begin
                                votes<=votes+1'b1;
                                status<=7;
                            end

                        end else begin
                            pending<=chosen;
                            votes<=1;
                            status<=7;

                            if (CONFIRM<=1) begin
                                detected_dir<=chosen;
                                status<=2;
                            end
                        end
                    end else begin
                        votes<=0;
                        status<=reason;

                        if (bad_count<250)
                            bad_count<=bad_count+1'b1;

                        if (detected_dir==4 ||
                            bad_count>=UNSURE_N-1)
                            detected_dir<=5;
                    end

                end else if (work_level<=OFF_LEVEL) begin
                    votes<=0;
                    bad_count<=0;

                    if (quiet_count<250)
                        quiet_count<=quiet_count+1'b1;

                    if (quiet_count>=QUIET_N-1) begin
                        detected_dir<=4;
                        detected_level<=0;
                        status<=1;
                    end

                end else begin
                    quiet_count<=0;
                    votes<=0;
                end
            end

            default:st<=IDLE;
        endcase
    end

endmodule


// =========================================================
// 一阶高通滤波 + Q8 增益 + 最终饱和
//
// y[n] = (1 - 2^-SHIFT) * y[n-1]
//        + x[n] - x[n-1]
//
// 内部状态为 34 位 Q8。
// 乘 Q8 增益后得到 Q16，最后转回有符号 16 位。
// =========================================================

module audio_hp_q8 #(
    parameter integer ENABLE=1,
    parameter integer SHIFT=5,
    parameter integer GAIN_Q8=256
)(
    input wire clk,
    input wire valid_in,
    input wire signed [15:0] sample_in,

    output reg valid_out=0,
    output reg signed [15:0] sample_out=0
);

    reg signed [33:0] x_prev=0;
    reg signed [33:0] y_prev=0;
    reg signed [33:0] filtered=0;

    reg stage_valid=0;

    // 先显式扩展，再表示为 Q8，避免窄位宽左移溢出
    wire signed [33:0] x_q8=
        {{10{sample_in[15]}},sample_in,8'b0};

    wire signed [33:0] hp_next=
        y_prev-(y_prev>>>SHIFT)+x_q8-x_prev;

    wire signed [65:0] amplified=
        filtered*$signed(GAIN_Q8);

    function signed [15:0] saturate;
        input signed [65:0] v;
        reg signed [65:0] q;
        begin
            q=v>>>16;

            if (q>66'sd32767)
                saturate=16'sh7FFF;
            else if (q < -66'sd32768)
                saturate=16'sh8000;
            else
                saturate=q[15:0];
        end
    endfunction

    always @(posedge clk) begin
        stage_valid<=valid_in;
        valid_out<=stage_valid;

        if (valid_in) begin
            x_prev<=x_q8;
            y_prev<=hp_next;
            filtered<=(ENABLE!=0)?hp_next:x_q8;
        end

        if (stage_valid)
            sample_out<=saturate(amplified);
    end

endmodule

// Embedded graphics: no external MEM paths or asset downloads are required.
// One synchronous ROM row read; caller waits the existing pixel-prep cycles.
module sound_ui_rom(
    input wire clk,
    input wire [9:0] icon_addr,
    input wire [6:0] icon_x,
    input wire [9:0] text_addr,
    input wire [7:0] text_x,
    output wire [3:0] icon_index,
    output wire text_on
);
    (* rom_style="block" *) reg [383:0] icons[0:959];
    (* rom_style="block" *) reg [223:0] texts[0:767];
    reg [383:0] icon_row=0;
    reg [223:0] text_row=0;
    reg [6:0] icon_x_q=0;
    reg [7:0] text_x_q=0;
    initial begin
        icons[0]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[1]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[2]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[3]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[4]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[5]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[6]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[7]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[8]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[9]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[10]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[11]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[12]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[13]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[14]=384'h00cccccccccccccccccccccccccccccccccccccccc11111111cccccccccccccccccccccccccccccccccccccccccccc00;
        icons[15]=384'h0ccccccccccccccccccccccccccccccccccccccc111111111111ccccccccccccccccccccccccccccccccccccccccccc0;
        icons[16]=384'h0ccccccccccccccccccccccccccccccccccccc1111111111111111ccccccccccccccccccccccccccccccccccccccccc0;
        icons[17]=384'h0ccccccccccccccccccccccccccccccccccc11111111111111111111ccccccccccccccccccccccccccccccccccccccc0;
        icons[18]=384'h0cccccccccccccccccccccccccccccccccc1111111111111111111111ccccccccccccccccccccccccaacccccccccccc0;
        icons[19]=384'h0ccccccccccccccccccccccccccccccccc111111111cccccc111111111ccccccccccccccccccccccaaaaccccccccccc0;
        icons[20]=384'h0cccccccccccccccccccccccccccccccc1111111cccccccccccc1111111cccccccccccccccccccccaaaaacccccccccc0;
        icons[21]=384'h0ccccccccccccccccccccccccccccccc1111111cccccccccccccc1111111cccccccccccccccccccccaaaacccccccccc0;
        icons[22]=384'h0cccccccccccccccccccccccccccccc1111111cccccccccccccccc1111111ccccccccccccccccccccaaaaaccccccccc0;
        icons[23]=384'h0cccccccccccccccccccccccccccccc111111cccccccccccccccccc111111cccccccccccccccccccccaaaaccccccccc0;
        icons[24]=384'h0ccccccccccccccccccccccccccccc111111cccccccccccccccccccc111111cccccccccccccccccccccaaaacccccccc0;
        icons[25]=384'h0ccccccccccccccccccccccccccccc11111cccccccccccccccccccccc11111cccccccccccccccccccccaaaacccccccc0;
        icons[26]=384'h0cccccccccccccccccccccccccccc111111cccccccccccccccccccccc111111cccccccccaaccccccccccaaaaccccccc0;
        icons[27]=384'h0cccccccccccccccccccccccccccc11111cccccccccc22222ccccccccc11111ccccccccaaaacccccccccaaaaccccccc0;
        icons[28]=384'h0ccccccccccccccccccccccccccc11111ccccccccc222222222cccccccc11111cccccccaaaaacccccccccaaaacccccc0;
        icons[29]=384'h0ccccccccccccccccccccccccccc11111cccccccc22222222222ccccccc11111ccccccccaaaaaccccccccaaaacccccc0;
        icons[30]=384'h0cccccccccccccccccccccccccc111111ccccccc2222222222222cccccc111111ccccccccaaaaccccccccaaaacccccc0;
        icons[31]=384'h0cccccccccccccccccccccccccc11111ccccccc22222ccccc22222cccccc11111cccccccccaaaaccccccccaaaaccccc0;
        icons[32]=384'h0cccccccccccccccccccccccccc11111cccccc22222ccccccc22222ccccc11111cccccccccaaaaacccccccaaaaccccc0;
        icons[33]=384'h0ccccccccccccccccccccccccc11111ccccccc2222ccccccccc2222cccccc11111cccccccccaaaacccccccaaaaccccc0;
        icons[34]=384'h0ccccccccccccccccccccccccc11111cccccc22222ccccccccc22222ccccc11111cccccccccaaaaacccccccaaaacccc0;
        icons[35]=384'h0ccccccccccccccccccccccccc11111cccccc2222ccccccccccc2222ccccc11111ccccccccccaaaacccccccaaaacccc0;
        icons[36]=384'h0ccccccccccccccccccccccccc11111ccccc22222ccccccccccc22222cccc11111ccccccccccaaaacccccccaaaacccc0;
        icons[37]=384'h0ccccccccccccccccccccccccc11111ccccc2222ccccccccccccc2222cccc11111ccccccccccaaaaaccccccaaaacccc0;
        icons[38]=384'h0cccccccccccccccccccccccc11111cccccc2222ccccccccccccc2222ccccc11111ccccccccccaaaaccccccaaaacccc0;
        icons[39]=384'h0ccccccccccccccccccccccccccccccccccc2222ccccccccccccc2222ccccc11111ccccccccccaaaaccccccaaaacccc0;
        icons[40]=384'h0cccccccccccccccccccccccccccccccccc2222ccccccccccccccc2222cccc11111ccccccccccaaaacccccccaaaaccc0;
        icons[41]=384'h0cccccccccccccccccccccccccccccccccc2222ccccccccccccccc2222cccc11111ccccccccccaaaacccccccaaaaccc0;
        icons[42]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[43]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[44]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[45]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[46]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[47]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[48]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[49]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccccc2222cccc11111cccccccccccaaaaccccccaaaaccc0;
        icons[50]=384'h0ccccccccccccccccccccccccc11111cccccccccccccccccccccc2222cccc11111ccccccccccccaaaaccccccaaaaccc0;
        icons[51]=384'h0ccccccccccccccccccccccccc11111cccccccccccccccccccccc2222cccc11111ccccccccccccaaaaccccccaaaaccc0;
        icons[52]=384'h0ccccccccccccccccccccccccc11111cccccccccccccccccccccc2222cccc11111ccccccccccccaaaaccccccaaaaccc0;
        icons[53]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccc22222cccc11111cccccccccccaaaacccccccaaaaccc0;
        icons[54]=384'h0ccccccccccccccccccccccccc11111ccccccccccccccccccccc2222ccccc11111cccccccccccaaaacccccccaaaaccc0;
        icons[55]=384'h0ccccccccccccccccccccccccc111111ccccccccccccccccccc22222cccc11111ccccccccccccaaaaccccccaaaacccc0;
        icons[56]=384'h0ccccccccccccccccccccccccc111111ccccccccccccccccccc2222ccccc11111ccccccccccccaaaaccccccaaaacccc0;
        icons[57]=384'h0ccccccccccccccccccccccccc1111111ccccccccccccccccc22222cccc111111cccccccccccaaaaaccccccaaaacccc0;
        icons[58]=384'h0ccccccccccccccccccccccccc1111111cccccccccccccccc22222ccccc11111ccccccccccccaaaacccccccaaaacccc0;
        icons[59]=384'h0ccccccccccccccccccccccccc1111111cccccccccccc22222222cccccc11111ccccccccccccaaaacccccccaaaacccc0;
        icons[60]=384'h0ccccccccccccccccccccccccc11111111cccccccccc22222222cccccc11111ccccccccccccaaaaacccccccaaaacccc0;
        icons[61]=384'h0ccccccccccccccccccccccccc111111111ccccccccc2222222cccccc111111ccccccccccccaaaacccccccaaaaccccc0;
        icons[62]=384'h0ccccccccccccccccccccccccc111111111ccccccccc22222cccccccc11111ccccccccccccaaaaacccccccaaaaccccc0;
        icons[63]=384'h0ccccccccccccccccccccccccc1111111111cccccccccccccccccccc111111ccccccccccccaaaaccccccccaaaaccccc0;
        icons[64]=384'h0ccccccccccccccccccccccccc11111111111cccccccccccccccccc111111ccccccccccccaaaaccccccccaaaacccccc0;
        icons[65]=384'h0cccccccccccccccccccccccccc11111111111cccccccccccccccc1111111cccccccccccaaaaaccccccccaaaacccccc0;
        icons[66]=384'h0cccccccccccccccccccccccccc111111111111cccccccccccccc1111111cccccccccccaaaaacccccccccaaaacccccc0;
        icons[67]=384'h0ccccccccccccccccccccccccccc111111111111cccccccccccc1111111ccccccccccccaaaacccccccccaaaaccccccc0;
        icons[68]=384'h0ccccccccccccccccccccccccccc111111111111111cccccc111111111ccccccccccccccaaccccccccccaaaaccccccc0;
        icons[69]=384'h0cccccccccccccccccccccccccccc1111111111111111111111111111ccccccccccccccccccccccccccaaaacccccccc0;
        icons[70]=384'h0ccccccccccccccccccccccccccccc11111111111111111111111111cccccccccccccccccccccccccccaaaacccccccc0;
        icons[71]=384'h0ccccccccccccccccccccccccccccc1111111c11111111111111111cccccccccccccccccccccccccccaaaaccccccccc0;
        icons[72]=384'h0cccccccccccccccccccccccccccccc111111ccc11111111111111cccccccccccccccccccccccccccaaaaaccccccccc0;
        icons[73]=384'h0ccccccccccccccccccccccccccccccc111111cccc11111111111ccccccccccccccccccccccccccccaaaacccccccccc0;
        icons[74]=384'h0ccccccccccccccccccccccccccccccc111111cccccccccc11111cccccccccccccccccccccccccccaaaaacccccccccc0;
        icons[75]=384'h0cccccccccccccccccccccccccccccccc1111111111111111111ccccccccccccccccccccccccccccaaaaccccccccccc0;
        icons[76]=384'h0cccccccccccccccccccccccccccccccc111111111111111111ccccccccccccccccccccccccccccccaacccccccccccc0;
        icons[77]=384'h0ccccccccccccccccccccccccccccccccc1111111111111111ccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[78]=384'h0ccccccccccccccccccccccccccccccccccc1111111111111cccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[79]=384'h0cccccccccccccccccccccccccccccccccccccccccccccc1ccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[80]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[81]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[82]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[83]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[84]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[85]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[86]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[87]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[88]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[89]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[90]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[91]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[92]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[93]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[94]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[95]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[96]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[97]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[98]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[99]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[100]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[101]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[102]=384'h0000000ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3333333333ccccccccccccccc0000000;
        icons[103]=384'h000000ccccccccccccccccccccccccccccccccccccccccccccccccccccccc3333333333333333ccccccccccccc000000;
        icons[104]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccc333333cccccccc333333cccccccccccc00000;
        icons[105]=384'h0000ccccccccccccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccc3333ccccccccccc0000;
        icons[106]=384'h000ccccccccccccccccccccccccccccccccccccccccccccccccccccc333cccccc3333333ccccccc333ccccccccccc000;
        icons[107]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccc333ccccc33333333333cccccc333cccccccccc000;
        icons[108]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccc333ccccc3333333333333cccccc333cccccccccc00;
        icons[109]=384'h00ccccccccccccccccccccccccccccccccccccccccccccccccccc333ccccc333333333333333cccccc333ccccccccc00;
        icons[110]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccc333ccccc33333333333333333cccccc333cccccccc00;
        icons[111]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccc33ccccc3333333333333333333cccccc33ccccccccc0;
        icons[112]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccc33ccccc333333333333333333333cccccc33cccccccc0;
        icons[113]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccc3ccccc333333333333333333333cccccc3ccccccccc0;
        icons[114]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333333333333333333333cccccccccccccccc0;
        icons[115]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccc33333333333333333333333ccccccccccccccc0;
        icons[116]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccc33333333333333333333333ccccccccccccccc0;
        icons[117]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccc333333333333333333333333333ccccccccccccc0;
        icons[118]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccc333333333333333333333333333ccccccccccccc0;
        icons[119]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccc333333333333333333333333333ccccccccccccc0;
        icons[120]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccc0;
        icons[121]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333333cccccccccccccccccccccccc0;
        icons[122]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333333cccccccccccccccccccccccc0;
        icons[123]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccc0;
        icons[124]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc111111111331ccccccccccccccccccccccccc0;
        icons[125]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccc11111111111111ccccccccccccccccccccccccc0;
        icons[126]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccc11111111111111ccccccccccccccccccccccccc0;
        icons[127]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccc1111111111111ccccccccccccccccccccccccc0;
        icons[128]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccc1111cccccccccccccccccccccccccccccccccc0;
        icons[129]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccc1111cccccccccccccccccccccccccccccccccc0;
        icons[130]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccc11111ccccccccccccccccccccccccccccccccc0;
        icons[131]=384'h0ccccccccccccccccccccccccccccccc1111111111111ccccccccccccc1111ccccccccccccccccccccccccccccccccc0;
        icons[132]=384'h0ccccccccccccccccccccccccccccccc1111111111111ccccccccccccc1111ccccccccccccccccccccccccccccccccc0;
        icons[133]=384'h0ccccccccccccccccccccccccccccccc1111111111111ccccccccccccc1111ccccccccccccccccccccccccccccccccc0;
        icons[134]=384'h0ccccccccccccccccccccccccccccccc1111111111111ccccccccccccc11111cccccccccccccccccccccccccccccccc0;
        icons[135]=384'h0ccccccccccccccccccccccccccccccccc222222222cccccccccccccccc1111cccccccccccccccccccccccccccccccc0;
        icons[136]=384'h0ccccccccccccccccccccccccccccccccc2222222222ccccccccccccccc1222c2cccccccccccccccccccccccccccccc0;
        icons[137]=384'h0cccccccccccccccccccccccccccccccc22222c22222cccccccccccccc2222222cccccccccccccccccccccccccccccc0;
        icons[138]=384'h0ccccccccccccccccccccccccccccccc222222cc22222ccccccccccc2222222222ccccccccccccccccccccccccccccc0;
        icons[139]=384'h0ccccccccccccccccccccccccccccccc22222ccc22222ccccccccc222222222222ccccccccccccccccccccccccccccc0;
        icons[140]=384'h0cccccccccccccccccccccccccccccc22222ccccc22222ccccccc22222222c22222cccccccccccccccccccccccccccc0;
        icons[141]=384'h0cccccccccccccccccccccccccccccc22222ccccc222222cccc22222222cccc2222cccccccccccccccccccccccccccc0;
        icons[142]=384'h0ccccccccccccccccccccccccccccc22222ccccccc22222cc22222222cccccc22222ccccccccccccccccccccccccccc0;
        icons[143]=384'h0cccccccccccccccccccccccccccc222222cccccccc2222222222222cccccccc2222ccccccccccccccccccccccccccc0;
        icons[144]=384'h0cccccccccccccccccccccccccccc22222ccccccccc22222222222cccccccccc22222cccccccccccccccccccccccccc0;
        icons[145]=384'h0cccccccccccccccccc1111111cc22222ccccccccccc22222222ccccccccccccc2222c1111111cccccccccccccccccc0;
        icons[146]=384'h0ccccccccccccccc11111111111122222cccccccccc22222222cccccccccccccc222221111111111ccccccccccccccc0;
        icons[147]=384'h0ccccccccccccc111111111111122222ccccccccc222222222ccccccccccccccc12222111111111111ccccccccccccc0;
        icons[148]=384'h0cccccccccccc111111ccccccc122222ccccccc222222222222ccccccccccccc112222ccccccc111111cccccccccccc0;
        icons[149]=384'h0ccccccccccc1111cccccccccc2222211ccccc22222222222222ccccccccccc11112222ccccccccc1111ccccccccccc0;
        icons[150]=384'h0cccccccccc1111cccccccccc222222111cc22222222ccc22222cccccccccc1111c2222cccccccccc1111cccccccccc0;
        icons[151]=384'h0ccccccccc1111ccccccccccc22222c11122222222cccccc22222cccccccc1111cc22222cccccccccc1111ccccccccc0;
        icons[152]=384'h0cccccccc1111ccccccccccc22222ccc122222222ccccccc222222cccccc1111cccc2222ccccccccccc1111cccccccc0;
        icons[153]=384'h0cccccccc111cccccccccccc22222cc22222222cccccccccc22222cccccc111ccccc22222ccccccccccc111cccccccc0;
        icons[154]=384'h0ccccccc111cccccccccccc22222c22222222ccccccccccccc22222cccc111ccccccc2222cccccccccccc111ccccccc0;
        icons[155]=384'h0ccccccc111ccccccccccc222222222222221ccccccccccccc22222cccc111ccccccc22222ccccccccccc111ccccccc0;
        icons[156]=384'h0ccccccc111ccccccccccc222222222222111cccccccccccccc22222ccc111cccccccc2222ccccccccccc111ccccccc0;
        icons[157]=384'h0cccccc111ccccccccccc22222222222ccc111ccccccccccccc222222c111ccccccccc22222ccccccccccc111cccccc0;
        icons[158]=384'h0cccccc111ccccccccccc222222222222222222222222222222222222c111cccccccccc2222ccccccccccc111cccccc0;
        icons[159]=384'h0cccccc111cccccccccc22222222222222222222222222222222222222111cccccccccc22222cccccccccc111cccccc0;
        icons[160]=384'h0cccccc111cccccccccccc2222222222222222222222222222222222cc111ccccccccccc2222cccccccccc111cccccc0;
        icons[161]=384'h0cccccc111cccccccccccc2222222222222222222222222222222222cc111ccccccccccc2ccccccccccccc111cccccc0;
        icons[162]=384'h0cccccc111ccccccccccccc2ccccccccccc111cccccccccccccccccccc111ccccccccccccccccccccccccc111cccccc0;
        icons[163]=384'h0cccccc111ccccccccccccccccccccccccc111cccccccccccccccccccc111ccccccccccccccccccccccccc111cccccc0;
        icons[164]=384'h0ccccccc111ccccccccccccccccccccccc111cccccccccccccccccccccc111ccccccccccccccccccccccc111ccccccc0;
        icons[165]=384'h0ccccccc111ccccccccccccccccccccccc111cccccccccccccccccccccc111ccccccccccccccccccccccc111ccccccc0;
        icons[166]=384'h0ccccccc111ccccccccccccccccccccccc111cccccccccccccccccccccc111ccccccccccccccccccccccc111ccccccc0;
        icons[167]=384'h0cccccccc111ccccccccccccccccccccc111cccccccccccccccccccccccc111ccccccccccccccccccccc111cccccccc0;
        icons[168]=384'h0cccccccc1111ccccccccccccccccccc1111cccccccccccccccccccccccc1111ccccccccccccccccccc1111cccccccc0;
        icons[169]=384'h0ccccccccc1111ccccccccccccccccc1111cccccccccccccccccccccccccc1111ccccccccccccccccc1111ccccccccc0;
        icons[170]=384'h0cccccccccc1111ccccccccccccccc1111cccccccccccccccccccccccccccc1111ccccccccccccccc1111cccccccccc0;
        icons[171]=384'h0ccccccccccc1111ccccccccccccc1111cccccccccccccccccccccccccccccc1111ccccccccccccc1111ccccccccccc0;
        icons[172]=384'h0cccccccccccc111111ccccccc111111cccccccccccccccccccccccccccccccc111111ccccccc111111cccccccccccc0;
        icons[173]=384'h0ccccccccccccc11111111111111111cccccccccccccccccccccccccccccccccc11111111111111111ccccccccccccc0;
        icons[174]=384'h0ccccccccccccccc1111111111111cccccccccccccccccccccccccccccccccccccc1111111111111ccccccccccccccc0;
        icons[175]=384'h0cccccccccccccccccc1111111cccccccccccccccccccccccccccccccccccccccccccc1111111cccccccccccccccccc0;
        icons[176]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[177]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[178]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[179]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[180]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[181]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[182]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[183]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[184]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[185]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[186]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[187]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[188]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[189]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[190]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[191]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[192]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[193]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[194]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[195]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[196]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[197]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3330000000;
        icons[198]=384'h0000000ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3333000000;
        icons[199]=384'h000000ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333300000;
        icons[200]=384'h00000ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc33330000;
        icons[201]=384'h0000ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3330000;
        icons[202]=384'h000ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc33cccccc333000;
        icons[203]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc33333cccc333000;
        icons[204]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc33333cccc33300;
        icons[205]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3333ccc33300;
        icons[206]=384'h00ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333ccc33300;
        icons[207]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333ccc3330;
        icons[208]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333ccc3330;
        icons[209]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc3330;
        icons[210]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc3330;
        icons[211]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333ccc333;
        icons[212]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc3333cc333;
        icons[213]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc333;
        icons[214]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc333;
        icons[215]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc333;
        icons[216]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc333;
        icons[217]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc333;
        icons[218]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc333;
        icons[219]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc333cc333;
        icons[220]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444cccccccccccccccccccccc333cc333;
        icons[221]=384'h0cccccccccccccccccccccccc444444444444444444444444444444444444444444cccccccccccccccccccc3333cc333;
        icons[222]=384'h0ccccccccccccccccccccccc4444444444444444444444444444444444444444444cccccccccccccccccccc333ccc333;
        icons[223]=384'h0ccccccccccccccccccccccc44444444444444444444444444444444444444444444ccccccccccccccccccc333cc3330;
        icons[224]=384'h0cccccccccccccccccccccc4444444eeeeeeeeeeee4444eeeeeeeeeeeeeeee444444ccccccccccccccccccc333cc3330;
        icons[225]=384'h0cccccccccccccccccccccc4444444eeeeeeeeeeee4444eeeeeeeeeeeeeeeee444444ccccccccccccccccc333ccc3330;
        icons[226]=384'h0ccccccccccccccccccccc4444444eeeeeeeeeeeee4444eeeeeeeeeeeeeeeee4444444cccccccccccccccc333ccc3330;
        icons[227]=384'h0ccccccccccccccccccccc4444444eeeeeeeeeeeee4444eeeeeeeeeeeeeeeeee444444ccccccccccccccc333ccc333c0;
        icons[228]=384'h0cccccccccccccccccccc4444444eeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeee4444444ccccccccccccc3333ccc333c0;
        icons[229]=384'h0cccccccccccccccccccc4444444eeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeee444444ccccccccccc33333cccc333c0;
        icons[230]=384'h0ccccccccccccccccccc4444444eeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeee4444444ccccccccc33333cccc333cc0;
        icons[231]=384'h0ccccccccccccccccccc4444444eeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeeee4444444ccccccccc33cccccc333cc0;
        icons[232]=384'h0cccccccccccccccccc4444444eeeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeeeee444444cccccccccccccccc333ccc0;
        icons[233]=384'h0cccccccccccccccccc4444444eeeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeeeee4444444cccccccccccccc3333ccc0;
        icons[234]=384'h0ccccccccccccccccc4444444eeeeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeeeeee444444ccccccccccccc3333cccc0;
        icons[235]=384'h0ccccccccccccccccc4444444eeeeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeeeeee4444444ccccccccccc3333ccccc0;
        icons[236]=384'h0cccccccccccccccc4444444eeeeeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeeeeeee4444444cccccccccc333cccccc0;
        icons[237]=384'h0cccccccccccccccc4444444eeeeeeeeeeeeeeeeee4444eeeeeeeeeeeeeeeeeeeeeee4444444ccccccccccccccccccc0;
        icons[238]=384'h0cccccccccccccc44444444444444444444444444444444444444444444444444444444444444cccccccccccccccccc0;
        icons[239]=384'h0cccccccccccc444444444444444444444444444444444444444444444444444444444444444444cccccccccccccccc0;
        icons[240]=384'h0ccccccccccc44444444444444444444444444444444444444444444444444444444444444444444ccccccccccccccc0;
        icons[241]=384'h0cccccccccc4444444444444444444444444444444444444444444444444444444444444444444444cccccccccccccc0;
        icons[242]=384'h0cccccccccc4444444444444444444444444444444444444444444444444444444444444444444444cccccccccccccc0;
        icons[243]=384'h0ccccccccc444444444444444444444444444444444444444444444444444444444444444444444444ccccccccccccc0;
        icons[244]=384'h0ccccccccc444444444444444444444444444444444444444444444444444444444444444444444444ccccccccccccc0;
        icons[245]=384'h0ccccccccc444444333333333333344444444444444444444444444444444444433333333333344444ccccccccccccc0;
        icons[246]=384'h0ccccccccc444444333333333333344444444444444444444444444444444444433333333333344444ccccccccccccc0;
        icons[247]=384'h0ccccccccc444444333333333333344444444444444444444444444444444444433333333333344444ccccccccccccc0;
        icons[248]=384'h0ccccccccc444444333333333333344444444444444444444444444444444444433333333333344444ccccccccccccc0;
        icons[249]=384'h0ccccccccc444444333333333333344444444444444444444444444444444444433333333333344444ccccccccccccc0;
        icons[250]=384'h0ccccccccc444444333333333333344444444444444444444444444444444444433333333333344444ccccccccccccc0;
        icons[251]=384'h0ccccccccc444444444444444444444444444444444444444444444444444444444444444444444444ccccccccccccc0;
        icons[252]=384'h0ccccccccc444444444444444444444444444444444444444444444444444444444444444444444444ccccccccccccc0;
        icons[253]=384'h0ccccccccc444444444444444444444444444444444444444444444444444444444444444444444444ccccccccccccc0;
        icons[254]=384'h0ccccccccc444444444444444444444444444444444444444444444444444444444444444444444444ccccccccccccc0;
        icons[255]=384'h0ccccccccc444444444444444444444444444444444444444444444444444444444444444444444444ccccccccccccc0;
        icons[256]=384'h0ccccccccc444444444444444999994444444444444444444444444444444444999994444444444444ccccccccccccc0;
        icons[257]=384'h0ccccccccc444444444444499999999944441111111111111111111114444499999999944444444444ccccccccccccc0;
        icons[258]=384'h0ccccccccc444444444444999999999994441111111111111111111114444999999999994444444444ccccccccccccc0;
        icons[259]=384'h0cccccccccc4444444444999999999999944111111111111111111111444999999999999944444444cccccccccccccc0;
        icons[260]=384'h0cccccccccc4444444444999999999999944444444444444444444444444999999999999944444444cccccccccccccc0;
        icons[261]=384'h0ccccccccccc44444444999999999999999444444444444444444444444999999999999999444444ccccccccccccccc0;
        icons[262]=384'h0cccccccccccc444444499999999999999944444444444444444444444499999999999999944444cccccccccccccccc0;
        icons[263]=384'h0cccccccccccccc44444999999999999999444444444444444444444444999999999999999444cccccccccccccccccc0;
        icons[264]=384'h0ccccccccccccccccccc999999999999999cccccccccccccccccccccccc999999999999999ccccccccccccccccccccc0;
        icons[265]=384'h0ccccccccccccccccccc999999999999999cccccccccccccccccccccccc999999999999999ccccccccccccccccccccc0;
        icons[266]=384'h0ccccccccccccccccccc999999999999999cccccccccccccccccccccccc999999999999999ccccccccccccccccccccc0;
        icons[267]=384'h0cccccccccccccccccccc9999999999999cccccccccccccccccccccccccc9999999999999cccccccccccccccccccccc0;
        icons[268]=384'h0cccccccccccccccccccc9999999999999cccccccccccccccccccccccccc9999999999999cccccccccccccccccccccc0;
        icons[269]=384'h0ccccccccccccccccccccc99999999999cccccccccccccccccccccccccccc99999999999ccccccccccccccccccccccc0;
        icons[270]=384'h0cccccccccccccccccccccc999999999cccccccccccccccccccccccccccccc999999999cccccccccccccccccccccccc0;
        icons[271]=384'h0cccccccccccccccccccccccc99999cccccccccccccccccccccccccccccccccc99999cccccccccccccccccccccccccc0;
        icons[272]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[273]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[274]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[275]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[276]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[277]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[278]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[279]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[280]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[281]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[282]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[283]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[284]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[285]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[286]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[287]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[288]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[289]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[290]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[291]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[292]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[293]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[294]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[295]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[296]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[297]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[298]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[299]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[300]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccc3ccccccccccccccccccccccccccccccccccc00;
        icons[301]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccccccc00;
        icons[302]=384'h00ccccccccccccccccccccccccccccccccccccccccccccccccccccc3333333cccccccccccccccccccccccccccccccc00;
        icons[303]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccc3333333333cccccccccccccccccccccccccccccccc0;
        icons[304]=384'h0ccccccccccccccccccccccccccccccccccccccccccccccccccc333333333333ccccccccccccccccccccccccccccccc0;
        icons[305]=384'h0ccccccccccccccccc6ccccccccccccccccccccccccccccccc333333333333333cccccccccccccccccccccccccccccc0;
        icons[306]=384'h0cccccccccccccccc666ccccccccccccccccccccccccccccc333333333333333333cccccccccccccccccccccccccccc0;
        icons[307]=384'h0ccccccccccccccc66666cccccccccccccccccccccccccc333333333333333333333ccccccccccccccccccccccccccc0;
        icons[308]=384'h0cccccccccccccc6666666ccccccccccccccccccccccccc3333333333333333333333cccccccccccccccccccccccccc0;
        icons[309]=384'h0ccccccccccccc66666616cccccccccccccccccccccccc333333333333333333333333ccccccccccccccccccccccccc0;
        icons[310]=384'h0cccccccccccc6666661116ccccccccccccccccccccccc33333333333333333333333333ccccccccccccccccccccccc0;
        icons[311]=384'h0ccccccccccc666666661116ccccccccccccccccccccc3333333333333333333333333333cccccccccccccccccccccc0;
        icons[312]=384'h0cccccccccc66666666661166cccccccccccccccccccc33333333333333333333333333333ccccccccccccccccccccc0;
        icons[313]=384'h0ccccccccc6666666666611166cccccccccccccccccc3333333333333333333333333333333cccccccccccccccccccc0;
        icons[314]=384'h0cccccccccc6666666666611166ccccccccccccccccc333333333333333333333333333333333cccccccccccccccccc0;
        icons[315]=384'h0ccccccccccc6666666666611166ccccccccccccccc33333333333333333333333333333333333ccccccccccccccccc0;
        icons[316]=384'h0cccccccccccc6666666666611166cccccccccccccc333333333333333333333333333333333333cccccccccccccccc0;
        icons[317]=384'h0ccccccccccccc666666666661166ccccccccccccc33333333333333333333333333333333333333ccccccccccccccc0;
        icons[318]=384'h0ccccccccccccc6666666666611166cccccccccccc3333333333333333333333333333333333333333ccccccccccccc0;
        icons[319]=384'h0cccccccccccccc6666666666611166cccccccccccc3333333333333333333333333333333333333333cccccccccccc0;
        icons[320]=384'h0ccccccccccccccc6666666666611166cccccccccccc33333333333333333333333333333333333333ccccccccccccc0;
        icons[321]=384'h0cccccccccccccccc6666666666611166cccccccccccc3333333333333333333333333333333333333ccccccccccccc0;
        icons[322]=384'h0ccccccccccccccccc6666666666611666ccccccccccccc3333333333333333333333333333333333cccccccccccccc0;
        icons[323]=384'h0cccccccccccccccccc6666666666111666ccccccccccccc33333333333333333333333333333333ccccccccccccccc0;
        icons[324]=384'h0ccccccccccccccccccc6666666666111666ccccccccccccc3333333333888833333333333333333ccccccccccccccc0;
        icons[325]=384'h0cccccccccccccccccccc666666666611166cccccccccccccc33333388888888333333333333333cccccccccccccccc0;
        icons[326]=384'h0ccccccccccccccccccccc666666666611666ccccccccccccc8388888888888888333333333333ccccccccccccccccc0;
        icons[327]=384'h0cccccccccccccccccccccc666666666611666ccccccccccc8888888888888888cc3333333333cccccccccccccccccc0;
        icons[328]=384'h0cccccccccccccccccccccc6666666666111666cccccccccc888888888888888cccc333333333cccccccccccccccccc0;
        icons[329]=384'h0ccccccccccccccccccccccc6666666666111666cccccccc8888888888888888ccccc3333333ccccccccccccccccccc0;
        icons[330]=384'h0cccccccccccccccccccccccc6666666666111666cccccc8888888888888888cccccccc3333cccccccccccccccccccc0;
        icons[331]=384'h0ccccccccccccccccccccccccc6666666666116666ccccc888888888888888cccccccccc333cccccccccccccccccccc0;
        icons[332]=384'h0cccccccccccccccccccccccccc6666666661116666ccc8888888888888888ccccccccccc3ccccccccccccccccccccc0;
        icons[333]=384'h0ccccccccccccccccccccccccccc666666666111666cc8888888888888888cccccccccccccccccccccccccccccccccc0;
        icons[334]=384'h0cccccccccccccccccccccccccccc666666666111666c888888888888888ccccccccccccccccccccccccccccccccccc0;
        icons[335]=384'h0ccccccccccccccccccccccccccccc666666666111666888888888888888ccccccccccccccccccccccccccccccccccc0;
        icons[336]=384'h0cccccccccccccccccccccccccccccc6666666661166668888888888888cccccccccccccccccccccccccccccccccccc0;
        icons[337]=384'h0ccccccccccccccccccccccccccccccc66666666111666688888888888ccccccccccccccccccccccccccccccccccccc0;
        icons[338]=384'h0ccccccccccccccccccccccccccccccc66666666611166668888888888ccccccccccccccccccccccccccccccccccccc0;
        icons[339]=384'h0cccccccccccccccccccccccccccccccc666666666111666688888888cccccccccccccccccccccccccccccccccccccc0;
        icons[340]=384'h0ccccccccccccccccccccccccccccccccc6666666661116666888888ccccccccccccccccccccccccccccccccccccccc0;
        icons[341]=384'h0cccccccccccccccccccccccccccccccccc666666666116666888888ccccccccccccccccccccccccccccccccccccccc0;
        icons[342]=384'h0ccccccccccccccccccccccccccccccccccc6666666611166668888cccccccccccccccccccccccccccccccccccccccc0;
        icons[343]=384'h0cccccccccccccccccccccccccccccccccccc66666666111666688ccccccccccccccccccccccccccccccccccccccccc0;
        icons[344]=384'h0ccccccccccccccccccccccccccccccccccccc6666666615666668ccccccccccccccccccccccccccccccccccccccccc0;
        icons[345]=384'h0ccccccccccccccccccccccccccccccccccccc866666665556668cccccccccccccccccccccccccccccccccccccccccc0;
        icons[346]=384'h0cccccccccccccccccccccccccccccccccccc888666666555558ccccccccccccccccccccccccccccccccccccccccccc0;
        icons[347]=384'h0ccccccccccccccccccccccccccccccccccc8888866666655555ccccccccccccccccccccccccccccccccccccccccccc0;
        icons[348]=384'h0ccccccccccccccccccccccccccccccccccc88888666666555555cccccccccccccccccccccccccccccccccccccccccc0;
        icons[349]=384'h0cccccccccccccccccccccccccccccccccc8888888666666555555ccccccccccccccccccccccccccccccccccccccccc0;
        icons[350]=384'h0ccccccccccccccccccccccccccccccccc888888888666665555555cccccccccccccccccccccccccccccccccccccccc0;
        icons[351]=384'h0ccccccccccccccccccccccccccccccccc888888888866685555555cccccccccccccccccccccccccccccccccccccccc0;
        icons[352]=384'h0cccccccccccccccccccccccccccccccc88888888888868885555555ccccccccccccccccccccccccccccccccccccccc0;
        icons[353]=384'h0ccccccccccccccccccccccccccccccc8888888888888888c55555555cccccccccccccccccccccccccccccccccccccc0;
        icons[354]=384'h0ccccccccccccccccccccccccccccccc888888888888888cc55555555cccccccccccccccccccccccccccccccccccccc0;
        icons[355]=384'h0cccccccccccccccccccccccccccccc8888888888888888ccc55555555ccccccccccccccccccccccccccccccccccccc0;
        icons[356]=384'h0ccccccccccccccccccccccccccccc8888888888888888cccc55555555ccccccccccccccccccccccccccccccccccccc0;
        icons[357]=384'h0ccccccccccccccccccccccccccccc888888888888888cccccc55555555cccccccccccccccccccccccccccccccccccc0;
        icons[358]=384'h0cccccccccccccccccccccccccccc8888888888888888cccccc555555555ccccccccccccccccccccccccccccccccccc0;
        icons[359]=384'h0ccccccccccccccccccccccccccc8888888888888888ccccccc555555555ccccccccccccccccccccccccccccccccccc0;
        icons[360]=384'h0ccccccccccccccccccccccccccc888888888888888ccccccccc555555555cccccccccccccccccccccccccccccccccc0;
        icons[361]=384'h0cccccccccccccccccccccccccc8888888888888888ccccccccc5555555555ccccccccccccccccccccccccccccccccc0;
        icons[362]=384'h0ccccccccccccccccccccccccc8888888888888888cccccccccc5555555555ccccccccccccccccccccccccccccccccc0;
        icons[363]=384'h0ccccccccccccccccccccccccc888888888888888cccccccccccc5555555555cccccccccccccccccccccccccccccccc0;
        icons[364]=384'h0cccccccccccccccccccccccc8888888888888888cccccccccccc555555555ccccccccccccccccccccccccccccccccc0;
        icons[365]=384'h0ccccccccccccccccccccccccc88888888888888cccccccccccccc5555555cccccccccccccccccccccccccccccccccc0;
        icons[366]=384'h0ccccccccccccccccccccccccccc88888888888ccccccccccccccc55555cccccccccccccccccccccccccccccccccccc0;
        icons[367]=384'h0cccccccccccccccccccccccccccc8888888888ccccccccccccccc5555ccccccccccccccccccccccccccccccccccccc0;
        icons[368]=384'h0cccccccccccccccccccccccccccccc8888888ccccccccccccccccc55cccccccccccccccccccccccccccccccccccccc0;
        icons[369]=384'h00cccccccccccccccccccccccccccccc88888cccccccccccccccccc5cccccccccccccccccccccccccccccccccccccc00;
        icons[370]=384'h00cccccccccccccccccccccccccccccccc888ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[371]=384'h00ccccccccccccccccccccccccccccccccc8cccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[372]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[373]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[374]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[375]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[376]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[377]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[378]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[379]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[380]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[381]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[382]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[383]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[384]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[385]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[386]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[387]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[388]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[389]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[390]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[391]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[392]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[393]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[394]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[395]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[396]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[397]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[398]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[399]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[400]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[401]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[402]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[403]=384'h0ccccccccccccccccccccccccccccccccccccccccccfffffffffffccccccccccccccccccccccccccccccccccccccccc0;
        icons[404]=384'h0cccccccccccccccccccccccdcccccccccccccccfffffffffffffffffcccccccccccccdcccccccccccccccccccccccc0;
        icons[405]=384'h0ccccccccccccccccccddddddddccccccccccfffffffffffffffffffffffccccccccdddddddddcccccccccccccccccc0;
        icons[406]=384'h0ccccccccccccddddddddddddddddccccccfffffffffffffffffffffffffffcccccddddddddddddddddcccccccccccc0;
        icons[407]=384'h0ccccccccccccdddddddddddddddddcccfffffffffffffffffffffffffffffffcddddddddddddddddddcccccccccccc0;
        icons[408]=384'h0ccccccccccccdddddddddddddddddddffffffffffffffffffffffffffffffffddddddddddddddddddddccccccccccc0;
        icons[409]=384'h0cccccccccccddddddddddddddddddddddffffffffffffffffffffffffffffddddddddddddddddddddddccccccccccc0;
        icons[410]=384'h0cccccccccccddddddddddddddddddddddffffffffffffffffffffffffffffddddddddddddddddddddddccccccccccc0;
        icons[411]=384'h0cccccccccccddddddddddddddddddddddffffffffffffffffffffffffffffddddddddddddddddddddddccccccccccc0;
        icons[412]=384'h0cccccccccccdddddddddddddddddddddffffffffffffffffffffffffffffffddddddddddddddddddddddcccccccccc0;
        icons[413]=384'h0ccccccccccddddddddddddddddddddddffffffffffffffffffffffffffffffddddddddddddddddddddddcccccccccc0;
        icons[414]=384'h0ccccccccccddddddddddddddddddddddffffffffffffffffffffffffffffffddddddddddddddddddddddcccccccccc0;
        icons[415]=384'h0ccccccccccddddddddddddddddddddddffffffffffffffffffffffffffffffdddddddddddddddddddddddccccccccc0;
        icons[416]=384'h0ccccccccccdddddddddddddddddddddffffffffffffffffffffffffffffffffddddddddddddddddddddddccccccccc0;
        icons[417]=384'h0cccccccccddddddddddddddddddddddffffffffffffffffffffffffffffffffddddddddddddddddddddddccccccccc0;
        icons[418]=384'h0cccccccccddddddddddddddddddddddffffffffffffffffffffffffffffffffddddddddddddddddddddddccccccccc0;
        icons[419]=384'h0cccccccccddddddddddddddddddddddffffffffffffffffffffffffffffffffdddddddddddddddddddddddcccccccc0;
        icons[420]=384'h0cccccccccdddddddddddddddddddddffffffffffffffffffffffffffffffffffddddddddddddddddddddddcccccccc0;
        icons[421]=384'h0ccccccccddddddddddddddddddddddf9999fffffffffffffffffffffffff9999ddddddddddddddddddddddcccccccc0;
        icons[422]=384'h0ccccccccdddddddddddddddddddddd999999fffffffffffffffffffffff999999ddddddddddddddddddddddccccccc0;
        icons[423]=384'h0ccccccccdddddddddddddddddddddd999999fffffffffffffffffffffff999999ddddddddddddddddddddddccccccc0;
        icons[424]=384'h0ccccccccddddddddddddddddddddd99999999fffffffffffffffffffff99999999dddddddddddddddddddddccccccc0;
        icons[425]=384'h0cccccccdddddddddddddddddddddd99999999fffffffffffffffffffff99999999ddddddddddddddddddddddcccccc0;
        icons[426]=384'h0cccccccdddddddddddddddddddddd99999999fffffffffffffffffffff99999999ddddddddddddddddddddddcccccc0;
        icons[427]=384'h0cccccccddddddddddddddddddddddf999999fffffffffffffffffffffff999999dddddddddddddddddddddddcccccc0;
        icons[428]=384'h0cccccccddddddddddddddddddddddf999999fffffffffffffffffffffff999999dddddddddddddddddddddddcccccc0;
        icons[429]=384'h0ccccccddddddddddddddddddddddfff9999fffffffffffffffffffffffff9999ffdddddddddddddddddddddddccccc0;
        icons[430]=384'h0ccccccddddddddddddddddddddddffffffffffffffffffffffffffffffffffffffdddddddddddddddddddddddccccc0;
        icons[431]=384'h0cccccccdddddddddddddddddddddffffffffffffffffffffffffffffffffffffffddddddddddddddddddddddcccccc0;
        icons[432]=384'h0cccccccddddddddddddddddddddffffffffffffffffffffffffffffffffffffffffdddddddddddddddddddddcccccc0;
        icons[433]=384'h0ccccccccddddddddddddddddddfffffffffffffff9999999999999fffffffffffffddddddddddddddddddddccccccc0;
        icons[434]=384'h0ccccccccddddddddddddddddddfffffffffffff19999999999999991ffffffffffffdddddddddddddddddddccccccc0;
        icons[435]=384'h0cccccccccddddddddddddddddfffffffffff11199999999999999999111ffffffffffdddddddddddddddddcccccccc0;
        icons[436]=384'h0cccccccccdddddddddddddddffffffffff111199999999999999999991111fffffffffddddddddddddddddcccccccc0;
        icons[437]=384'h0ccccccccccdddddddddddddffffffffff11111999999999999999999911111ffffffffdddddddddddddddccccccccc0;
        icons[438]=384'h0ccccccccccdddddddddddddfffffffff1111119999999999999999999111111ffffffffddddddddddddddccccccccc0;
        icons[439]=384'h0cccccccccccdddddddddddfffffffff111111199999999999999999991111111ffffffffddddddddddddcccccccccc0;
        icons[440]=384'h0cccccccccccddddddddddfffffffff11111111999999999999999999911111111fffffffdddddddddddccccccccccc0;
        icons[441]=384'h0ccccccccccccddddddddfffffffff1111111111999999999999999991111111111fffffffddddddddddccccccccccc0;
        icons[442]=384'h0ccccccccccccddddddddffffffff111111111111999999999999999111111111111fffffffddddddddcccccccccccc0;
        icons[443]=384'h0cccccccccccccddddddfffffffff111111111111199999999999991111111111111fffffffddddddddcccccccccccc0;
        icons[444]=384'h0cccccccccccccdddddccfffffff11111111111111111119991111111111111111111fffffffddddddccccccccccccc0;
        icons[445]=384'h0ccccccccccccccdddcccfffffff11111111111111111119991111111111111111111fffffffcdddddccccccccccccc0;
        icons[446]=384'h0ccccccccccccccdddcccfffffff11111111111111111119991111111111111111111fffffffccdddcccccccccccccc0;
        icons[447]=384'h0cccccccccccccccdcccccffffff11111111111111111119991111111111111111111ffffffcccdddcccccccccccccc0;
        icons[448]=384'h0cccccccccccccccccccccffffff11111111111111111119991111111111111111111ffffffccccdccccccccccccccc0;
        icons[449]=384'h0ccccccccccccccccccccccfffff11111111111111111119991111111111111111111fffffccccccccccccccccccccc0;
        icons[450]=384'h0ccccccccccccccccccccccfffff11111111111111111199999111111111111111111fffffccccccccccccccccccccc0;
        icons[451]=384'h0cccccccccccccccccccccccfffff1111111111111111999bbbb9111111111111111fffffcccccccccccccccccccccc0;
        icons[452]=384'h0cccccccccccccccccccccccfffff111111111111119999bbbbbb991111111111111fffffcccccccccccccccccccccc0;
        icons[453]=384'h0ccccccccccccccccccccccccfffff1111111111199991bbbbbbbb9991111111111fffffccccccccccccccccccccccc0;
        icons[454]=384'h0cccccccccccccccccccccccccfffff11111111119991bbbbbbbbbb99111111111fffffcccccccccccccccccccccccc0;
        icons[455]=384'h0ccccccccccccccccccccccccccfffff1111111119111bbbbbbbbbb1911111111fffffccccccccccccccccccccccccc0;
        icons[456]=384'h0cccccccccccccccccccccccccccfffff111111111111bbbbbbbbbb111111111fffffcccccccccccccccccccccccccc0;
        icons[457]=384'h0ccccccccccccccccccccccccccccfffff11111111111bbbbbbbbbb11111111fffffccccccccccccccccccccccccccc0;
        icons[458]=384'h0cccccccccccccccccccccccccccccfffff1111111111bbbbbbbbbb1111111fffffcccccccccccccccccccccccccccc0;
        icons[459]=384'h0ccccccccccccccccccccccccccccccffffff11111111bbbbbbbbbb11111ffffffccccccccccccccccccccccccccccc0;
        icons[460]=384'h0cccccccccccccccccccccccccccccccffffffff11111bbbbbbbbbb11ffffffffcccccccccccccccccccccccccccccc0;
        icons[461]=384'h0ccccccccccccccccccccccccccccccccffffffffff111bbbbbbbbffffffffffccccccccccccccccccccccccccccccc0;
        icons[462]=384'h0ccccccccccccccccccccccccccccccccccffffffffffffbbbbbbfffffffffccccccccccccccccccccccccccccccccc0;
        icons[463]=384'h0ccccccccccccccccccccccccccccccccccccfffffffffffbbbbffffffffccccccccccccccccccccccccccccccccccc0;
        icons[464]=384'h0cccccccccccccccccccccccccccccccccccccccfffffffffffffffffcccccccccccccccccccccccccccccccccccccc0;
        icons[465]=384'h00cccccccccccccccccccccccccccccccccccccccccfffffffffffcccccccccccccccccccccccccccccccccccccccc00;
        icons[466]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[467]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[468]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[469]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[470]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[471]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[472]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[473]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[474]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[475]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[476]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[477]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[478]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[479]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[480]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[481]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[482]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[483]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[484]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[485]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[486]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[487]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[488]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[489]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[490]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[491]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[492]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[493]=384'h00cccccccccccccccccccccccccccccccccc9999999999cccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[494]=384'h00ccccccccccccccccccccccccccccccc9999999999999999ccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[495]=384'h0ccccccccccccccccccccccccccccc9999999999999999999999ccccccccccccccccccccccccccccccccccccccccccc0;
        icons[496]=384'h0ccccccccccccccccccccccccccc99999999999999999999999999ccccccccccccccccccccccccccccccccccccccccc0;
        icons[497]=384'h0cccccccccccccccccccccccccc9999999999999999999999999999cccccccccccccccccccccccccccccccccccccccc0;
        icons[498]=384'h0ccccccccccccccccccccccccc999999999999999999999999999999ccccccccccccccccccccccccccccccccccccccc0;
        icons[499]=384'h0cccccccccccccccccccccccc99999999999999999999999999999999cccccccccccccccccccccccccccccccccccccc0;
        icons[500]=384'h0ccccccccccccccccccccccc9999999999999999999999999999999999ccccccccccccccccccccccccccccccccccccc0;
        icons[501]=384'h0cccccccccccccccccccccc999999999999999999999999999999999999cccccccccccccccccccccccccccccccccccc0;
        icons[502]=384'h0cccccccccccccccccccccc999999999999999999999999999999999999cccccccccccccccccccccccccccccccccccc0;
        icons[503]=384'h0ccccccccccccccccccccc99999999999999999999999999999999999999ccccccccccccccccccccccccccccccccccc0;
        icons[504]=384'h0ccccccccccccccccccccc99999999999999999999999999999999999999ccccccccccccccccccccc33cccccccccccc0;
        icons[505]=384'h0cccccccccccccccccccc9999999999999999999999999999999999999999cccccccccccccccccccc333ccccccccccc0;
        icons[506]=384'h0cccccccccccccccccccc9999999999999999999999999999999999999999ccccccccccccccccccc33333cccccccccc0;
        icons[507]=384'h0cccccccccccccccccccc9999999999999999999999999999999999999999cccccccccccccccccccc33333ccccccccc0;
        icons[508]=384'h0cccccccccccccccccccc9999999999999999999999999999999999999999ccccccccccccccccccccc33333cccccccc0;
        icons[509]=384'h0ccccccccccccccccccccccc7777777777777777777777777777777777ccccccccccccccccccccccccc3333cccccccc0;
        icons[510]=384'h0cccccccccccccccccccccc777777777777777777777777777777777777cccccccccccccccccccccccc33333ccccccc0;
        icons[511]=384'h0cccccccccccccccccccccc777777777777777777777777777777777777ccccccccccccccccccccccccc3333ccccccc0;
        icons[512]=384'h0cccccccccccccccccccccc777777777777777777777777777777777777ccccccccccccccccccccccccc33333cccccc0;
        icons[513]=384'h0cccccccccccccccccccccc777777777777777777777777777777777777ccccccccccccc3cccccccccccc3333cccccc0;
        icons[514]=384'h0ccccccccccccccccccccc77777777777777777777777777777777777777ccccccccccc333ccccccccccc3333cccccc0;
        icons[515]=384'h0ccccccccccccccccccccc77777777777777777777777777777777777777cccccccccc33333ccccccccccc3333ccccc0;
        icons[516]=384'h0ccccccccccccccccccccc77777777777777777777777799977777777777ccccccccccc33333cccccccccc3333ccccc0;
        icons[517]=384'h0ccccccccccccccccccccc77777777777777777777777999997777777777cccccccccccc3333cccccccccc3333ccccc0;
        icons[518]=384'h0ccccccccccccccccccccc77777777777777777777777999997777777777ccccccccccccc3333cccccccccc3333cccc0;
        icons[519]=384'h0ccccccccccccccccccccc77777777777777777777777999997777777777ccccccccccccc3333cccccccccc3333cccc0;
        icons[520]=384'h0ccccccccccccccccccccc77777777777777777777777799977777777777ccccccccccccc3333cccccccccc3333cccc0;
        icons[521]=384'h0ccccccccccccccccccccc77777777777777777777777777777777777777cccccccccccccc3333ccccccccc3333cccc0;
        icons[522]=384'h0ccccccccccccccccccccc777777777777777777777777777777777777777ccccccccccccc3333ccccccccc3333cccc0;
        icons[523]=384'h0ccccccccccccccccccccc77777777777777777777777777777777777777777ccccccccccc3333ccccccccc3333cccc0;
        icons[524]=384'h0cccccccccccccccccccccc77777777777777777777777777777777777777777cccccccccc3333cccccccccc3333ccc0;
        icons[525]=384'h0cccccccccccccccccccccc7777777777777777777777777777777777777777777ccccccccc3333ccccccccc3333ccc0;
        icons[526]=384'h0cccccccccccccccccccccc777777777777777777777777777777777777777ccccccccccccc3333ccccccccc3333ccc0;
        icons[527]=384'h0cccccccccccccccccccccc777777777777777777777777777777777777cccccccccccccccc3333ccccccccc3333ccc0;
        icons[528]=384'h0ccccccccccccccccccccccc7777777777777777777777777777779997ccccccccccccccccc3333ccccccccc3333ccc0;
        icons[529]=384'h0ccccccccccccccccccccccc77777777777777777777777777779999999cccccccccccccccc3333ccccccccc3333ccc0;
        icons[530]=384'h0cccccccccccccccccccccccc77777777777777777777777777999999999ccccccccccccccc3333ccccccccc3333ccc0;
        icons[531]=384'h0cccccccccccccccccccccccc77777777777777777777777777999999999ccccccccccccccc3333ccccccccc3333ccc0;
        icons[532]=384'h0ccccccccccccccccccccccccc7777777777777777777777777999999999ccccccccccccccc3333ccccccccc3333ccc0;
        icons[533]=384'h0ccccccccccccccccccccccccc7777777777777777777777777999999999ccccccccccccccc3333ccccccccc3333ccc0;
        icons[534]=384'h0cccccccccccccccccccccccccc77777777777777777777777779999999cccccccccccccccc3333ccccccccc3333ccc0;
        icons[535]=384'h0ccccccccccccccccccccccccccc77777777777777777777777777999cccccccccccccccccc3333ccccccccc3333ccc0;
        icons[536]=384'h0cccccccccccccccccccccccccccc777777777777777777777777cccccccccccccccccccccc3333ccccccccc3333ccc0;
        icons[537]=384'h0ccccccccccccccccccccccccccccc7777777777777777777777cccccccccccccccccccccc3333cccccccccc3333ccc0;
        icons[538]=384'h0cccccccccccccccccccccccccccccc77777777777777777777ccccccccccccccccccccccc3333cccccccccc3333ccc0;
        icons[539]=384'h0cccccccccccccccccccccccccccccccc7777777777777777ccccccccccccccccccccccccc3333ccccccccc3333cccc0;
        icons[540]=384'h0ccccccccccccccccccccccccccccccccc77777777777777cccccccccccccccccccccccccc3333ccccccccc3333cccc0;
        icons[541]=384'h0cccccccccccccccccccccccccccccccccccc77777777cccccccccccccccccccccccccccc3333cccccccccc3333cccc0;
        icons[542]=384'h0ccccccccccccccccccccc55555555555555555555555555555555555cccccccccccccccc3333cccccccccc3333cccc0;
        icons[543]=384'h0ccccccccccccccccccc555555555555555555555555555555555555555cccccccccccccc3333cccccccccc3333cccc0;
        icons[544]=384'h0ccccccccccccccccc5555555555555555555555555555555555555555555ccccccccccc3333ccccccccccc3333cccc0;
        icons[545]=384'h0cccccccccccccccc555555555555555555555555555555555555555555555ccccccccc33333cccccccccc3333ccccc0;
        icons[546]=384'h0ccccccccccccccc55555555555555555555555555555555555555555555555ccccccc33333ccccccccccc3333ccccc0;
        icons[547]=384'h0cccccccccccccc5555555555555555555555555555555555555555555555555ccccccc333cccccccccccc3333ccccc0;
        icons[548]=384'h0cccccccccccccc5555555555555555555555555555555555555555555555555cccccccc3cccccccccccc3333cccccc0;
        icons[549]=384'h0ccccccccccccc555555555555555555555555555555555555555555555555555cccccccccccccccccccc3333cccccc0;
        icons[550]=384'h0ccccccccccccc555555555555555555555555555555555555555555555555555ccccccccccccccccccc33333cccccc0;
        icons[551]=384'h0cccccccccccc55555555555555555555555555555555555555555555555555555cccccccccccccccccc3333ccccccc0;
        icons[552]=384'h0cccccccccccc55555555555555555555555555555555555555555555555555555ccccccccccccccccc33333ccccccc0;
        icons[553]=384'h0cccccccccccc55555555555555555555555555555555555555555555555555555ccccccccccccccccc3333cccccccc0;
        icons[554]=384'h0cccccccccccc55555555555555555555555555555555555555555555555555555cccccccccccccccc33333cccccccc0;
        icons[555]=384'h0cccccccccccc55555555555555555555555555555555555555555555555555555ccccccccccccccc33333ccccccccc0;
        icons[556]=384'h0cccccccccccc55555555555555555555555555555555555555555555555555555cccccccccccccc33333cccccccccc0;
        icons[557]=384'h0cccccccccccc55555555555555555555555555555555555555555555555555555ccccccccccccccc333ccccccccccc0;
        icons[558]=384'h0ccccccccccccc555555555555555555555555555555555555555555555555555cccccccccccccccc33cccccccccccc0;
        icons[559]=384'h0ccccccccccccc555555555555555555555555555555555555555555555555555cccccccccccccccccccccccccccccc0;
        icons[560]=384'h0cccccccccccccc5555555555555555555555555555555555555555555555555ccccccccccccccccccccccccccccccc0;
        icons[561]=384'h00ccccccccccccc5555555555555555555555555555555555555555555555555cccccccccccccccccccccccccccccc00;
        icons[562]=384'h00cccccccccccccc55555555555555555555555555555555555555555555555ccccccccccccccccccccccccccccccc00;
        icons[563]=384'h00ccccccccccccccc555555555555555555555555555555555555555555555cccccccccccccccccccccccccccccccc00;
        icons[564]=384'h000ccccccccccccccc5555555555555555555555555555555555555555555cccccccccccccccccccccccccccccccc000;
        icons[565]=384'h000ccccccccccccccccc555555555555555555555555555555555555555cccccccccccccccccccccccccccccccccc000;
        icons[566]=384'h0000cccccccccccccccccc55555555555555555555555555555555555ccccccccccccccccccccccccccccccccccc0000;
        icons[567]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[568]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[569]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[570]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[571]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[572]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[573]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[574]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[575]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[576]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[577]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[578]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[579]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[580]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[581]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[582]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[583]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[584]=384'h00000cccccccccccccccccccccccccccccccccccccc3ccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[585]=384'h0000ccccccccccccccccccccccccccccccccccccc333cccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[586]=384'h000ccccccccccccccccccccccccccccccccccc3333333cccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[587]=384'h000ccccccccccccccccccccccccccccccccc333333333cccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[588]=384'h00cccccccccccccccccccccccccccccccc333333333333cccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[589]=384'h00ccccccccccccccccccccccccccccc333333333333333cccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[590]=384'h00ccccccccccccccccccccccccccc33333333333333333cccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[591]=384'h0cccccccccccccccccccccccccc33333333333333333333cccccccccccccccccccccccc3ccccccccccccccccccccccc0;
        icons[592]=384'h0ccccccccccccccccccccccc33333333333333333333333ccccccccccccccccccccccc33ccccccccccccccccccccccc0;
        icons[593]=384'h0ccccccccccccccccccccc33333333333333333333333333ccccccccccccccccccccc333ccccccccccccccccccccccc0;
        icons[594]=384'h0ccccccccccccccccccccc33333333333333333333333333ccccccccccccccccccc3333cccccccccccccccccccccccc0;
        icons[595]=384'h0cccccccccccccccccccccc3333333333333333333333333cccccccccccccccccc33333cccccccccccccccccccccccc0;
        icons[596]=384'h0cccccccccccccccccccccc33333333333333333333333333cccccccccccccccc333333cccccccccccccccccccccccc0;
        icons[597]=384'h0ccccccccccccccccccccccc3333333333333333333333333ccccccccccccccc3333333cccccccccccccccccccccccc0;
        icons[598]=384'h0ccccccccccccccccccccccc3333333333333333333333333cccccccccccccc3333333ccccccccccccccccccccccccc0;
        icons[599]=384'h0ccccccccccccccccccccccc33333333333333333333333333cccccccccccc33333333ccccccccccccccccccccccccc0;
        icons[600]=384'h0cccccccccccccccccccccccc3333333333333333333333111cccccccccc3333333333ccccccccccccccccccccccccc0;
        icons[601]=384'h0cccccccccccccccccccccccc33333333333333333333331113cccccccc33333333333ccccccccccccccccccccccccc0;
        icons[602]=384'h0ccccccccccccccccccccccccc3333333333333333333311133ccccccc33333333333cccccccccccccccccccccccccc0;
        icons[603]=384'h0ccccccccccccccccccccccccc3333333333333333333311133cccccc333333333333cccccccccccccccccccccccccc0;
        icons[604]=384'h0ccccccccccccccccccccccccc33333333333333333333111333cccc3333333333333cccccccccccccccccccccccccc0;
        icons[605]=384'h0cccccccccccccccccccccccccc3333333333333333343111333cc333333333333333cccccccccccccccccccccccccc0;
        icons[606]=384'h0cccccccccccccccccccccccccc333333333333333334111333333333333333333333cccccccccccccccccccccccccc0;
        icons[607]=384'h0cccccccccccccccccccccccccc33333333333333334411133333333333333333333ccccccccccccccccccccccccccc0;
        icons[608]=384'h0ccccccccccccccccccccccccccc3333333333333334411133333333333333333333ccccccccccccccccccccccccccc0;
        icons[609]=384'h0ccccccccccccccccccccccccccc3333333333333334411133333333333333333333ccccccccccccccccccccccccccc0;
        icons[610]=384'h0cccccccccccccccccccccccccccc333333333333334111443333333333333333333ccccccccccccccccccccccccccc0;
        icons[611]=384'h0cccccccccccccccccccccccccccc33333333333334411144333333333333333333cccccccccccccccccccccccccccc0;
        icons[612]=384'h0cccccccccccccccccccccccccccc33333333333334411144433333333333333333cccccccccccccccccccccccccccc0;
        icons[613]=384'h0ccccccccccccccccccccccccccccc3333333333334111444443333333333333333cccccccccccccccccccccccccccc0;
        icons[614]=384'h0ccccccccccccccccccccccccccccc333333333334411144444333333333333333333333333333ccccccccccccccccc0;
        icons[615]=384'h0cccccccccccccccccccccccccccccc33333333334411144444433333333333333333333333333333333333333ccccc0;
        icons[616]=384'h0cccccccccccccccccccccccccccccc333333333344111444444433333333333333333333333333333333333ccccccc0;
        icons[617]=384'h0cccccccccccccccccccccccccc333333333333334111444444444333333333333333333333333333333333cccccccc0;
        icons[618]=384'h0cccccccccccccccccccccc33333333333333333441114444444443333333333333333333333333333333cccccccccc0;
        icons[619]=384'h0cccccccccccccccccc33333333333333333333344111444444444433333333333333333333333333333ccccccccccc0;
        icons[620]=384'h0cccccccccccccc3333333333333333334444444441114444444444444444444444444333333333333ccccccccccccc0;
        icons[621]=384'h0cccccccccc3333333333333344444444444444441114444444444444444444444444333333333333cccccccccccccc0;
        icons[622]=384'h0cccccc333333333333333333344444444444444411114444444444444444444444433333333333cccccccccccccccc0;
        icons[623]=384'h0cccccccc333333333333333333344444444444441111114444444444444444444433333333333ccccccccccccccccc0;
        icons[624]=384'h0ccccccccc333333333333333333344444444444441111114444444444444444443333333333ccccccccccccccccccc0;
        icons[625]=384'h0ccccccccccc333333333333333333444444444444441111114444444444444433333333333cccccccccccccccccccc0;
        icons[626]=384'h0cccccccccccc333333333333333333344444444444441111114444444444443333333333cccccccccccccccccccccc0;
        icons[627]=384'h0cccccccccccccc333333333333333333444444444444441111114444444443333333333ccccccccccccccccccccccc0;
        icons[628]=384'h0ccccccccccccccc333333333333333333444444444444441111114444444333333333ccccccccccccccccccccccccc0;
        icons[629]=384'h0ccccccccccccccccc33333333333333333344444444444444111144444433333333333cccccccccccccccccccccccc0;
        icons[630]=384'h0cccccccccccccccccc33333333333333333344444444444444111444443333333333333ccccccccccccccccccccccc0;
        icons[631]=384'h0cccccccccccccccccccc333333333333333344444444444441114444443333333333333ccccccccccccccccccccccc0;
        icons[632]=384'h0ccccccccccccccccccccc333333333333333444444444444411144444443333333333333cccccccccccccccccccccc0;
        icons[633]=384'h0ccccccccccccccccccccccc33333333333344444444444441114444444433333333333333ccccccccccccccccccccc0;
        icons[634]=384'h0cccccccccccccccccccccccc33333333333444444444444411144444444333333333333333cccccccccccccccccccc0;
        icons[635]=384'h0cccccccccccccccccccccccc33333333333444444444444411144444444333333333333333cccccccccccccccccccc0;
        icons[636]=384'h0ccccccccccccccccccccccc3333333333334444444444441114444444444333333333333333ccccccccccccccccccc0;
        icons[637]=384'h0ccccccccccccccccccccccc33333333333344444444444311144444444443333333333333333cccccccccccccccccc0;
        icons[638]=384'h0cccccccccccccccccccccc3333333333333444444444331114444444444433333333333333333ccccccccccccccccc0;
        icons[639]=384'h0cccccccccccccccccccccc3333333333334444444443331113344444444433333333333333333ccccccccccccccccc0;
        icons[640]=384'h0cccccccccccccccccccccc33333333333344444444333311333334444444433333333333333333cccccccccccccccc0;
        icons[641]=384'h0ccccccccccccccccccccc3333333333333444444333331113333334444444333333333333333333ccccccccccccccc0;
        icons[642]=384'h0ccccccccccccccccccccc33333333333334444433333311133333333444443333333333333333333cccccccccccccc0;
        icons[643]=384'h0cccccccccccccccccccc33333333333333444433333311133333333333444cc33333333333333333cccccccccccccc0;
        icons[644]=384'h0cccccccccccccccccccc333333333333344443333333111333333333333444cccc333333333333333ccccccccccccc0;
        icons[645]=384'h0cccccccccccccccccccc333333333333344333333331113333333333333cc4cccccccc333333333333cccccccccccc0;
        icons[646]=384'h0ccccccccccccccccccc3333333333333343333cc333111333333333333ccccccccccccccc3333333333ccccccccccc0;
        icons[647]=384'h0ccccccccccccccccccc33333333333333333cccc333111333333333333ccccccccccccccccccc333333ccccccccccc0;
        icons[648]=384'h0cccccccccccccccccc33333333333333333cccccc31113333333333333cccccccccccccccccccccc3333cccccccccc0;
        icons[649]=384'h0cccccccccccccccccc333333333333333cccccccc3111333333333333ccccccccccccccccccccccccccc3ccccccccc0;
        icons[650]=384'h0cccccccccccccccccc3333333333333cccccccccc1113333333333333ccccccccccccccccccccccccccccccccccccc0;
        icons[651]=384'h0ccccccccccccccccc333333333333cccccccccccc1113333333333333ccccccccccccccccccccccccccccccccccccc0;
        icons[652]=384'h0ccccccccccccccccc3333333333cccccccccccccccc3333333333333cccccccccccccccccccccccccccccccccccccc0;
        icons[653]=384'h0cccccccccccccccc3333333333ccccccccccccccccc3333333333333cccccccccccccccccccccccccccccccccccccc0;
        icons[654]=384'h0cccccccccccccccc33333333cccccccccccccccccccc33333333333ccccccccccccccccccccccccccccccccccccccc0;
        icons[655]=384'h0cccccccccccccccc333333cccccccccccccccccccccc33333333333ccccccccccccccccccccccccccccccccccccccc0;
        icons[656]=384'h0ccccccccccccccc33333ccccccccccccccccccccccccc3333333333ccccccccccccccccccccccccccccccccccccccc0;
        icons[657]=384'h00cccccccccccccc3333cccccccccccccccccccccccccc333333333ccccccccccccccccccccccccccccccccccccccc00;
        icons[658]=384'h00ccccccccccccc333ccccccccccccccccccccccccccccc33333333ccccccccccccccccccccccccccccccccccccccc00;
        icons[659]=384'h00ccccccccccccc3ccccccccccccccccccccccccccccccc33333333ccccccccccccccccccccccccccccccccccccccc00;
        icons[660]=384'h000ccccccccccccccccccccccccccccccccccccccccccccc333333ccccccccccccccccccccccccccccccccccccccc000;
        icons[661]=384'h000ccccccccccccccccccccccccccccccccccccccccccccc333333ccccccccccccccccccccccccccccccccccccccc000;
        icons[662]=384'h0000ccccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccccccccccccccccc0000;
        icons[663]=384'h00000cccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccccccccccc00000;
        icons[664]=384'h000000cccccccccccccccccccccccccccccccccccccccccccc333ccccccccccccccccccccccccccccccccccccc000000;
        icons[665]=384'h0000000ccccccccccccccccccccccccccccccccccccccccccc33ccccccccccccccccccccccccccccccccccccc0000000;
        icons[666]=384'h00000000ccccccccccccccccccccccccccccccccccccccccccc3cccccccccccccccccccccccccccccccccccc00000000;
        icons[667]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[668]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[669]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[670]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[671]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[672]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[673]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[674]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[675]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[676]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[677]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[678]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[679]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[680]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[681]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[682]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[683]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[684]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[685]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[686]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[687]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[688]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[689]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[690]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[691]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[692]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[693]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[694]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[695]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[696]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[697]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[698]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[699]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[700]=384'h0cccccccccccccccccccccccc55555555555555555555555555555555555555555ccccccccccccccccccccccccccccc0;
        icons[701]=384'h0cccccccccccccccccccccccc555555555555555555555555555555555555555555cccccccccccccccccccccccccccc0;
        icons[702]=384'h0ccccccccccccccccccccccc5555555555555555555555555555555555555555555cccccccccccccccccccccccccccc0;
        icons[703]=384'h0ccccccccccccccccccccccc55555555555555555555555555555555555555555555ccccccccccccccccccccccccccc0;
        icons[704]=384'h0cccccccccccccccccccccc5555555eeeeeeeeeeee5555eeeeeeeeeeeeeeee555555ccccccccccccccccccccccccccc0;
        icons[705]=384'h0cccccccccccccccccccccc5555555eeeeeeeeeeee5555eeeeeeeeeeeeeeeee555555cccccccccccccccccccccccccc0;
        icons[706]=384'h0ccccccccccccccccccccc5555555eeeeeeeeeeeee5555eeeeeeeeeeeeeeeee5555555ccccccccccccccccccccccccc0;
        icons[707]=384'h0ccccccccccccccccccccc5555555eeeeeeeeeeeee5555eeeeeeeeeeeeeeeeee555555ccccccccccccccccccccccccc0;
        icons[708]=384'h0cccccccccccccccccccc5555555eeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeee5555555cccccccccccccccccccccccc0;
        icons[709]=384'h0cccccccccccccccccccc5555555eeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeee555555cccccccccccccccccccccccc0;
        icons[710]=384'h0ccccccccccccccccccc5555555eeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeee5555555ccccccccccccccccccccccc0;
        icons[711]=384'h0ccccccccccccccccccc5555555eeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeeee5555555cccccccccccccccccccccc0;
        icons[712]=384'h0cccccccccccccccccc5555555eeeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeeeee555555cccccccccccccccccccccc0;
        icons[713]=384'h0cccccccccccccccccc5555555eeeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeeeee5555555ccccccccccccccccccccc0;
        icons[714]=384'h0ccccccccccccccccc5555555eeeeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeeeeee555555ccccccccccccccccccccc0;
        icons[715]=384'h0ccccccccccccccccc5555555eeeeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeeeeee5555555cccccccccccccccccccc0;
        icons[716]=384'h0cccccccccccccccc5555555eeeeeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeeeeeee5555555ccccccccccccccccccc0;
        icons[717]=384'h0cccccccccccccccc5555555eeeeeeeeeeeeeeeeee5555eeeeeeeeeeeeeeeeeeeeeee5555555ccccccccccccccccccc0;
        icons[718]=384'h0cccccccccccccc55555555555555555555555555555555555555555555555555555555555555cccccccccccccccccc0;
        icons[719]=384'h0cccccccccccc555555555555555555555555555555555555555555555555555555555555555555cccccccccccccccc0;
        icons[720]=384'h0ccccccccccc55555555555555555555555555555555555555555555555555555555555555555555ccccccccccccccc0;
        icons[721]=384'h0cccccccccc5555555555555555555555555555555555555555555555555555555555555555555555cccccccccccccc0;
        icons[722]=384'h0cccccccccc5555555555555555555555555555555555555555555555555555555555555555555555cccccccccccccc0;
        icons[723]=384'h0ccccccccc555555555555555555555555555555555555555555555555555555555555555555555555ccccccccccccc0;
        icons[724]=384'h0ccccccccc555555555555555555555555555555555555555555555555555555555555555555555555ccccccccccccc0;
        icons[725]=384'h0ccccccccc555555333333333333355555555555555555555555555555555555533333333333355555ccccccccccccc0;
        icons[726]=384'h0ccccccccc555555333333333333355555555555555555555555555555555555533333333333355555ccccccccccccc0;
        icons[727]=384'h0ccccccccc555555333333333333355555555555555555555555555555555555533333333333355555ccccccccccccc0;
        icons[728]=384'h0ccccccccc555555333333333333355555555555555555555555555555555555533333333333355555ccccccccccccc0;
        icons[729]=384'h0ccccccccc555555333333333333355555555555555555555555555555555555533333333333355555ccccccccccccc0;
        icons[730]=384'h0ccccccccc555555333333333333355555555555555555555555555555555555533333333333355555ccccccccccccc0;
        icons[731]=384'h0ccccccccc555555555555555555555555555555555555555555555555555555555555555555555555ccccccccccccc0;
        icons[732]=384'h0ccccccccc555555555555555555555555555555555555555555555555555555555555555555555555ccccccccccccc0;
        icons[733]=384'h0ccccccccc555555555555555555555555555555555555555555555555555555555555555555555555ccccccccccccc0;
        icons[734]=384'h0ccccccccc555555555555555555555555555555555555555555555555555555555555555555555555ccccccccccccc0;
        icons[735]=384'h0ccccccccc555555555555555555555555555555555555555555555555555555555555555555555555ccccccccccccc0;
        icons[736]=384'h0ccccccccc555555555555555999995555555555555555555555555555555555999995555555555555ccccccccccccc0;
        icons[737]=384'h0ccccccccc555555555555599999999955551111111111111111111115555599999999955555555555ccccccccccccc0;
        icons[738]=384'h0ccccccccc555555555555999999999995551111111111111111111115555999999999995555555555ccccccccccccc0;
        icons[739]=384'h0cccccccccc5555555555999999999999955111111111111111111111555999999999999955555555cccccccccccccc0;
        icons[740]=384'h0cccccccccc5555555555999999999999955555555555555555555555555999999999999955555555cccccccccccccc0;
        icons[741]=384'h0ccccccccccc55555555999999999999999555555555555555555555555999999999999999555555ccccccccccccccc0;
        icons[742]=384'h0cccccccccccc555555599999999999999955555555555555555555555599999999999999955555cccccccccccccccc0;
        icons[743]=384'h0cccccccccccccc55555999999999999999555555555555555555555555999999999999999555cccccccccccccccccc0;
        icons[744]=384'h0ccccccccccccccccccc999999999999999cccccccccccccccccccccccc999999999999999ccccccccccccccccccccc0;
        icons[745]=384'h0ccccccccccccccccccc999999999999999cccccccccccccccccccccccc999999999999999ccccccccccccccccccccc0;
        icons[746]=384'h0ccccccccccccccccccc999999999999999cccccccccccccccccccccccc999999999999999ccccccccccccccccccccc0;
        icons[747]=384'h0cccccccccccccccccccc9999999999999cccccccccccccccccccccccccc9999999999999cccccccccccccccccccccc0;
        icons[748]=384'h0cccccccccccccccccccc9999999999999cccccccccccccccccccccccccc9999999999999cccccccccccccccccccccc0;
        icons[749]=384'h0ccccccccccccccccccccc99999999999cccccccccccccccccccccccccccc99999999999ccccccccccccccccccccccc0;
        icons[750]=384'h0cccccccccccccccccccccc999999999cccccccccccccccccccccccccccccc999999999cccccccccccccccccccccccc0;
        icons[751]=384'h0cccccccccccccccccccccccc99999cccccccccccccccccccccccccccccccccc99999cccccccccccccccccccccccccc0;
        icons[752]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[753]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[754]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[755]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[756]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[757]=384'h000cc66666666666666666666666666666666666666666666666666666666666666666666666666666666666666cc000;
        icons[758]=384'h0000c66666666666666666666666666666666666666666666666666666666666666666666666666666666666666c0000;
        icons[759]=384'h000006666666666666666666666666666666666666666666666666666666666666666666666666666666666666600000;
        icons[760]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[761]=384'h0000000cccccccc33333333333333cccccccccccccc33333333333333cccccccccccccc33333333333333cccc0000000;
        icons[762]=384'h00000000ccccccc33333333333333cccccccccccccc33333333333333cccccccccccccc33333333333333ccc00000000;
        icons[763]=384'h000000000cccccc33333333333333cccccccccccccc33333333333333cccccccccccccc33333333333333cc000000000;
        icons[764]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[765]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[766]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[767]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[768]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[769]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[770]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[771]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[772]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[773]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[774]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[775]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[776]=384'h00000cccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccccccccccccc00000;
        icons[777]=384'h0000ccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccccccccccccccccccc0000;
        icons[778]=384'h000cccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccccccccccccccc000;
        icons[779]=384'h000cccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccccccccccccccc000;
        icons[780]=384'h00ccccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccccccccccccccccccccc00;
        icons[781]=384'h00ccccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccccccccccccccccccccc00;
        icons[782]=384'h00ccccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccccccccccccccccccccc00;
        icons[783]=384'h0cccccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccccccccccccccccc0;
        icons[784]=384'h0cccccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccccccccccccccccc0;
        icons[785]=384'h0cccccccccccccccccccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccccc3ccccccccccccc0;
        icons[786]=384'h0cccccccccccccccccccccccccccccccccccccccccccccc3333ccccccccccccccccccccccccccccc333cccccccccccc0;
        icons[787]=384'h0cccccccccccccccc3ccccccccccccccccccccccccccccc3333cccccccccccccccccccccccccccc33333ccccccccccc0;
        icons[788]=384'h0ccccccccccccccc333cccccccccccccccccccccccccccc3333ccccccccccccccccccccccccccc33333cccccccccccc0;
        icons[789]=384'h0cccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc33333ccccccccccccc0;
        icons[790]=384'h0ccccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccccccccccccc33333cccccccccccccc0;
        icons[791]=384'h0cccccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccccccccccc33333ccccccccccccccc0;
        icons[792]=384'h0ccccccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccccccccc33333cccccccccccccccc0;
        icons[793]=384'h0cccccccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccccccc33333ccccccccccccccccc0;
        icons[794]=384'h0ccccccccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccccc33333cccccccccccccccccc0;
        icons[795]=384'h0cccccccccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccc33333ccccccccccccccccccc0;
        icons[796]=384'h0ccccccccccccccccccccc33333ccccccccccccccccccccccccccccccccccccccccccccc333cccccccccccccccccccc0;
        icons[797]=384'h0cccccccccccccccccccccc333cccccccccccccc44444444444444444cccccccccccccccc3ccccccccccccccccccccc0;
        icons[798]=384'h0ccccccccccccccccccccccc3cccccccccccc44444444444444444444444ccccccccccccccccccccccccccccccccccc0;
        icons[799]=384'h0cccccccccccccccccccccccccccccccccc444444444444444444444444444ccccccccccccccccccccccccccccccccc0;
        icons[800]=384'h0ccccccccccccccccccccccccccccccccc44444444444444444444444444444cccccccccccccccccccccccccccccccc0;
        icons[801]=384'h0ccccccccccccccccccccccccccccccc444444444444444444444444444444444cccccccccccccccccccccccccccccc0;
        icons[802]=384'h0cccccccccccccccccccccccccccccc44444444444444444444444444444444444ccccccccccccccccccccccccccccc0;
        icons[803]=384'h0ccccccccccccccccccccccccccccc4444444444444444444444444444444444444cccccccccccccccccccccccccccc0;
        icons[804]=384'h0cccccccccccccccccccccccccccc444444444444444444444444444444444444444ccccccccccccccccccccccccccc0;
        icons[805]=384'h0cccccccccccccccccccccccccccc444444444444444444444444444444444444444ccccccccccccccccccccccccccc0;
        icons[806]=384'h0ccccccccccccccccccccccccccc44444411114444444444444444444444444444444cccccccccccccccccccccccccc0;
        icons[807]=384'h0cccccccccccccccccccccccccc4444441111114444444444444444444444444444444ccccccccccccccccccccccccc0;
        icons[808]=384'h0cccccccccccccccccccccccccc4444411111111444444444444444444444444444444ccccccccccccccccccccccccc0;
        icons[809]=384'h0ccccccccccccccccccccccccc444444111111114444444444444444444444444444444cccccccccccccccccccccccc0;
        icons[810]=384'h0ccccccccccccccccccccccccc444444111111114444444444444444444444444444444cccccccccccccccccccccccc0;
        icons[811]=384'h0ccccccccccccccccccccccccc444444111111114444444444444444444444444444444cccccccccccccccccccccccc0;
        icons[812]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[813]=384'h0cccc3333333333333ccccccc44444441111111144444444444444444444444444444444ccccccc3333333333333ccc0;
        icons[814]=384'h0cccc3333333333333ccccccc44444441111111144444444444444444444444444444444ccccccc3333333333333ccc0;
        icons[815]=384'h0cccc3333333333333ccccccc44444441111111144444444444444444444444444444444ccccccc3333333333333ccc0;
        icons[816]=384'h0cccc3333333333333ccccccc44444441111111144444444444444444444444444444444ccccccc3333333333333ccc0;
        icons[817]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[818]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[819]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[820]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[821]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[822]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[823]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[824]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[825]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[826]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[827]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[828]=384'h0cccccccccccccccccccccccc44444441111111144444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[829]=384'h0cccccccccccccccccccccccc44444444111111444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[830]=384'h0cccccccccccccccccccccccc44444444411114444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[831]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[832]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[833]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[834]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[835]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[836]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[837]=384'h0cccccccccccccccccccccccc44444444444444444444444444444444444444444444444ccccccccccccccccccccccc0;
        icons[838]=384'h0cccccccccccccccccccc6666666666666666666666666666666666666666666666666666666ccccccccccccccccccc0;
        icons[839]=384'h0cccccccccccccccccc66666666666666666666666666666666666666666666666666666666666ccccccccccccccccc0;
        icons[840]=384'h0cccccccccccccccccc66666666666666666666666666666666666666666666666666666666666ccccccccccccccccc0;
        icons[841]=384'h0ccccccccccccccccc6666666666666666666666666666666666666666666666666666666666666cccccccccccccccc0;
        icons[842]=384'h0ccccccccccccccccc6666666666666666666666666666666666666666666666666666666666666cccccccccccccccc0;
        icons[843]=384'h0ccccccccccccccccc6666666666666666666666666666666666666666666666666666666666666cccccccccccccccc0;
        icons[844]=384'h0ccccccccccccccccc6666666666666666666666666666666666666666666666666666666666666cccccccccccccccc0;
        icons[845]=384'h0ccccccccccccccccc6666666666666666666666666666666666666666666666666666666666666cccccccccccccccc0;
        icons[846]=384'h0ccccccccccccccccc6666666666666666666666666666666666666666666666666666666666666cccccccccccccccc0;
        icons[847]=384'h0ccccccccccccccccc6666666666666666666666666666666666666666666666666666666666666cccccccccccccccc0;
        icons[848]=384'h0cccccccccccccccccc66666666666666666666666666666666666666666666666666666666666ccccccccccccccccc0;
        icons[849]=384'h00ccccccccccccccccc66666666666666666666666666666666666666666666666666666666666cccccccccccccccc00;
        icons[850]=384'h00ccccccccccccccccccc6666666666666666666666666666666666666666666666666666666cccccccccccccccccc00;
        icons[851]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[852]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[853]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[854]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[855]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[856]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[857]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[858]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[859]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[860]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[861]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[862]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[863]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[864]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        icons[865]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[866]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[867]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[868]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[869]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[870]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[871]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[872]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[873]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[874]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[875]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[876]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[877]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[878]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[879]=384'h0ccccccccccccccccccccccccccccccccccccccccccc222222222cccccccccccccccccccccccccccccccccccccccccc0;
        icons[880]=384'h0ccccccccccccccccccccccccccccccccccccccc22222222222222222cccccccccccccccccccccccccccccccccccccc0;
        icons[881]=384'h0ccccccccccccccccccccccccccccccccccccc222222222222222222222cccccccccccccccccccccccccccccccccccc0;
        icons[882]=384'h0ccccccccccccccccccccccccccccccccccc2222222222222222222222222cccccccccccccccccccccccccccccccccc0;
        icons[883]=384'h0cccccccccccccccccccccccccccccccccc222222222ccccccccc222222222ccccccccccccccccccccccccccccccccc0;
        icons[884]=384'h0cccccccccccccccccccccccccccccccc22222222ccccccccccccccc22222222ccccccccccccccccccccccccccccccc0;
        icons[885]=384'h0ccccccccccccccccccccccccccccccc2222222ccccccccccccccccccc2222222cccccccccccccccccccccccccccccc0;
        icons[886]=384'h0cccccccccccccccccccccccccccccc222222ccccccccccccccccccccccc222222ccccccccccccccccccccccccccccc0;
        icons[887]=384'h0ccccccccccccccccccccccccccccc222222ccccccccccccccccccccccccc222222cccccccccccccccccccccccccccc0;
        icons[888]=384'h0cccccccccccccccccccccccccccc22222ccccccccccccccccccccccccccccc22222ccccccccccccccccccccccccccc0;
        icons[889]=384'h0ccccccccccccccccccccccccccc22222c11111111111111111111111111111c22222cccccccccccccccccccccccccc0;
        icons[890]=384'h0ccccccccccccccccccccccccccc2222cc11111111111111111111111111111cc2222cccccccccccccccccccccccccc0;
        icons[891]=384'h0cccccccccccccccccccccccccc22222cc11111111111111111111111111111cc22222ccccccccccccccccccccccccc0;
        icons[892]=384'h0ccccccccccccccccccccccccc22222ccc11111111111111111111111111111ccc22222cccccccccccccccccccccccc0;
        icons[893]=384'h0ccccccccccccccccccccccccc2222cccc111111111111111111111111111111ccc2222cccccccccccccccccccccccc0;
        icons[894]=384'h0cccccccccccccccccccccccc22222cccc111111111111111111111111111111ccc22222ccccccccccccccccccccccc0;
        icons[895]=384'h0cccccccccccccccccccccccc2222ccccc1111111111111111111111111111111ccc2222ccccccccccccccccccccccc0;
        icons[896]=384'h0ccccccccccccccccccccccc2222cccccc111111111111111111111111111111ccccc2222cccccccccccccccccccccc0;
        icons[897]=384'h0ccccccccccccccccccccccc2222ccccccccccccccccccccccccccccc1111111ccccc2222cccccccccccccccccccccc0;
        icons[898]=384'h0cccccccccccccccccccccc22222cccccccccccccccccccccccccccc1111111cccccc22222ccccccccccccccccccccc0;
        icons[899]=384'h0cccccccccccccccccccccc2222ccccccccccccccccccccccccccccc111111cccccccc2222ccccccccccccccccccccc0;
        icons[900]=384'h0cccccccccccccccccccccc2222cccccccccccccccccccccccccccc111111ccccccccc2222ccccccccccccccccccccc0;
        icons[901]=384'h0ccccccccccccccccccccc2222cccccccccccccccccccccccccccc1111111cccccccccc2222cccccccccccccccccccc0;
        icons[902]=384'h0ccccccccccccccccccccc2222cccccccccccccccccccccccccccc111111ccccccccccc2222cccccccccccccccccccc0;
        icons[903]=384'h0ccccccccccccccccccccc2222ccccccccccccccccccccccccccc111111cccccccccccc2222cccccccccccccccccccc0;
        icons[904]=384'h0ccccccccccccccccccccc2222cccccccccccccccccccccccccc1111111cccccccccccc2222cccccccccccccccccccc0;
        icons[905]=384'h0cccccccccccccccccccc22222ccccccccccccccccccccccccc1111111ccccccccccccc22222ccccccccccccccccccc0;
        icons[906]=384'h0cccccccccccccccccccc2222cccccccccccccccccccccccccc111111ccccccccccccccc2222ccccccccccccccccccc0;
        icons[907]=384'h0cccccccccccccccccccc2222ccccccccccccccccccccccccc111111cccccccccccccccc2222ccccccccccccccccccc0;
        icons[908]=384'h0cccccccccccccccccccc2222cccccccccccccccccccccccc1111111cccccccccccccccc2222ccccccccccccccccccc0;
        icons[909]=384'h0cccccccccccccccccccc2222cccccccccccccccccccccccc111111ccccccccccccccccc2222ccccccccccccccccccc0;
        icons[910]=384'h0cccccccccccccccccccc2222ccccccccccccccccccccccc111111cccccccccccccccccc2222ccccccccccccccccccc0;
        icons[911]=384'h0cccccccccccccccccccc2222cccccccccccccccccccccc111111ccccccccccccccccccc2222ccccccccccccccccccc0;
        icons[912]=384'h0cccccccccccccccccccc2222ccccccccccccccccccccc1111111ccccccccccccccccccc2222ccccccccccccccccccc0;
        icons[913]=384'h0cccccccccccccccccccc2222ccccccccccccccccccccc111111cccccccccccccccccccc2222ccccccccccccccccccc0;
        icons[914]=384'h0cccccccccccccccccccc2222cccccccccccccccccccc111111ccccccccccccccccccccc2222ccccccccccccccccccc0;
        icons[915]=384'h0cccccccccccccccccccc2222ccccccccccccccccccc1111111ccccccccccccccccccccc2222ccccccccccccccccccc0;
        icons[916]=384'h0cccccccccccccccccccc2222cccccccccccccccccc1111111cccccccccccccccccccccc2222ccccccccccccccccccc0;
        icons[917]=384'h0cccccccccccccccccccc22222ccccccccccccccccc111111cccccccccccccccccccccc22222ccccccccccccccccccc0;
        icons[918]=384'h0ccccccccccccccccccccc2222cccccccccccccccc111111ccccccccccccccccccccccc2222cccccccccccccccccccc0;
        icons[919]=384'h0ccccccccccccccccccccc2222ccccccccccccccc1111111ccccccccccccccccccccccc2222cccccccccccccccccccc0;
        icons[920]=384'h0ccccccccccccccccccccc2222ccccccccccccccc111111cccccccccccccccccccccccc2222cccccccccccccccccccc0;
        icons[921]=384'h0ccccccccccccccccccccc2222cccccccccccccc111111ccccccccccccccccccccccccc2222cccccccccccccccccccc0;
        icons[922]=384'h0cccccccccccccccccccccc2222cccccccccccc1111111cccccccccccccccccccccccc2222ccccccccccccccccccccc0;
        icons[923]=384'h0cccccccccccccccccccccc2222ccccccccccc1111111ccccccccccccccccccccccccc2222ccccccccccccccccccccc0;
        icons[924]=384'h0cccccccccccccccccccccc22222cccccccccc11111111111111111111111cccccccc22222ccccccccccccccccccccc0;
        icons[925]=384'h0ccccccccccccccccccccccc2222ccccccccc111111111111111111111111cccccccc2222cccccccccccccccccccccc0;
        icons[926]=384'h0ccccccccccccccccccccccc2222ccccccccc111111111111111111111111cccccccc2222cccccccccccccccccccccc0;
        icons[927]=384'h0cccccccccccccccccccccccc2222ccccccccc11111111111111111111111ccccccc2222ccccccccccccccccccccccc0;
        icons[928]=384'h0cccccccccccccccccccccccc22222ccccccccc1111111111111111111111cccccc22222ccccccccccccccccccccccc0;
        icons[929]=384'h0ccccccccccccccccccccccccc2222ccccccccccccccccccccccccccccccccccccc2222cccccccccccccccccccccccc0;
        icons[930]=384'h0ccccccccccccccccccccccccc22222ccc11111111111111111111111111111ccc22222cccccccccccccccccccccccc0;
        icons[931]=384'h0cccccccccccccccccccccccccc22222cc11111111111111111111111111111cc22222ccccccccccccccccccccccccc0;
        icons[932]=384'h0ccccccccccccccccccccccccccc2222cc11111111111111111111111111111cc2222cccccccccccccccccccccccccc0;
        icons[933]=384'h0ccccccccccccccccccccccccccc22222c11111111111111111111111111111c22222cccccccccccccccccccccccccc0;
        icons[934]=384'h0cccccccccccccccccccccccccccc22222ccccccccccccccccccccccccccccc22222ccccccccccccccccccccccccccc0;
        icons[935]=384'h0ccccccccccccccccccccccccccccc222222ccccccccccccccccccccccccc222222cccccccccccccccccccccccccccc0;
        icons[936]=384'h0cccccccccccccccccccccccccccccc222222ccccccccccccccccccccccc222222ccccccccccccccccccccccccccccc0;
        icons[937]=384'h0ccccccccccccccccccccccccccccccc2222222ccccccccccccccccccc2222222cccccccccccccccccccccccccccccc0;
        icons[938]=384'h0cccccccccccccccccccccccccccccccc22222222ccccccccccccccc22222222ccccccccccccccccccccccccccccccc0;
        icons[939]=384'h0cccccccccccccccccccccccccccccccccc222222222ccccccccc222222222ccccccccccccccccccccccccccccccccc0;
        icons[940]=384'h0ccccccccccccccccccccccccccccccccccc2222222222222222222222222cccccccccccccccccccccccccccccccccc0;
        icons[941]=384'h0ccccccccccccccccccccccccccccccccccccc222222222222222222222cccccccccccccccccccccccccccccccccccc0;
        icons[942]=384'h0ccccccccccccccccccccccccccccccccccccccc22222222222222222cccccccccccccccccccccccccccccccccccccc0;
        icons[943]=384'h0ccccccccccccccccccccccccccccccccccccccccccc222222222cccccccccccccccccccccccccccccccccccccccccc0;
        icons[944]=384'h0cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0;
        icons[945]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[946]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[947]=384'h00cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00;
        icons[948]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[949]=384'h000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000;
        icons[950]=384'h0000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000;
        icons[951]=384'h00000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000;
        icons[952]=384'h000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000;
        icons[953]=384'h0000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000;
        icons[954]=384'h00000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc00000000;
        icons[955]=384'h000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000;
        icons[956]=384'h0000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0000000000;
        icons[957]=384'h000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000;
        icons[958]=384'h000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000000000000;
        icons[959]=384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
        texts[0]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[1]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[2]=224'h0000000000000000f1e0c0000000000f000000f00000000000000000;
        texts[3]=224'h0000000000000000f1e7c1fffff8000f000000f00000000000000000;
        texts[4]=224'h000000000000007ff1ffe1fffff87fffffe000f00000000000000000;
        texts[5]=224'h000000000000007ff1ffc1e000787fffffe3fffffe00000000000000;
        texts[6]=224'h0000000000000000f1fcc1fffff87fffffe3fffffe00000000000000;
        texts[7]=224'h0000000000000003f1e0f1fffff8000f0003fffffe00000000000000;
        texts[8]=224'h000000000000003ff1e0e1e00078000f00001c038000000000000000;
        texts[9]=224'h000000000000007ff1e0e1fffff81fffff803e07c000000000000000;
        texts[10]=224'h000000000000007cf1ffe1fffff81fffff801f078000000000000000;
        texts[11]=224'h0000000000000060f0ffc000f0001fffff87ffffff00000000000000;
        texts[12]=224'h0000000000000000f07f8000f00000000007ffffff00000000000000;
        texts[13]=224'h000000000000000000000fffffff00000007ffffff00000000000000;
        texts[14]=224'h000000000000001fffff8fffffff1fffff8000000000000000000000;
        texts[15]=224'h000000000000001fffff800000001fffff80fffff000000000000000;
        texts[16]=224'h000000000000001e000780fffff01fffff80fffff000000000000000;
        texts[17]=224'h000000000000001e000780fffff01e0f0780fffff000000000000000;
        texts[18]=224'h000000000000001fffff80f000f01e0f0780e0007000000000000000;
        texts[19]=224'h000000000000001fffff80f000f01e0f0780e0007000000000000000;
        texts[20]=224'h000000000000001e000780fffff01fffff80fffff000000000000000;
        texts[21]=224'h000000000000001e000780fffff01fffff80fffff000000000000000;
        texts[22]=224'h000000000000001fffff800070001fffff80fffff000000000000000;
        texts[23]=224'h000000000000001fffff801071803c000780e0007000000000000000;
        texts[24]=224'h000000000000001e0007807873e03c000000e0007000000000000000;
        texts[25]=224'h000000000000001e000f03f8f1fc7c000000fffff000000000000000;
        texts[26]=224'h000000000000001e03ff07e7f07ef8000000fffff000000000000000;
        texts[27]=224'h000000000000001e03ff0787f01e70000000fffff000000000000000;
        texts[28]=224'h000000000000001e01fe0203e00420000000e0007000000000000000;
        texts[29]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[30]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[31]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[32]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[33]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[34]=224'h00000000000000001e000010000000780001e00f8000000000000000;
        texts[35]=224'h00000000000000001e000038000000780001c00f8000000000000000;
        texts[36]=224'h00000000000000001e00007cfffc00f00001c01fc000000000000000;
        texts[37]=224'h000000000000001fffff80f8fffc3fffffc1fc3fc000000000000000;
        texts[38]=224'h000000000000001fffff81f0fffc3fffffc3fc3de000000000000000;
        texts[39]=224'h000000000000001fffff87e000003fffffc3fc78f000000000000000;
        texts[40]=224'h000000000000001e000787c0000003c0000780f07800000000000000;
        texts[41]=224'h000000000000001e00078398000003c0000703e63e00000000000000;
        texts[42]=224'h000000000000001e0007811c00000787800fffef1f00000000000000;
        texts[43]=224'h000000000000001fffff803e000007878007ff8f0e00000000000000;
        texts[44]=224'h000000000000001fffff807dffff0f078007fd078400000000000000;
        texts[45]=224'h000000000000001fffff80f9ffff0f078004e0030000000000000000;
        texts[46]=224'h000000000000001e000780f1ffff1fffff84e0020000000000000000;
        texts[47]=224'h000000000000001e000781f001e01fffff80e1fffc00000000000000;
        texts[48]=224'h000000000000001e000783f001e01fffff8ffdfffc00000000000000;
        texts[49]=224'h000000000000001fffff87f001e00007800ffdfffc00000000000000;
        texts[50]=224'h000000000000001fffff87f001e00007800ffc007c00000000000000;
        texts[51]=224'h000000000000001fffff87f001e000078000e000f800000000000000;
        texts[52]=224'h000000000000001e000784f001e07fffffe0e040f000000000000000;
        texts[53]=224'h000000000000001e000780f001e07fffffe0e0f1f000000000000000;
        texts[54]=224'h000000000000001e000780f001e07fffffe0e5fbe000000000000000;
        texts[55]=224'h000000000000001e000780f001e000078000fcffc000000000000000;
        texts[56]=224'h000000000000001fffff80f001e000078000fc3f8000000000000000;
        texts[57]=224'h000000000000001fffff80f001e000078001fc0fe000000000000000;
        texts[58]=224'h000000000000001fffff80f07fe000078001f007f000000000000000;
        texts[59]=224'h000000000000001e000780f07fc000078001c001e000000000000000;
        texts[60]=224'h000000000000001e000780f03f800007800080004000000000000000;
        texts[61]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[62]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[63]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[64]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[65]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[66]=224'h00000000000000301e00000780000000f000f0070000000000000000;
        texts[67]=224'h000000000000007c1e00000780000000f000f00f0000000000000000;
        texts[68]=224'h000000000000003e3fffe00f00007fcfffc1ffcffe00000000000000;
        texts[69]=224'h000000000000001f3fffe3fffffc7fcfffc1ffdffe00000000000000;
        texts[70]=224'h000000000000000e7fffe3fffffc7fcfffc3fffffe00000000000000;
        texts[71]=224'h0000000000000004780003fffffc7bce63c7cc3ce000000000000000;
        texts[72]=224'h0000000000000000f000003c00007bcef3c79e39f000000000000000;
        texts[73]=224'h0000000000000031ffff803c00007bcef3c70f187000000000000000;
        texts[74]=224'h0000000000000079ffff807878007bce7b8204f02000000000000000;
        texts[75]=224'h000000000000007edfff807878007bce338000f00000000000000000;
        texts[76]=224'h000000000000003e800000f078007bce7f81fffff800000000000000;
        texts[77]=224'h000000000000001c000000f078007bce7f81fffff800000000000000;
        texts[78]=224'h00000000000000047fff01fffff87bce3e01fffff800000000000000;
        texts[79]=224'h00000000000000007fff01fffff87bce0001e0f07800000000000000;
        texts[80]=224'h00000000000000087fff01fffff87bcfffe1e0f07800000000000000;
        texts[81]=224'h000000000000000f000f000078007bcfffe1e0f07800000000000000;
        texts[82]=224'h000000000000000e000f000078007bcfffe1fffff800000000000000;
        texts[83]=224'h000000000000001e000f000078007bc001e1fffff800000000000000;
        texts[84]=224'h000000000000001e000f47fffffe7fdffde1fffff800000000000000;
        texts[85]=224'h000000000000001e000f77fffffe7fdffde1e0f07800000000000000;
        texts[86]=224'h000000000000003c000f77fffffe7fdffde1e0f07800000000000000;
        texts[87]=224'h000000000000003c0007600078007bc001e1e0f07800000000000000;
        texts[88]=224'h000000000000003c0007e00078007bc0e7e1fffff800000000000000;
        texts[89]=224'h00000000000000780007e000780000007fc1fffff800000000000000;
        texts[90]=224'h00000000000000780007e000780000007fc1fffff800000000000000;
        texts[91]=224'h00000000000000780003c000780000007f01e0007800000000000000;
        texts[92]=224'h000000000000001800000000780000000001e0007800000000000000;
        texts[93]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[94]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[95]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[96]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[97]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[98]=224'h000000000000000603c0000000000000000000000000000000000000;
        texts[99]=224'h000000000000000f03c003fffffc3fffffc1fffff800000000000000;
        texts[100]=224'h000000000000000f078003fffffc3fffffc1fffff800000000000000;
        texts[101]=224'h000000000000000f87ffe3fffffc3fffffc1fffff800000000000000;
        texts[102]=224'h000000000000007fefffe000f000000f0001e0007800000000000000;
        texts[103]=224'h000000000000007fffffe000f000000f0001e0007800000000000000;
        texts[104]=224'h000000000000007ffe000000f000000f0001fffff800000000000000;
        texts[105]=224'h000000000000001c7c380000f000000f0001fffff800000000000000;
        texts[106]=224'h000000000000001c0f380000f000000f0001e0007800000000000000;
        texts[107]=224'h000000000000001c0739c000f000000f0001e0007800000000000000;
        texts[108]=224'h000000000000001fe73fc000f000000f0001fffff800000000000000;
        texts[109]=224'h000000000000001fe7ffc000f000000f0001fffff800000000000000;
        texts[110]=224'h000000000000003ffff9c000f000000f0001e0007800000000000000;
        texts[111]=224'h000000000000003cffb9c000f000000f0001e0007800000000000000;
        texts[112]=224'h000000000000003cef39c000f000000f0001fffff800000000000000;
        texts[113]=224'h000000000000003ce739c000f000000f0001fffff800000000000000;
        texts[114]=224'h000000000000003ce739c000f000000f0001e0007800000000000000;
        texts[115]=224'h0000000000000038e73fc000f000000f0001e0007800000000000000;
        texts[116]=224'h0000000000000038e73fc000f000000f000fffffff00000000000000;
        texts[117]=224'h0000000000000038e73fc000f000000f000fffffff00000000000000;
        texts[118]=224'h0000000000000038e738f000f000000f000fffffff00000000000000;
        texts[119]=224'h0000000000000079e738f000f000000f00000e070000000000000000;
        texts[120]=224'h0000000000000079e701e000f000000f00003e0fc000000000000000;
        texts[121]=224'h000000000000007fc7ffe7fffffe7fffffe1ff0ff800000000000000;
        texts[122]=224'h0000000000000077c7ffe7fffffe7fffffe7fc03fe00000000000000;
        texts[123]=224'h000000000000006783ff87fffffe7fffffe3e0007c00000000000000;
        texts[124]=224'h00000000000000200000000000000000000100000800000000000000;
        texts[125]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[126]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[127]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[128]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[129]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[130]=224'h000000000000000000000000f0800000f00000000000000000000000;
        texts[131]=224'h000000000000000000000000f1c07fc0f70000000000000000000000;
        texts[132]=224'h000000000000000000000000f3e07fc0ff8000000000000000000000;
        texts[133]=224'h000000000000000000000000f1e07fc0f7e000000000000000000000;
        texts[134]=224'h000000000000000000000000f0f079c0f3c000000000000000000000;
        texts[135]=224'h000000000000000000000000f0e079c0f18000000000000000000000;
        texts[136]=224'h000000000000000000000000f04079c0f00000000000000000000000;
        texts[137]=224'h000000000000000000000000f00079dfffe000000000000000000000;
        texts[138]=224'h0000000000000000000007fffffe79dfffe000000000000000000000;
        texts[139]=224'h0000000000000000000007fffffe79dfffe000000000000000000000;
        texts[140]=224'h0000000000000000000007fffffe79dfffe000000000000000000000;
        texts[141]=224'h000000000000000000000001f00079c1f00000000000000000000000;
        texts[142]=224'h000000000000000000000001f80079c1f80000000000000000000000;
        texts[143]=224'h000000000000000000000001f80079c1f80000000000000000000000;
        texts[144]=224'h000000000000000000000003f80079c1fc0000000000000000000000;
        texts[145]=224'h000000000000000000000003fc0079c3fc0000000000000000000000;
        texts[146]=224'h000000000000000000000007bc0079c3dc0000000000000000000000;
        texts[147]=224'h0000000000000000000000079e0079c79e0000000000000000000000;
        texts[148]=224'h00000000000000000000000f9f007fc79f0000000000000000000000;
        texts[149]=224'h00000000000000000000001f0f807fcf8f8000000000000000000000;
        texts[150]=224'h00000000000000000000003e07807fdf0f8000000000000000000000;
        texts[151]=224'h00000000000000000000007c07e0783f07e000000000000000000000;
        texts[152]=224'h0000000000000000000000fc03f0787e03e000000000000000000000;
        texts[153]=224'h0000000000000000000003f801fc007c03e000000000000000000000;
        texts[154]=224'h0000000000000000000007e000fe003801c000000000000000000000;
        texts[155]=224'h0000000000000000000003c0003c0010000000000000000000000000;
        texts[156]=224'h00000000000000000000010000180000000000000000000000000000;
        texts[157]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[158]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[159]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[160]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[161]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[162]=224'h00000000000000000000007200000000000000000000000000000000;
        texts[163]=224'h0000000000000000f000007f000078c0003c00000000f00000000000;
        texts[164]=224'h00000000000007fff000007780007bc0003c00000000f00000000000;
        texts[165]=224'h00000000000ffbfff9fc0073000079e0043c400ffcf0f00000000000;
        texts[166]=224'h00000000000ffbfe01fdffff800078e00f3cf00ffcf0f00000000000;
        texts[167]=224'h00000000000ff80e01fdffff9ffffffc1fbcf80ffcf0f00000000000;
        texts[168]=224'h00000000000e798e31ddffff9ffffffc3f3c7c0f3cf0f00000000000;
        texts[169]=224'h00000000000e7b8e39ddc0701ffffffc7e3c3e0f3cf0f00000000000;
        texts[170]=224'h00000000000e7bce79ddc07000007800fc3c1f0f3cf0f00000000000;
        texts[171]=224'h00000000000e79ce71dddff300007841f83c0f8f3cf0f00000000000;
        texts[172]=224'h00000000000e79cef1dddff38ffe78f0f03c070f3cf0f00000000000;
        texts[173]=224'h00000000000e79eee1ddc0738ffe78f0403c020f3cf0f00000000000;
        texts[174]=224'h00000000000e788e21ddc07b8ffe79e00000000f3cf0f00000000000;
        texts[175]=224'h00000000000e780e01ddc03f0f1e79e0003c000f3cf0f00000000000;
        texts[176]=224'h00000000000e7ffff9dddfbf0f1e3bc0003c000f3cf0f00000000000;
        texts[177]=224'h00000000000e7ffff9dddfbf0f1e3bc1ffffff8f3cf0f00000000000;
        texts[178]=224'h00000000000e7ffff9dddbbe0f1e3f81ffffff8f3cf0f00000000000;
        texts[179]=224'h00000000000e780e01dddbbe0f1e3f01ffffff8f3cf3f00000000000;
        texts[180]=224'h00000000000e780e01fddbbc0ffe3f00007e000f3cfff00000000000;
        texts[181]=224'h00000000000ff80e01ff9bbdcffe3e00007f000f3cfff00000000000;
        texts[182]=224'h00000000000ff80e01ff9fb9cffe3e2000f7800ffdfff00000000000;
        texts[183]=224'h00000000000ff80e01c39ffd80007e3801e7c00ffcf8f00000000000;
        texts[184]=224'h00000000000e780e01c398fd80007e3803e3e00ffc40f00000000000;
        texts[185]=224'h00000000000e781e000799ff807eff380fc1f80f3c00f00000000000;
        texts[186]=224'h00000000000e01fe000703cf9fffef787f80fe0f0000f00000000000;
        texts[187]=224'h00000000000001fe000301cf9fff87f9fe007f800000f00000000000;
        texts[188]=224'h00000000000001fc000200871e0103f0f8001f000000f00000000000;
        texts[189]=224'h000000000000000000000000000001e0c00006000000f00000000000;
        texts[190]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[191]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[192]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[193]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[194]=224'h00000000000000001f000001e0800000e00000f00000000000000000;
        texts[195]=224'h00000000000000000f0001e3c1c02000e00000f00000000000000000;
        texts[196]=224'h00000000000000000f0003c3c3f07000e00000f00000000000000000;
        texts[197]=224'h000000000000007fffffe3c3c1f0f800e00000f00000000000000000;
        texts[198]=224'h000000000000007fffffe3c3c0607c00e003fffffc00000000000000;
        texts[199]=224'h000000000000007fffffe7ffffff3effffe3fffffc00000000000000;
        texts[200]=224'h00000000000000780001e7ffffff1fffffe3fffffc00000000000000;
        texts[201]=224'h00000000000000786061e7ffffff0cffffe000f00000000000000000;
        texts[202]=224'h0000000000000001f0fc000f000008f0e1e000f00000000000000000;
        texts[203]=224'h000000000000000ff07f000f000000f0e1e000f00000000000000000;
        texts[204]=224'h000000000000003fc00fc01f000000f0e1e000f00000000000000000;
        texts[205]=224'h000000000000001f0f1bc01ffff800f0e1e7fffffe00000000000000;
        texts[206]=224'h00000000000000180f38803ffff808f0e1e7fffffe00000000000000;
        texts[207]=224'h00000000000000000f3c003ffff80ef0e1e7fffffe00000000000000;
        texts[208]=224'h000000000000007fffffe07f00f00ff0e1e000f00000000000000000;
        texts[209]=224'h000000000000007fffffe0ff81f01effffe000f00000000000000000;
        texts[210]=224'h000000000000007fffffe1ff83e01effffe1e0f07800000000000000;
        texts[211]=224'h00000000000000003f8001f3c7c01effffe1e0f07800000000000000;
        texts[212]=224'h00000000000000003fc003e3ef803cf0e1e1e0f07800000000000000;
        texts[213]=224'h000000000000000079e007e1ff003cf0e1e1e0f07800000000000000;
        texts[214]=224'h0000000000000000f9f00fc0fe007800e001e0f07800000000000000;
        texts[215]=224'h0000000000000003f0f80781ff807800e001e0f07800000000000000;
        texts[216]=224'h0000000000000007e07e0707ffe07800e001e0f07800000000000000;
        texts[217]=224'h000000000000001f803f863fe7f8f000e001fffff800000000000000;
        texts[218]=224'h000000000000007f000fe4ff83fe7000e001fffff800000000000000;
        texts[219]=224'h000000000000007c0003e07e007e1000e001fffff800000000000000;
        texts[220]=224'h00000000000000200000c030001c0000e00000007800000000000000;
        texts[221]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[222]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[223]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[224]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[225]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[226]=224'h00000000000000100c0e00001f0000780001c0000000000000000000;
        texts[227]=224'h00000000000000781e1e00001e0000780001c3fffe00000000000000;
        texts[228]=224'h00000000000000780e1e03fe3e0000f00003c3fffe00000000000000;
        texts[229]=224'h000000000000003cffffe3fe3ffc3fffffcffffffe00000000000000;
        texts[230]=224'h000000000000003effffe3fe7ffc3fffffcffc1ce000000000000000;
        texts[231]=224'h000000000000001effffe38efffc3fffffcffc1ce000000000000000;
        texts[232]=224'h000000000000001e01e0038ff83c03c00003801ce000000000000000;
        texts[233]=224'h000000000000000801c0038ff87c03c0000773fffe00000000000000;
        texts[234]=224'h00000000000000007fffc38efc780787800773fffe00000000000000;
        texts[235]=224'h00000000000000007fffc3fe9ff00787800773fffe00000000000000;
        texts[236]=224'h000000000000007c7003c3fe1fe00f078007739cee00000000000000;
        texts[237]=224'h000000000000007c7003c3fe0fe00f07800e739cee00000000000000;
        texts[238]=224'h000000000000007c7fffc0387ffc1fffff8fff99ce00000000000000;
        texts[239]=224'h000000000000001c7fffc039fffe1fffff8fffbdce00000000000000;
        texts[240]=224'h000000000000001c7003c739f87e1fffff8fffbfee00000000000000;
        texts[241]=224'h000000000000001c7003c73ec00e0007800073bffe00000000000000;
        texts[242]=224'h000000000000001c7fffc73e00000007800073bdfe00000000000000;
        texts[243]=224'h000000000000001c7fffc73e7ffc0007800073f7be00000000000000;
        texts[244]=224'h000000000000001c7003c7387ffc7fffffeffff3be00000000000000;
        texts[245]=224'h000000000000001c7003c7387ffc7fffffeffff79e00000000000000;
        texts[246]=224'h000000000000001c7fffc738703c7fffffe7ffa70e00000000000000;
        texts[247]=224'h000000000000003e7fffc73f703c0007800073830e00000000000000;
        texts[248]=224'h000000000000003f8000077f703c0007800073800e00000000000000;
        texts[249]=224'h000000000000007fffffe7ff7ffc0007800073807e00000000000000;
        texts[250]=224'h0000000000000073ffffe7fc7ffc0007800073807c00000000000000;
        texts[251]=224'h0000000000000060ffffe7007ffc0007800073807800000000000000;
        texts[252]=224'h000000000000004000000000703c0007800000000000000000000000;
        texts[253]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[254]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[255]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[256]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[257]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[258]=224'h0000000000038e0e003c01c001e0000038e0e0038000000000000000;
        texts[259]=224'h00000000001fffdc003c03c001e00001fffdc00387fff00000000000;
        texts[260]=224'h00000000001fffdff87ff3ff81e00001fffdff8387fff00000000000;
        texts[261]=224'h0000000000070e3ff87ff7ff81fffff870e3ff8387fff00000000000;
        texts[262]=224'h000000000007fffc60ffffff81fffff87fffc6038700f00000000000;
        texts[263]=224'h00000000000ffffce1f30f3801fffff8ffffce1ff700f00000000000;
        texts[264]=224'h00000000001c03afc1e78e7c01e00001c03afc1ff700f00000000000;
        texts[265]=224'h00000000001ff387c1c3c61c01e00001ff387c1ff71fe00000000000;
        texts[266]=224'h000000000016338fe0813c0803e000016338fe03871fe00000000000;
        texts[267]=224'h000000000007ff3cf8003c0003e000007ff3cf83871fc00000000000;
        texts[268]=224'h000000000007ffd8307ffffe03fffff07ffd83038700000000000000;
        texts[269]=224'h00000000000001c0007ffffe03fffff0001c000387fff00000000000;
        texts[270]=224'h00000000001ffffff87ffffe03ffffe1ffffff83b7fff00000000000;
        texts[271]=224'h00000000001ffffff8783c1e000001e1ffffff87f7fff00000000000;
        texts[272]=224'h000000000000000000783c1e000001e00000001ff720f00000000000;
        texts[273]=224'h000000000003ffffc0783c1e000001e03ffffc1f8770f00000000000;
        texts[274]=224'h000000000003ffffc07ffffe000001e03ffffc1b8770e00000000000;
        texts[275]=224'h0000000000000000007ffffe1ffffde0000000038779e00000000000;
        texts[276]=224'h000000000003ffffc07ffffe1ffffde03ffffc038739e00000000000;
        texts[277]=224'h000000000003ffffc0783c1e1ffffde03ffffc03871fc00000000000;
        texts[278]=224'h000000000000000000783c1e000001e000000003870f800000000000;
        texts[279]=224'h000000000003ffffc0783c1e000001e03ffffc03871f800000000000;
        texts[280]=224'h000000000003ffffc07ffffe000003e03ffffc03877fc00000000000;
        texts[281]=224'h0000000000038003c07ffffe0003ffc038003c0387fff00000000000;
        texts[282]=224'h000000000003ffffc07ffffe0001ffc03ffffc1f87f8f80000000000;
        texts[283]=224'h000000000003ffffc078001e0001ff003ffffc1f8770780000000000;
        texts[284]=224'h0000000000038003c078001e0000000038003c1f0740300000000000;
        texts[285]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[286]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[287]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[288]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[289]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[290]=224'h000000000000000f007800200f000800000000003c00000000000000;
        texts[291]=224'h000000000000001f00f800700f001c3fffc3ffe03c00000000000000;
        texts[292]=224'h000000000000001ffeffe0f80f003e3fffc3ffe03c00000000000000;
        texts[293]=224'h000000000000003fffffe1f3fffc1f3fffc3ffe73c00000000000000;
        texts[294]=224'h00000000000000f9c3ef01e3fffc0f3c03c381e73c00000000000000;
        texts[295]=224'h0000000000000071efc703c3fffc0f3c03c381e73c00000000000000;
        texts[296]=224'h00000000000000208f8207800f00043c03c381e73c00000000000000;
        texts[297]=224'h00000000000000000f0003000f00003c03c381e73c00000000000000;
        texts[298]=224'h000000000000003fffffc2200f007e3c03c3ffe73c00000000000000;
        texts[299]=224'h000000000000003fffffc037ffff7e3c03c3ffe73c00000000000000;
        texts[300]=224'h000000000000003fffffc07fffff7e3c03c3ffe73c00000000000000;
        texts[301]=224'h00000000000000000f00007fffff1e3c03c000073c00000000000000;
        texts[302]=224'h00000000000000000f0000f000001e3c03c070073c00000000000000;
        texts[303]=224'h000000000000007ffffff1e000f01e3fffc070073c00000000000000;
        texts[304]=224'h000000000000007ffffff3e000f01e3fffc7ffe73c00000000000000;
        texts[305]=224'h000000000000007ffffff3e7fffe1e3fffc7ffe73c00000000000000;
        texts[306]=224'h0000000000000000003c07e7fffe1e000007ffe73c00000000000000;
        texts[307]=224'h0000000000000000003c07e7fffe1e460400f0e73c00000000000000;
        texts[308]=224'h000000000000007fffffe6e0c0f01ec71e00f1e73c00000000000000;
        texts[309]=224'h000000000000007fffffe4e1e0f01fcf9f00f1e73c00000000000000;
        texts[310]=224'h000000000000007fffffe0e1f0f01fdf0f81e1e73c00000000000000;
        texts[311]=224'h0000000000000003c03c00e0f8f01f3e07c1e1e03c00000000000000;
        texts[312]=224'h0000000000000003e03c00e070f01e7c07c3c1e03c00000000000000;
        texts[313]=224'h0000000000000001e07c00e020f01cfc03e7dfe03c00000000000000;
        texts[314]=224'h0000000000000000e7fc00e01ff008f801f79fc3fc00000000000000;
        texts[315]=224'h000000000000000087f800e01fe0007001e38f83fc00000000000000;
        texts[316]=224'h000000000000000007f000e00fc0002000810003f800000000000000;
        texts[317]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[318]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[319]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[320]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[321]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[322]=224'h00000000000000000f000000f0000800000000003c00000000000000;
        texts[323]=224'h00000000000000000f000000f0001c3fffc3ffe03c00000000000000;
        texts[324]=224'h000000000000007fffffe000f0003e3fffc3ffe03c00000000000000;
        texts[325]=224'h000000000000007fffffe3fffffe1f3fffc3ffe73c00000000000000;
        texts[326]=224'h000000000000007fffffe3fffffe0f3c03c381e73c00000000000000;
        texts[327]=224'h00000000000000000f0003fffffe0f3c03c381e73c00000000000000;
        texts[328]=224'h00000000000000000f00001c0380043c03c381e73c00000000000000;
        texts[329]=224'h000000000000001fffff803e07c0003c03c381e73c00000000000000;
        texts[330]=224'h000000000000001fffff801f07807e3c03c3ffe73c00000000000000;
        texts[331]=224'h000000000000001fffff87ffffff7e3c03c3ffe73c00000000000000;
        texts[332]=224'h0000000000000000000007ffffff7e3c03c3ffe73c00000000000000;
        texts[333]=224'h0000000000000000000007ffffff1e3c03c000073c00000000000000;
        texts[334]=224'h000000000000001fffff800000001e3c03c070073c00000000000000;
        texts[335]=224'h000000000000001fffff80fffff01e3fffc070073c00000000000000;
        texts[336]=224'h000000000000001fffff80fffff01e3fffc7ffe73c00000000000000;
        texts[337]=224'h000000000000001e0f0780fffff01e3fffc7ffe73c00000000000000;
        texts[338]=224'h000000000000001e0f0780e000701e000007ffe73c00000000000000;
        texts[339]=224'h000000000000001e0f0780e000701e460400f0e73c00000000000000;
        texts[340]=224'h000000000000001fffff80fffff01ec71e00f1e73c00000000000000;
        texts[341]=224'h000000000000001fffff80fffff01fcf9f00f1e73c00000000000000;
        texts[342]=224'h000000000000001fffff80fffff01fdf0f81e1e73c00000000000000;
        texts[343]=224'h000000000000003c000780e000701f3e07c1e1e03c00000000000000;
        texts[344]=224'h000000000000003c000000e000701e7c07c3c1e03c00000000000000;
        texts[345]=224'h000000000000007c000000fffff01cfc03e7dfe03c00000000000000;
        texts[346]=224'h00000000000000f8000000fffff008f801f79fc3fc00000000000000;
        texts[347]=224'h0000000000000070000000fffff0007001e38f83fc00000000000000;
        texts[348]=224'h0000000000000020000000e00070002000810003f800000000000000;
        texts[349]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[350]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[351]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[352]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[353]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[354]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[355]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[356]=224'h00000000000000000000000000000010000000000000000000000000;
        texts[357]=224'h00000000000000000000000000000038000000000000000000000000;
        texts[358]=224'h00000000000000000000000030000018000000000000000000000000;
        texts[359]=224'h00000000000000000000000030000018000000000000000000000000;
        texts[360]=224'h00000000000000000000000030007ffff80000000000000000000000;
        texts[361]=224'h00000000000000000000001fffff7ffff80000000000000000000000;
        texts[362]=224'h00000000000000000000001fffff0180000000000000000000000000;
        texts[363]=224'h00000000000000000000000060000180000000000000000000000000;
        texts[364]=224'h00000000000000000000000040000180000000000000000000000000;
        texts[365]=224'h000000000000000000000000c0000180000000000000000000000000;
        texts[366]=224'h000000000000000000000000c00001ffe00000000000000000000000;
        texts[367]=224'h000000000000000000000001fffe01ffe00000000000000000000000;
        texts[368]=224'h000000000000000000000001fffe0180600000000000000000000000;
        texts[369]=224'h00000000000000000000000303000180600000000000000000000000;
        texts[370]=224'h00000000000000000000000303000300600000000000000000000000;
        texts[371]=224'h00000000000000000000000603000300400000000000000000000000;
        texts[372]=224'h00000000000000000000000e03000300400000000000000000000000;
        texts[373]=224'h00000000000000000000001c03000600400000000000000000000000;
        texts[374]=224'h00000000000000000000001803000600400000000000000000000000;
        texts[375]=224'h00000000000000000000003003000c00c00000000000000000000000;
        texts[376]=224'h000000000000000000000013ffff1c00c00000000000000000000000;
        texts[377]=224'h000000000000000000000003ffff383fc00000000000000000000000;
        texts[378]=224'h0000000000000000000000000000703f800000000000000000000000;
        texts[379]=224'h00000000000000000000000000002000000000000000000000000000;
        texts[380]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[381]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[382]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[383]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[384]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[385]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[386]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[387]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[388]=224'h00000000000000000000000000000010000000000000000000000000;
        texts[389]=224'h00000000000000000000000000000038000000000000000000000000;
        texts[390]=224'h00000000000000000000000040400018000000000000000000000000;
        texts[391]=224'h000000000000000000000000e0e00018000000000000000000000000;
        texts[392]=224'h00000000000000000000000031807ffff80000000000000000000000;
        texts[393]=224'h00000000000000000000001fffff7ffff80000000000000000000000;
        texts[394]=224'h00000000000000000000001fffff0180000000000000000000000000;
        texts[395]=224'h00000000000000000000000000000180000000000000000000000000;
        texts[396]=224'h00000000000000000000000ffccc0180000000000000000000000000;
        texts[397]=224'h00000000000000000000000ffccc0180000000000000000000000000;
        texts[398]=224'h00000000000000000000000c0ccc01ffe00000000000000000000000;
        texts[399]=224'h00000000000000000000000c0ccc01ffe00000000000000000000000;
        texts[400]=224'h00000000000000000000000ffccc0180600000000000000000000000;
        texts[401]=224'h00000000000000000000000ffccc0180600000000000000000000000;
        texts[402]=224'h00000000000000000000000c0ccc0300600000000000000000000000;
        texts[403]=224'h00000000000000000000000c0ccc0300400000000000000000000000;
        texts[404]=224'h00000000000000000000000ffccc0300400000000000000000000000;
        texts[405]=224'h00000000000000000000000ffccc0600400000000000000000000000;
        texts[406]=224'h00000000000000000000000c0c0c0600400000000000000000000000;
        texts[407]=224'h00000000000000000000000c0c0c0c00c00000000000000000000000;
        texts[408]=224'h00000000000000000000000c7c7c1c00c00000000000000000000000;
        texts[409]=224'h00000000000000000000000c7878383fc00000000000000000000000;
        texts[410]=224'h0000000000000000000000000000703f800000000000000000000000;
        texts[411]=224'h00000000000000000000000000002000000000000000000000000000;
        texts[412]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[413]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[414]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[415]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[416]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[417]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[418]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[419]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[420]=224'h00000000000000000000000000000010000000000000000000000000;
        texts[421]=224'h00000000000000000000000000000038000000000000000000000000;
        texts[422]=224'h0000000000000000000000000c000018000000000000000000000000;
        texts[423]=224'h0000000000000000000000001c000018000000000000000000000000;
        texts[424]=224'h00000000000000000000000018007ffff80000000000000000000000;
        texts[425]=224'h00000000000000000000003fffff7ffff80000000000000000000000;
        texts[426]=224'h00000000000000000000003fffff0180000000000000000000000000;
        texts[427]=224'h00000000000000000000000030000180000000000000000000000000;
        texts[428]=224'h00000000000000000000000060000180000000000000000000000000;
        texts[429]=224'h000000000000000000000000c0000180000000000000000000000000;
        texts[430]=224'h000000000000000000000000800001ffe00000000000000000000000;
        texts[431]=224'h000000000000000000000001fffc01ffe00000000000000000000000;
        texts[432]=224'h000000000000000000000003fffc0180600000000000000000000000;
        texts[433]=224'h000000000000000000000007800c0180600000000000000000000000;
        texts[434]=224'h00000000000000000000000f800c0300600000000000000000000000;
        texts[435]=224'h00000000000000000000001d800c0300400000000000000000000000;
        texts[436]=224'h000000000000000000000039800c0300400000000000000000000000;
        texts[437]=224'h000000000000000000000011800c0600400000000000000000000000;
        texts[438]=224'h000000000000000000000001800c0600400000000000000000000000;
        texts[439]=224'h000000000000000000000001800c0c00c00000000000000000000000;
        texts[440]=224'h000000000000000000000001fffc1c00c00000000000000000000000;
        texts[441]=224'h000000000000000000000001fffc383fc00000000000000000000000;
        texts[442]=224'h000000000000000000000001800c703f800000000000000000000000;
        texts[443]=224'h00000000000000000000000000002000000000000000000000000000;
        texts[444]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[445]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[446]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[447]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[448]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[449]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[450]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[451]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[452]=224'h00000000000000000000000000000010000000000000000000000000;
        texts[453]=224'h00000000000000000000000000000038000000000000000000000000;
        texts[454]=224'h00000000000000000000000000fc0018000000000000000000000000;
        texts[455]=224'h000000000000000000000007fffe0018000000000000000000000000;
        texts[456]=224'h000000000000000000000007ff807ffff80000000000000000000000;
        texts[457]=224'h00000000000000000000000600007ffff80000000000000000000000;
        texts[458]=224'h00000000000000000000000600000180000000000000000000000000;
        texts[459]=224'h00000000000000000000000600000180000000000000000000000000;
        texts[460]=224'h000000000000000000000007ffff0180000000000000000000000000;
        texts[461]=224'h000000000000000000000007ffff0180000000000000000000000000;
        texts[462]=224'h000000000000000000000006000001ffe00000000000000000000000;
        texts[463]=224'h000000000000000000000006000001ffe00000000000000000000000;
        texts[464]=224'h00000000000000000000000600000180600000000000000000000000;
        texts[465]=224'h0000000000000000000000067ffc0180600000000000000000000000;
        texts[466]=224'h0000000000000000000000067ffc0300600000000000000000000000;
        texts[467]=224'h000000000000000000000006600c0300400000000000000000000000;
        texts[468]=224'h00000000000000000000000e600c0300400000000000000000000000;
        texts[469]=224'h00000000000000000000000c600c0600400000000000000000000000;
        texts[470]=224'h00000000000000000000000c600c0600400000000000000000000000;
        texts[471]=224'h00000000000000000000001c600c0c00c00000000000000000000000;
        texts[472]=224'h0000000000000000000000187ffc1c00c00000000000000000000000;
        texts[473]=224'h0000000000000000000000307ffc383fc00000000000000000000000;
        texts[474]=224'h000000000000000000000010600c703f800000000000000000000000;
        texts[475]=224'h00000000000000000000000000002000000000000000000000000000;
        texts[476]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[477]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[478]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[479]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[480]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[481]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[482]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[483]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[484]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[485]=224'h00000000000000000180000000000010000000000000000000000000;
        texts[486]=224'h0000000000000000018001c00c000038001810000000000000000000;
        texts[487]=224'h00000000000000000ffefe000c00001c001838000000000000000000;
        texts[488]=224'h00000000000000000300c0000c003ffff8301c000000000000000000;
        texts[489]=224'h00000000000000000660c00ffffe3ffff83008000000000000000000;
        texts[490]=224'h00000000000000000660c00ffffe30001877fff00000000000000000;
        texts[491]=224'h000000000000000007fcffc00c0030001867fff00000000000000000;
        texts[492]=224'h00000000000000000060c6000c000000006000000000000000000000;
        texts[493]=224'h0000000000000000007c86000c007ffffce300c00000000000000000;
        texts[494]=224'h00000000000000000fe186000c007ffffce381c00000000000000000;
        texts[495]=224'h00000000000000000063063fffff001801e181800000000000000000;
        texts[496]=224'h00000000000000000002003fffff0618036181800000000000000000;
        texts[497]=224'h000000000000000001fffe001e0006180360c3000000000000000000;
        texts[498]=224'h0000000000000000018006003f00061ff260c3000000000000000000;
        texts[499]=224'h0000000000000000018006006d800c1ff060c3000000000000000000;
        texts[500]=224'h000000000000000001fffe01ccc00c18006066000000000000000000;
        texts[501]=224'h0000000000000000018006070c700e18006066000000000000000000;
        texts[502]=224'h00000000000000000180060e0c1c1b1800600c000000000000000000;
        texts[503]=224'h00000000000000000180063c0c0f19d800600c000000000000000000;
        texts[504]=224'h000000000000000001fffe100c0230fffc6ffff00000000000000000;
        texts[505]=224'h0000000000000000018006000c00603ffc6ffff00000000000000000;
        texts[506]=224'h0000000000000000000000000c002000006000000000000000000000;
        texts[507]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[508]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[509]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[510]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[511]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[512]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[513]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[514]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[515]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[516]=224'h00000000000000000001000000000000000000000000000000000000;
        texts[517]=224'h00000000000000000003800000000000000040000000000000000000;
        texts[518]=224'h000000000000000000018000180004060000e0000000000000000000;
        texts[519]=224'h00000000000000000001800018000e06000070000000000000000000;
        texts[520]=224'h000000000000000007ffff8030000c0600ffffe00000000000000000;
        texts[521]=224'h000000000000000007ffff80300018fff0ffffe00000000000000000;
        texts[522]=224'h00000000000000000018000ffffc30fff0c000600000000000000000;
        texts[523]=224'h00000000000000000018000ffffc600600c000600000000000000000;
        texts[524]=224'h00000000000000000018000c000cc406000000000000000000000000;
        texts[525]=224'h00000000000000000018000c000c8e0601fffff00000000000000000;
        texts[526]=224'h0000000000000000001ffe0cffcc0dfff9fffff00000000000000000;
        texts[527]=224'h0000000000000000001ffe0cffcc19fff80060000000000000000000;
        texts[528]=224'h00000000000000000018060cc0cc3800001860000000000000000000;
        texts[529]=224'h00000000000000000018060cc0cc7800c01860000000000000000000;
        texts[530]=224'h00000000000000000030060cc0cc79fff8187fc00000000000000000;
        texts[531]=224'h00000000000000000030040cc0ccd9fff8307fc00000000000000000;
        texts[532]=224'h00000000000000000030040cffcc9800c03060000000000000000000;
        texts[533]=224'h00000000000000000060040cffcc18c0c03860000000000000000000;
        texts[534]=224'h00000000000000000060040cc00c1860c06c60000000000000000000;
        texts[535]=224'h000000000000000000c00c0c000c1830c06760000000000000000000;
        texts[536]=224'h000000000000000001c00c0c000c1800c0c3fff00000000000000000;
        texts[537]=224'h00000000000000000383fc0c00fc181fc180fff00000000000000000;
        texts[538]=224'h00000000000000000703f80c00f8181f808000000000000000000000;
        texts[539]=224'h00000000000000000200000000000000000000000000000000000000;
        texts[540]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[541]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[542]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[543]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[544]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[545]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[546]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[547]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[548]=224'h00000000000000000000000000000000020000000000000000000000;
        texts[549]=224'h00000000000000000000000000000000070000000000000000000000;
        texts[550]=224'h00000000000000000000018000080800030000000000000000000000;
        texts[551]=224'h000000000000000000000180001c1c00030000000000000000000000;
        texts[552]=224'h0000000000000000000001800006300fffff00000000000000000000;
        texts[553]=224'h00000000000000000000fffffbffffefffff00000000000000000000;
        texts[554]=224'h00000000000000000000fffffbffffe0300000000000000000000000;
        texts[555]=224'h00000000000000000000030000000000300000000000000000000000;
        texts[556]=224'h00000000000000000000020001ff9980300000000000000000000000;
        texts[557]=224'h00000000000000000000060001ff9980300000000000000000000000;
        texts[558]=224'h000000000000000000000600018199803ffc00000000000000000000;
        texts[559]=224'h000000000000000000000ffff18199803ffc00000000000000000000;
        texts[560]=224'h000000000000000000000ffff1ff9980300c00000000000000000000;
        texts[561]=224'h00000000000000000000181801ff9980300c00000000000000000000;
        texts[562]=224'h00000000000000000000181801819980600c00000000000000000000;
        texts[563]=224'h00000000000000000000301801819980600800000000000000000000;
        texts[564]=224'h00000000000000000000701801ff9980600800000000000000000000;
        texts[565]=224'h00000000000000000000e01801ff9980c00800000000000000000000;
        texts[566]=224'h00000000000000000000c01801818180c00800000000000000000000;
        texts[567]=224'h00000000000000000001801801818181801800000000000000000000;
        texts[568]=224'h000000000000000000009ffff98f8f83801800000000000000000000;
        texts[569]=224'h000000000000000000001ffff98f0f0707f800000000000000000000;
        texts[570]=224'h0000000000000000000000000000000e07f000000000000000000000;
        texts[571]=224'h00000000000000000000000000000004000000000000000000000000;
        texts[572]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[573]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[574]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[575]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[576]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[577]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[578]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[579]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[580]=224'h00000000000000000000000000000000020000000000000000000000;
        texts[581]=224'h00000000000000000000000000000000070000000000000000000000;
        texts[582]=224'h00000000000000000000006000080800030000000000000000000000;
        texts[583]=224'h0000000000000000000000e0001c1c00030000000000000000000000;
        texts[584]=224'h0000000000000000000000c00006300fffff00000000000000000000;
        texts[585]=224'h00000000000000000001fffffbffffefffff00000000000000000000;
        texts[586]=224'h00000000000000000001fffffbffffe0300000000000000000000000;
        texts[587]=224'h00000000000000000000018000000000300000000000000000000000;
        texts[588]=224'h00000000000000000000030001ff9980300000000000000000000000;
        texts[589]=224'h00000000000000000000060001ff9980300000000000000000000000;
        texts[590]=224'h000000000000000000000400018199803ffc00000000000000000000;
        texts[591]=224'h000000000000000000000fffe18199803ffc00000000000000000000;
        texts[592]=224'h000000000000000000001fffe1ff9980300c00000000000000000000;
        texts[593]=224'h000000000000000000003c0061ff9980300c00000000000000000000;
        texts[594]=224'h000000000000000000007c0061819980600c00000000000000000000;
        texts[595]=224'h00000000000000000000ec0061819980600800000000000000000000;
        texts[596]=224'h00000000000000000001cc0061ff9980600800000000000000000000;
        texts[597]=224'h000000000000000000008c0061ff9980c00800000000000000000000;
        texts[598]=224'h000000000000000000000c0061818180c00800000000000000000000;
        texts[599]=224'h000000000000000000000c0061818181801800000000000000000000;
        texts[600]=224'h000000000000000000000fffe18f8f83801800000000000000000000;
        texts[601]=224'h000000000000000000000fffe18f0f0707f800000000000000000000;
        texts[602]=224'h000000000000000000000c006000000e07f000000000000000000000;
        texts[603]=224'h00000000000000000000000000000004000000000000000000000000;
        texts[604]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[605]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[606]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[607]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[608]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[609]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[610]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[611]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[612]=224'h00000000000000000000000000000000020000000000000000000000;
        texts[613]=224'h00000000000000000000000000000000070000000000000000000000;
        texts[614]=224'h00000000000000000000018000001f80030000000000000000000000;
        texts[615]=224'h00000000000000000000018000ffffc0030000000000000000000000;
        texts[616]=224'h00000000000000000000018000fff00fffff00000000000000000000;
        texts[617]=224'h00000000000000000000fffff8c0000fffff00000000000000000000;
        texts[618]=224'h00000000000000000000fffff8c00000300000000000000000000000;
        texts[619]=224'h00000000000000000000030000c00000300000000000000000000000;
        texts[620]=224'h00000000000000000000020000ffffe0300000000000000000000000;
        texts[621]=224'h00000000000000000000060000ffffe0300000000000000000000000;
        texts[622]=224'h00000000000000000000060000c000003ffc00000000000000000000;
        texts[623]=224'h000000000000000000000ffff0c000003ffc00000000000000000000;
        texts[624]=224'h000000000000000000000ffff0c00000300c00000000000000000000;
        texts[625]=224'h00000000000000000000181800cfff80300c00000000000000000000;
        texts[626]=224'h00000000000000000000181800cfff80600c00000000000000000000;
        texts[627]=224'h00000000000000000000301800cc0180600800000000000000000000;
        texts[628]=224'h00000000000000000000701801cc0180600800000000000000000000;
        texts[629]=224'h00000000000000000000e018018c0180c00800000000000000000000;
        texts[630]=224'h00000000000000000000c018018c0180c00800000000000000000000;
        texts[631]=224'h000000000000000000018018038c0181801800000000000000000000;
        texts[632]=224'h000000000000000000009ffffb0fff83801800000000000000000000;
        texts[633]=224'h000000000000000000001ffffe0fff8707f800000000000000000000;
        texts[634]=224'h000000000000000000000000020c018e07f000000000000000000000;
        texts[635]=224'h00000000000000000000000000000004000000000000000000000000;
        texts[636]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[637]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[638]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[639]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[640]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[641]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[642]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[643]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[644]=224'h00000000000000000000000000000000020000000000000000000000;
        texts[645]=224'h00000000000000000000000000000000070000000000000000000000;
        texts[646]=224'h00000000000000000000006000001f80030000000000000000000000;
        texts[647]=224'h0000000000000000000000e000ffffc0030000000000000000000000;
        texts[648]=224'h0000000000000000000000c000fff00fffff00000000000000000000;
        texts[649]=224'h00000000000000000001fffff8c0000fffff00000000000000000000;
        texts[650]=224'h00000000000000000001fffff8c00000300000000000000000000000;
        texts[651]=224'h00000000000000000000018000c00000300000000000000000000000;
        texts[652]=224'h00000000000000000000030000ffffe0300000000000000000000000;
        texts[653]=224'h00000000000000000000060000ffffe0300000000000000000000000;
        texts[654]=224'h00000000000000000000040000c000003ffc00000000000000000000;
        texts[655]=224'h000000000000000000000fffe0c000003ffc00000000000000000000;
        texts[656]=224'h000000000000000000001fffe0c00000300c00000000000000000000;
        texts[657]=224'h000000000000000000003c0060cfff80300c00000000000000000000;
        texts[658]=224'h000000000000000000007c0060cfff80600c00000000000000000000;
        texts[659]=224'h00000000000000000000ec0060cc0180600800000000000000000000;
        texts[660]=224'h00000000000000000001cc0061cc0180600800000000000000000000;
        texts[661]=224'h000000000000000000008c00618c0180c00800000000000000000000;
        texts[662]=224'h000000000000000000000c00618c0180c00800000000000000000000;
        texts[663]=224'h000000000000000000000c00638c0181801800000000000000000000;
        texts[664]=224'h000000000000000000000fffe30fff83801800000000000000000000;
        texts[665]=224'h000000000000000000000fffe60fff8707f800000000000000000000;
        texts[666]=224'h000000000000000000000c00620c018e07f000000000000000000000;
        texts[667]=224'h00000000000000000000000000000004000000000000000000000000;
        texts[668]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[669]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[670]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[671]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[672]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[673]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[674]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[675]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[676]=224'h00000000000000000000000000000000000040000000000000000000;
        texts[677]=224'h000000000000600000000000000000000000e0000000000000000000;
        texts[678]=224'h00000000000060007000000000000c00000060006040000000000000;
        texts[679]=224'h000000000003ffbf81ffff07fff80c3ff800600060e0000000000000;
        texts[680]=224'h000000000000c03001ffff07fff80c3ff9ffffe0c070000000000000;
        texts[681]=224'h00000000000198300003000600180c0001ffffe0c020000000000000;
        texts[682]=224'h00000000000198300003000600187f8000060001dfffc00000000000;
        texts[683]=224'h000000000001ff3ff003000600187f80000600019fffc00000000000;
        texts[684]=224'h000000000000183180030007fff80c00000600018000000000000000;
        texts[685]=224'h0000000000001f2180060007fff80c7ffc0600038c03000000000000;
        texts[686]=224'h000000000003f86187ffffc600181e7ffc07ff838e07000000000000;
        texts[687]=224'h00000000000018c187ffffc600181f030007ff878606000000000000;
        texts[688]=224'h00000000000000800006000600181d830006018d8606000000000000;
        texts[689]=224'h0000000000007fff800e000600182cb32006018d830c000000000000;
        texts[690]=224'h0000000000006001800cc007fff82c73700c0189830c000000000000;
        texts[691]=224'h0000000000006001801cc007fff86c63300c0101830c000000000000;
        texts[692]=224'h0000000000007fff8018c0c600184c63300c01018198000000000000;
        texts[693]=224'h00000000000060018038c0c600180ce3181801018198000000000000;
        texts[694]=224'h00000000000060018070c0c600180cc3181801018030000000000000;
        texts[695]=224'h000000000000600180e0c0c600180dc31c3003018030000000000000;
        texts[696]=224'h0000000000007fff83c0ff87fff80c8308700301bfffc00000000000;
        texts[697]=224'h000000000000600187807f87fff80c1f00e0ff01bfffc00000000000;
        texts[698]=224'h00000000000000000200000600180c1e01c0fe018000000000000000;
        texts[699]=224'h00000000000000000000000600180000008000000000000000000000;
        texts[700]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[701]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[702]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[703]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[704]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[705]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[706]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[707]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[708]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[709]=224'h0000000000000000000c000000000230000000000200000000000000;
        texts[710]=224'h0000000000000000000c000000fc07180000c0000700000000000000;
        texts[711]=224'h000000000000ffffe00c001ffffc061c0000c0000300000000000000;
        texts[712]=224'h000000000000ffffe3ffffcffe000ffffbffffe7ffff800000000000;
        texts[713]=224'h000000000000006003ffffc010081c1803ffffe7ffff800000000000;
        texts[714]=224'h000000000000006000180008381c1c180000c0002020000000000000;
        texts[715]=224'h00000000000000600030600c1c383ffff000c0007030000000000000;
        texts[716]=224'h0000000000003060003060060e606c1800ffffc03060000000000000;
        texts[717]=224'h00000000000030600060600704c00ffff0ffffcfffffc00000000000;
        texts[718]=224'h0000000000003060006060020c800c180000000fffffc00000000000;
        texts[719]=224'h000000000000307fc0c060000c000c18007fff800000000000000000;
        texts[720]=224'h000000000000307fc1cfffbffffe0ffff87fff81fffe000000000000;
        texts[721]=224'h000000000000306003cfffbffffe0c000060c181fffe000000000000;
        texts[722]=224'h000000000000306003c060003f0000300060c1818006000000000000;
        texts[723]=224'h000000000000306006c060006d800030007fff818006000000000000;
        texts[724]=224'h000000000000306004c06000ccc03ffff87fff81fffe000000000000;
        texts[725]=224'h000000000000306000c060038c6000fc00600181fffe000000000000;
        texts[726]=224'h000000000000306000c0600f0c3c01b600c000018006000000000000;
        texts[727]=224'h000000000000306000c0603c0c1f033380c000018006000000000000;
        texts[728]=224'h000000000001fffff0dfffd00c060c30f1800001fffe000000000000;
        texts[729]=224'h000000000001fffff0dfffc00c0018303f800001fffe000000000000;
        texts[730]=224'h000000000000000000c000000c006030090000018006000000000000;
        texts[731]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[732]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[733]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[734]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[735]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[736]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[737]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[738]=224'h00000000000000000f00030000000007000001c00000000000000000;
        texts[739]=224'h00000000000000000f00078ffffe001f000003e00000000000000000;
        texts[740]=224'h000000000000007fffffe3cffffe000f800003c00000000000000000;
        texts[741]=224'h000000000000007fffffe1effffe000f800003c00000000000000000;
        texts[742]=224'h000000000000007fffffe0ef07007fffffe3fffffc00000000000000;
        texts[743]=224'h00000000000000000f00004f0f007fffffe3fffffc00000000000000;
        texts[744]=224'h00000000000000000f00000f7ffc7fffffe3fffffc00000000000000;
        texts[745]=224'h000000000000001fffff820f7ffc01e00003c0003c00000000000000;
        texts[746]=224'h000000000000001fffff878f7ffc01e00003c0003c00000000000000;
        texts[747]=224'h000000000000001fffff87cf781c01e00003c0003c00000000000000;
        texts[748]=224'h0000000000000000000003ef781c01e00003cfff3c00000000000000;
        texts[749]=224'h0000000000000000000001cf7ffc01ffff03cfff3c00000000000000;
        texts[750]=224'h000000000000001fffff808f7ffc01ffff03cfff3c00000000000000;
        texts[751]=224'h000000000000001fffff800f781c01ffff03cf0f3c00000000000000;
        texts[752]=224'h000000000000001fffff800f781c01e00f03cf0f3c00000000000000;
        texts[753]=224'h000000000000001e0f07818f7ffc01e00f03cf0f3c00000000000000;
        texts[754]=224'h000000000000001e0f0781ee7ffc03e00f03cf0f3c00000000000000;
        texts[755]=224'h000000000000001e0f0781ee7ffc03c00f03cf0f3c00000000000000;
        texts[756]=224'h000000000000001fffff81ce03c003c00f03cfff3c00000000000000;
        texts[757]=224'h000000000000001fffff83de23d807c00f03cfff3c00000000000000;
        texts[758]=224'h000000000000001fffff83de7bf80f801f03cfff3c00000000000000;
        texts[759]=224'h000000000000003c000783de7bfc0f801e03cf003c00000000000000;
        texts[760]=224'h000000000000003c0000039ef3de1f001e03cf003c00000000000000;
        texts[761]=224'h000000000000007c000007bde3ce7e0ffe03c0007c00000000000000;
        texts[762]=224'h00000000000000f8000007bddf8f7c07fc03c01ffc00000000000000;
        texts[763]=224'h0000000000000070000007989f843807f803c01ff800000000000000;
        texts[764]=224'h0000000000000020000001081f0010000003c00ff000000000000000;
        texts[765]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[766]=224'h00000000000000000000000000000000000000000000000000000000;
        texts[767]=224'h00000000000000000000000000000000000000000000000000000000;
    end
    always @(posedge clk) begin
        icon_row<=icons[icon_addr]; icon_x_q<=icon_x;
        text_row<=texts[text_addr]; text_x_q<=text_x;
    end
    assign icon_index=icon_row[383-icon_x_q*4 -: 4];
    assign text_on=text_row[223-text_x_q];
endmodule
