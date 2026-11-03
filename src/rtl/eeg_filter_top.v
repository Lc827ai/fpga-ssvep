`timescale 1ns / 1ps

module eeg_filter_top (
    input  wire        aclk,
    input  wire        aresetn,
    
    // 总输入 (连接 AXI DMA 的 M_AXIS)
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    
    // 总输出 (连接后续 FBCCA 或 DMA 的 S_AXIS)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // 内部连线：用于连接 Stage1 的输出和 Stage2 的输入
    wire [31:0] mid_tdata;
    wire        mid_tvalid;
    wire        mid_tready;
    wire        mid_tlast;

    // 实例化 Stage 1 (注入 Python 算出的第一组 Biquad 系数)
    eeg_iir_biquad_tdm_7ch #(
        .B0_SEC ( 32'sd644609 ),
        .B1_SEC ( 32'sd1289218 ),
        .B2_SEC ( 32'sd644609 ),
        .A1_SEC ( -32'sd23476336 ),
        .A2_SEC ( 32'sd9476315 )
    ) biquad_stage1 (
        .aclk         (aclk),
        .aresetn      (aresetn),
        .s_axis_tdata (s_axis_tdata),    
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast (s_axis_tlast),
        .m_axis_tdata (mid_tdata),       
        .m_axis_tvalid(mid_tvalid),
        .m_axis_tready(mid_tready),
        .m_axis_tlast (mid_tlast)
    );

    // 实例化 Stage 2 (注入 Python 算出的第二组 Biquad 系数)
    eeg_iir_biquad_tdm_7ch #(
        .B0_SEC ( 32'sd16777216 ),
        .B1_SEC ( -32'sd33554432 ),
        .B2_SEC ( 32'sd16777216 ),
        .A1_SEC ( -32'sd32405534 ),
        .A2_SEC ( 32'sd15676701 )
    ) biquad_stage2 (
        .aclk         (aclk),
        .aresetn      (aresetn),
        .s_axis_tdata (mid_tdata),       
        .s_axis_tvalid(mid_tvalid),
        .s_axis_tready(mid_tready),
        .s_axis_tlast (mid_tlast),
        .m_axis_tdata (m_axis_tdata),    
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast (m_axis_tlast)
    );

endmodule