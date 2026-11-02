`timescale 1ns / 1ps

module eeg_iir_biquad_tdm_7ch #(
    parameter DATA_WIDTH = 32,
    parameter COEF_WIDTH = 32,
    parameter FRAC_BITS  = 24,
    // 默认对外开放的系数参数 (外部调用时可被覆盖)
    parameter signed [COEF_WIDTH-1:0] B0_SEC = 32'sd0,
    parameter signed [COEF_WIDTH-1:0] B1_SEC = 32'sd0,
    parameter signed [COEF_WIDTH-1:0] B2_SEC = 32'sd0,
    parameter signed [COEF_WIDTH-1:0] A1_SEC = 32'sd0,
    parameter signed [COEF_WIDTH-1:0] A2_SEC = 32'sd0
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    // AXI-Stream Slave 接口
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire                  s_axis_tlast,
    
    // AXI-Stream Master 接口
    output reg  [DATA_WIDTH-1:0] m_axis_tdata,
    output reg                   m_axis_tvalid,
    input  wire                  m_axis_tready,
    output reg                   m_axis_tlast
);

    // 7 通道历史寄存器堆 (深度 0~6)
    reg signed [DATA_WIDTH-1:0] x_hist_1 [0:6];
    reg signed [DATA_WIDTH-1:0] x_hist_2 [0:6];
    reg signed [DATA_WIDTH-1:0] y_hist_1 [0:6];
    reg signed [DATA_WIDTH-1:0] y_hist_2 [0:6];

    reg [2:0] ch_ptr; // 0~6
    
    localparam IDLE    = 3'd0,
               MAC_B0  = 3'd1,
               MAC_B1  = 3'd2,
               MAC_B2  = 3'd3,
               MAC_A1  = 3'd4,
               MAC_A2  = 3'd5,
               SHIFT_O = 3'd6;

    reg [2:0] state;
    reg signed [63:0] accumulator; 
    reg signed [DATA_WIDTH-1:0] current_x;

    assign s_axis_tready = (state == IDLE) && m_axis_tready;

    integer i;
    
    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= IDLE;
            ch_ptr <= 3'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
            for(i=0; i<7; i=i+1) begin
                x_hist_1[i] <= 0; x_hist_2[i] <= 0;
                y_hist_1[i] <= 0; y_hist_2[i] <= 0;
            end
        end else begin
            case (state)
                IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        current_x <= s_axis_tdata;
                        m_axis_tlast <= s_axis_tlast;
                        
                        // 强制通道同步校准
                        if (s_axis_tlast) ch_ptr <= 3'd6; 
                        
                        accumulator <= 0;
                        state <= MAC_B0;
                    end
                end

                MAC_B0: begin
                    accumulator <= accumulator + (current_x * B0_SEC);
                    state <= MAC_B1;
                end

                MAC_B1: begin
                    accumulator <= accumulator + (x_hist_1[ch_ptr] * B1_SEC);
                    state <= MAC_B2;
                end

                MAC_B2: begin
                    accumulator <= accumulator + (x_hist_2[ch_ptr] * B2_SEC);
                    state <= MAC_A1;
                end

                MAC_A1: begin
                    accumulator <= accumulator - (y_hist_1[ch_ptr] * A1_SEC);
                    state <= MAC_A2;
                end

                MAC_A2: begin
                    accumulator <= accumulator - (y_hist_2[ch_ptr] * A2_SEC);
                    state <= SHIFT_O;
                end

SHIFT_O: begin
                    // ? 终极修复：加入 2^23 (64'sd8388608) 实现对称的四舍五入
                    // 彻底消除右移操作带来的向下取整直流偏置
                    m_axis_tdata <= (accumulator + 64'sd8388608) >>> FRAC_BITS; 
                    m_axis_tvalid <= 1'b1;
                    
                    x_hist_2[ch_ptr] <= x_hist_1[ch_ptr];
                    x_hist_1[ch_ptr] <= current_x;
                    y_hist_2[ch_ptr] <= y_hist_1[ch_ptr];
                    // 历史反馈寄存器同样必须四舍五入，切断误差放大的循环
                    y_hist_1[ch_ptr] <= (accumulator + 64'sd8388608) >>> FRAC_BITS;

                    if (ch_ptr == 3'd6) 
                        ch_ptr <= 3'd0;
                    else 
                        ch_ptr <= ch_ptr + 1;

                    state <= IDLE;
                end
            endcase
        end
    end
endmodule