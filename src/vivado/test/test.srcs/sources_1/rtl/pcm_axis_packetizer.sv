// Unique module name prevents binding the old one-shot packetizer by mistake.
// CONTINUOUS four-mic packetizer. capture_arm is now an ENABLE LEVEL.
// It must remain high across DMA packets. No audio is intentionally discarded
// between packets. Sticky overflow is fatal and must not be ignored.
module pcm_axis_stream_packetizer #(
    parameter integer CHANNELS=4,
    parameter integer CLIP_FRAMES=12208,
    parameter integer FIFO_DEPTH=4096
)(
    input wire aclk, input wire aresetn, input wire capture_arm,
    input wire frame_valid,
    input wire [CHANNELS*24-1:0] frame_pcm,
    output wire [31:0] m_axis_tdata,
    output wire [3:0] m_axis_tkeep,
    output wire m_axis_tvalid, input wire m_axis_tready,
    output wire m_axis_tlast,
    output wire busy, output reg done, output reg overflow
);
    localparam integer PW=$clog2(FIFO_DEPTH);
    localparam integer CW=$clog2(CHANNELS+1);
    (* ram_style="block" *) reg [CHANNELS*24-1:0] fifo[0:FIFO_DEPTH-1];
    reg [PW-1:0] wr,rd;
    reg [PW:0] count;
    reg [CHANNELS*24-1:0] current_frame;
    reg have_frame;
    reg [CW-1:0] channel_index;
    reg [31:0] packet_frame;
    wire transfer=m_axis_tvalid && m_axis_tready;
    wire end_frame=transfer && channel_index==CHANNELS-1;
    wire load_frame=capture_arm && count!=0 && (!have_frame || end_frame);
    wire wants_push=capture_arm && !overflow && frame_valid;
    wire push_frame=wants_push && (count<FIFO_DEPTH || load_frame);
    wire [23:0] word24=current_frame[channel_index*24 +: 24];
    assign busy=capture_arm && !overflow;
    assign m_axis_tvalid=capture_arm && have_frame;
    assign m_axis_tdata={{8{word24[23]}},word24};
    assign m_axis_tkeep=4'hf;
    assign m_axis_tlast=m_axis_tvalid && channel_index==CHANNELS-1 && packet_frame==CLIP_FRAMES-1;

    always @(posedge aclk) begin
        if(!aresetn || !capture_arm) begin
            wr<=0;rd<=0;count<=0;current_frame<=0;have_frame<=0;
            channel_index<=0;packet_frame<=0;done<=0;overflow<=0;
        end else begin
            done<=0;
            if(wants_push && !push_frame) overflow<=1;
            if(push_frame) begin fifo[wr]<=frame_pcm;wr<=wr+1'b1;end
            // Registered synchronous read permits block-RAM implementation.
            if(load_frame) begin current_frame<=fifo[rd];rd<=rd+1'b1;end
            case({push_frame,load_frame})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:count<=count;
            endcase
            if(load_frame) begin have_frame<=1;channel_index<=0;end
            else if(end_frame) begin have_frame<=0;channel_index<=0;end
            else if(transfer) channel_index<=channel_index+1'b1;
            if(end_frame) begin
                if(packet_frame==CLIP_FRAMES-1) begin packet_frame<=0;done<=1;end
                else packet_frame<=packet_frame+1'b1;
            end
        end
    end
endmodule
