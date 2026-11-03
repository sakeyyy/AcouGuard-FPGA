`timescale 1ns/1ps
module packet_case #(
    parameter integer FRAMES=17,
    parameter integer PACKETS=3,
    parameter integer DEPTH=8,
    parameter integer CHECK_OVERFLOW=1
)(output reg complete=0);
    reg clk=0;
    always #10 clk=~clk;
    reg resetn=0, arm=0, frame_valid=0, ready=0;
    reg [95:0] pcm=0;
    wire [31:0] data;
    wire [3:0] keep;
    wire valid,last,busy,done,overflow;
    integer received=0, packet_count=0, cycle=0;
    integer frame_number, channel_number;
    integer trace_file=0;
    reg checking=1, random_ready=1;
    reg [31:0] lfsr=32'h1234abcd;
    reg held=0, held_last=0;
    reg [31:0] held_data=0;
    pcm_axis_stream_packetizer #(.CHANNELS(4),.CLIP_FRAMES(FRAMES),.FIFO_DEPTH(DEPTH))
        dut(.aclk(clk),.aresetn(resetn),.capture_arm(arm),
            .frame_valid(frame_valid),.frame_pcm(pcm),
            .m_axis_tdata(data),.m_axis_tkeep(keep),.m_axis_tvalid(valid),
            .m_axis_tready(ready),.m_axis_tlast(last),
            .busy(busy),.done(done),.overflow(overflow));

    function automatic signed [31:0] sample_value(input integer frame_id, input integer channel_id);
        integer magnitude;
        begin
            magnitude=frame_id*4+channel_id+1;
            sample_value=((frame_id+channel_id)%2) ? -magnitude : magnitude;
            if(frame_id==0 && channel_id==0) sample_value=-8388608;
            if(frame_id==0 && channel_id==1) sample_value=8388607;
        end
    endfunction

    always @(negedge clk) begin
        lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        if(random_ready) ready=lfsr[0] | lfsr[2];
    end

    always @(posedge clk) begin
        cycle=cycle+1;
        if(trace_file && cycle<500)
            $fdisplay(trace_file,"%0d,%0d,%0d,%h,%0d,%0d,%0d",cycle,valid,ready,data,last,done,overflow);
        if(resetn && arm && checking) begin
            if(overflow) $fatal(1,"Unexpected overflow FRAMES=%0d",FRAMES);
            if(held && (!valid || data!==held_data || last!==held_last))
                $fatal(1,"Unstable AXIS under backpressure");
            held=valid && !ready;
            held_data=data;
            held_last=last;
            if(done) packet_count=packet_count+1;
            if(valid && ready) begin
                if(keep!==4'hf) $fatal(1,"Wrong TKEEP");
                if(data!==sample_value(received/4,received%4))
                    $fatal(1,"PCM/order/sign mismatch word=%0d got=%h expected=%h",
                           received,data,sample_value(received/4,received%4));
                if(last!==((received%(FRAMES*4))==FRAMES*4-1))
                    $fatal(1,"TLAST mismatch word=%0d",received);
                received=received+1;
            end
        end else held=0;
    end

    initial begin
        if(CHECK_OVERFLOW) begin
            trace_file=$fopen("packetizer_trace.csv","w");
            $fdisplay(trace_file,"cycle,valid,ready,data_hex,last,done,overflow");
        end
        repeat(4) @(negedge clk);
        resetn=1;arm=1;
        for(frame_number=0;frame_number<FRAMES*PACKETS;frame_number=frame_number+1) begin
            @(negedge clk);
            for(channel_number=0;channel_number<4;channel_number=channel_number+1)
                pcm[channel_number*24 +: 24]=sample_value(frame_number,channel_number);
            frame_valid=1;
            @(negedge clk);
            frame_valid=0;
            repeat(15) @(negedge clk);
        end
        wait(received==FRAMES*PACKETS*4);
        repeat(4) @(negedge clk);
        if(packet_count!=PACKETS) $fatal(1,"done pulse count mismatch");
        checking=0;arm=0;
        repeat(3) @(negedge clk);
        if(overflow || busy || valid) $fatal(1,"Disarm did not clear state");
        if(CHECK_OVERFLOW) begin
            random_ready=0;ready=0;arm=1;
            repeat(DEPTH+5) begin
                @(negedge clk);frame_valid=1;
            end
            @(negedge clk);frame_valid=0;
            if(!overflow || busy) $fatal(1,"Missing overflow/busy indication");
            repeat(8) @(negedge clk);
            if(!overflow) $fatal(1,"Overflow must remain sticky");
            arm=0;
            repeat(2) @(negedge clk);
            if(overflow || valid) $fatal(1,"Overflow did not clear on disarm");
            arm=1;resetn=0;
            repeat(2) @(negedge clk);
            resetn=1;
            repeat(2) @(negedge clk);
            if(overflow || valid) $fatal(1,"Reset did not clear state");
        end
        $display("CASE_PASS frames=%0d packets=%0d words=%0d cycles=%0d overflow_case=%0d",
                 FRAMES,PACKETS,received,cycle,CHECK_OVERFLOW);
        complete=1;
        if(trace_file)$fclose(trace_file);
    end
endmodule

module tb_packetizer;
    wire small_complete,production_complete;
    packet_case small_case(small_complete);
    packet_case #(.FRAMES(12208),.PACKETS(2),.DEPTH(4096),.CHECK_OVERFLOW(0))
        production_case(production_complete);
    initial begin
        wait(small_complete && production_complete);
        $display("PACKETIZER_REGRESSION_PASS");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"Testbench watchdog");
    end
endmodule
