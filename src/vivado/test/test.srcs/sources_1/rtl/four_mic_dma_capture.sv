// One clock domain: AX7021 clk_50m from Y9, including ALL AXI peripherals.
// frame_pcm order (LSB first): FRONT, LEFT, RIGHT, BACK.
module four_mic_dma_capture #(
    parameter integer CLIP_FRAMES=12208,
    parameter integer FIFO_DEPTH=4096
)(
    input wire aclk,
    input wire aresetn,
    input wire [31:0] ps_control,
    input wire frame_valid,
    input wire [95:0] frame_pcm,
    input wire [3:0] direction,
    input wire direction_valid,
    output wire [31:0] pl_status,
    output wire [31:0] m_axis_tdata,
    output wire [3:0] m_axis_tkeep,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire m_axis_tlast
);
    wire busy,done,overflow;
    reg done_d,arm_d;
    reg [3:0] direction_snapshot;
    reg valid_snapshot;
    pcm_axis_stream_packetizer #(.CHANNELS(4),.CLIP_FRAMES(CLIP_FRAMES),
                         .FIFO_DEPTH(FIFO_DEPTH)) u_packetizer (
        .aclk(aclk),.aresetn(aresetn),.capture_arm(ps_control[0]),
        .frame_valid(frame_valid),.frame_pcm(frame_pcm),
        .m_axis_tdata(m_axis_tdata),.m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid),.m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),.busy(busy),.done(done),.overflow(overflow));
    always @(posedge aclk) begin
        if(!aresetn) begin
            done_d<=0;arm_d<=0;direction_snapshot<=4;valid_snapshot<=0;
        end else begin
            done_d<=done;arm_d<=ps_control[0];
            if(ps_control[0] && !arm_d) valid_snapshot<=0;
            if(done && !done_d) begin
                direction_snapshot<=direction;
                valid_snapshot<=direction_valid && (direction!=4) && (direction!=5);
            end
        end
    end
    // bits31:16 packet frames, bits15:9 build tag=0x35, bit8 validity, bits7:4 DOA, bit3 STREAM signature,
    // bit2 overflow, bit1 done, bit0 busy. Never truncate diagonal codes.
    localparam [15:0] PACKET_ID=CLIP_FRAMES;
    assign pl_status={PACKET_ID,7'h36,valid_snapshot,direction_snapshot,1'b1,overflow,done_d,busy};
endmodule
