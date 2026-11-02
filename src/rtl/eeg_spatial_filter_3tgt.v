`timescale 1ns / 1ps

module eeg_spatial_filter_3tgt #(
    parameter DATA_WIDTH = 32,
    parameter FRAC_BITS  = 24, 
    
    // AXI-Lite 参数设置
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 7 // 7位地址线支持 128 Bytes，足够容纳 21 个 32位寄存器(84 Bytes)
)(
    input  wire                              aclk,
    input  wire                              aresetn,

    // ==========================================
    // 1. AXI4-Lite 从机接口 (用于 PS 端动态配置权重 W)
    // ==========================================
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]   s_axi_awaddr,
    input  wire                              s_axi_awvalid,
    output wire                              s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1 : 0]   s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,
    output wire [1:0]                        s_axi_bresp,
    output wire                              s_axi_bvalid,
    input  wire                              s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]   s_axi_araddr,
    input  wire                              s_axi_arvalid,
    output wire                              s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1 : 0]   s_axi_rdata,
    output wire [1:0]                        s_axi_rresp,
    output wire                              s_axi_rvalid,
    input  wire                              s_axi_rready,

    // ==========================================
    // 2. AXI-Stream 接口 (数据流输入输出)
    // ==========================================
    input  wire [DATA_WIDTH-1:0]             s_axis_tdata,
    input  wire                              s_axis_tvalid,
    output wire                              s_axis_tready,
    input  wire                              s_axis_tlast,
    
    output reg  [DATA_WIDTH-1:0]             m_axis_tdata,
    output reg                               m_axis_tvalid,
    input  wire                              m_axis_tready,
    output reg                               m_axis_tlast
);

    // =========================================================================
    // AXI-Lite 寄存器定义 (21 个权重)
    // =========================================================================
    reg signed [31:0] reg_w_t1_c0, reg_w_t1_c1, reg_w_t1_c2, reg_w_t1_c3, reg_w_t1_c4, reg_w_t1_c5, reg_w_t1_c6;
    reg signed [31:0] reg_w_t2_c0, reg_w_t2_c1, reg_w_t2_c2, reg_w_t2_c3, reg_w_t2_c4, reg_w_t2_c5, reg_w_t2_c6;
    reg signed [31:0] reg_w_t3_c0, reg_w_t3_c1, reg_w_t3_c2, reg_w_t3_c3, reg_w_t3_c4, reg_w_t3_c5, reg_w_t3_c6;

    // AXI-Lite 写握手控制信号
    reg axi_awready;
    reg axi_wready;
    reg axi_bvalid;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = 2'b00; // OKAY response
    assign s_axi_bvalid  = axi_bvalid;
    
    // AXI-Lite 写地址锁存
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_en_addr;
    wire slv_reg_wren = axi_wready && s_axi_wvalid && axi_awready && s_axi_awvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
        end else begin
            if (~axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                axi_awready <= 1'b1;
                aw_en_addr  <= s_axi_awaddr;
            end else axi_awready <= 1'b0;
            
            if (~axi_wready && s_axi_wvalid && s_axi_awvalid) begin
                axi_wready <= 1'b1;
            end else axi_wready <= 1'b0;
            
            if (axi_awready && s_axi_awvalid && ~axi_bvalid && axi_wready && s_axi_wvalid) begin
                axi_bvalid <= 1'b1;
            end else if (s_axi_bready && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // AXI-Lite 寄存器写入逻辑 (根据地址偏移量写入对应通道权重)
    always @(posedge aclk) begin
        if (!aresetn) begin
            // 复位时默认权重设为0
            reg_w_t1_c0 <= 0; reg_w_t1_c1 <= 0; reg_w_t1_c2 <= 0; reg_w_t1_c3 <= 0; reg_w_t1_c4 <= 0; reg_w_t1_c5 <= 0; reg_w_t1_c6 <= 0;
            reg_w_t2_c0 <= 0; reg_w_t2_c1 <= 0; reg_w_t2_c2 <= 0; reg_w_t2_c3 <= 0; reg_w_t2_c4 <= 0; reg_w_t2_c5 <= 0; reg_w_t2_c6 <= 0;
            reg_w_t3_c0 <= 0; reg_w_t3_c1 <= 0; reg_w_t3_c2 <= 0; reg_w_t3_c3 <= 0; reg_w_t3_c4 <= 0; reg_w_t3_c5 <= 0; reg_w_t3_c6 <= 0;
        end else if (slv_reg_wren) begin
            case (aw_en_addr[6:2]) // 忽略低2位(字节对齐)
                // Target 1
                5'h00: reg_w_t1_c0 <= s_axi_wdata;
                5'h01: reg_w_t1_c1 <= s_axi_wdata;
                5'h02: reg_w_t1_c2 <= s_axi_wdata;
                5'h03: reg_w_t1_c3 <= s_axi_wdata;
                5'h04: reg_w_t1_c4 <= s_axi_wdata;
                5'h05: reg_w_t1_c5 <= s_axi_wdata;
                5'h06: reg_w_t1_c6 <= s_axi_wdata;
                // Target 2
                5'h07: reg_w_t2_c0 <= s_axi_wdata;
                5'h08: reg_w_t2_c1 <= s_axi_wdata;
                5'h09: reg_w_t2_c2 <= s_axi_wdata;
                5'h0A: reg_w_t2_c3 <= s_axi_wdata;
                5'h0B: reg_w_t2_c4 <= s_axi_wdata;
                5'h0C: reg_w_t2_c5 <= s_axi_wdata;
                5'h0D: reg_w_t2_c6 <= s_axi_wdata;
                // Target 3
                5'h0E: reg_w_t3_c0 <= s_axi_wdata;
                5'h0F: reg_w_t3_c1 <= s_axi_wdata;
                5'h10: reg_w_t3_c2 <= s_axi_wdata;
                5'h11: reg_w_t3_c3 <= s_axi_wdata;
                5'h12: reg_w_t3_c4 <= s_axi_wdata;
                5'h13: reg_w_t3_c5 <= s_axi_wdata;
                5'h14: reg_w_t3_c6 <= s_axi_wdata;
                default: ;
            endcase
        end
    end

    // 读逻辑简略处理 (仅写入为主，返回0避免总线挂死)
    assign s_axi_arready = 1'b1;
    assign s_axi_rvalid  = s_axi_arvalid;
    assign s_axi_rdata   = 32'd0;
    assign s_axi_rresp   = 2'b00;

    // =========================================================================
    // AXI-Stream 数据处理逻辑 (核心乘加状态机)
    // =========================================================================
    localparam IDLE      = 2'd0;
    localparam MAC_CALC  = 2'd1; 
    localparam SEND_OUT  = 2'd2; 

    reg [1:0] state;
    reg [2:0] ch_in_ptr;  
    reg [1:0] tgt_out_ptr; 
    reg last_flag; // TLAST 透传寄存器

    reg signed [63:0] acc_tgt1;
    reg signed [63:0] acc_tgt2;
    reg signed [63:0] acc_tgt3;

    assign s_axis_tready = (state == IDLE) || (state == MAC_CALC);

    // 根据当前输入通道，动态选择从 AXI-Lite 寄存器中取出的权重
    reg signed [31:0] w_t1_mux, w_t2_mux, w_t3_mux;
    always @(*) begin
        case(ch_in_ptr)
            3'd0: begin w_t1_mux = reg_w_t1_c0; w_t2_mux = reg_w_t2_c0; w_t3_mux = reg_w_t3_c0; end
            3'd1: begin w_t1_mux = reg_w_t1_c1; w_t2_mux = reg_w_t2_c1; w_t3_mux = reg_w_t3_c1; end
            3'd2: begin w_t1_mux = reg_w_t1_c2; w_t2_mux = reg_w_t2_c2; w_t3_mux = reg_w_t3_c2; end
            3'd3: begin w_t1_mux = reg_w_t1_c3; w_t2_mux = reg_w_t2_c3; w_t3_mux = reg_w_t3_c3; end
            3'd4: begin w_t1_mux = reg_w_t1_c4; w_t2_mux = reg_w_t2_c4; w_t3_mux = reg_w_t3_c4; end
            3'd5: begin w_t1_mux = reg_w_t1_c5; w_t2_mux = reg_w_t2_c5; w_t3_mux = reg_w_t3_c5; end
            3'd6: begin w_t1_mux = reg_w_t1_c6; w_t2_mux = reg_w_t2_c6; w_t3_mux = reg_w_t3_c6; end
            default: begin w_t1_mux = 0; w_t2_mux = 0; w_t3_mux = 0; end
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= IDLE;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
            ch_in_ptr <= 3'd0;
            tgt_out_ptr <= 2'd0;
            last_flag <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        acc_tgt1 <= $signed(s_axis_tdata) * w_t1_mux;
                        acc_tgt2 <= $signed(s_axis_tdata) * w_t2_mux;
                        acc_tgt3 <= $signed(s_axis_tdata) * w_t3_mux;
                        ch_in_ptr <= 3'd1;
                        if (s_axis_tlast) last_flag <= 1'b1;
                        state <= MAC_CALC;
                    end
                end

                MAC_CALC: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        acc_tgt1 <= acc_tgt1 + ($signed(s_axis_tdata) * w_t1_mux);
                        acc_tgt2 <= acc_tgt2 + ($signed(s_axis_tdata) * w_t2_mux);
                        acc_tgt3 <= acc_tgt3 + ($signed(s_axis_tdata) * w_t3_mux);
                        
                        if (s_axis_tlast) last_flag <= 1'b1;
                        
                        if (s_axis_tlast || ch_in_ptr == 3'd6) begin
                            ch_in_ptr <= 3'd0;
                            tgt_out_ptr <= 2'd0;
                            state <= SEND_OUT;
                        end else begin
                            ch_in_ptr <= ch_in_ptr + 1;
                        end
                    end
                end

                SEND_OUT: begin
                    if (m_axis_tready || !m_axis_tvalid) begin
                        m_axis_tvalid <= 1'b1;
                        if (tgt_out_ptr == 2'd0) begin
                            m_axis_tdata <= (acc_tgt1 + 64'sd8388608) >>> FRAC_BITS;
                            m_axis_tlast <= 1'b0;
                            tgt_out_ptr <= 2'd1;
                        end else if (tgt_out_ptr == 2'd1) begin
                            m_axis_tdata <= (acc_tgt2 + 64'sd8388608) >>> FRAC_BITS;
                            m_axis_tlast <= 1'b0;
                            tgt_out_ptr <= 2'd2;
                        end else if (tgt_out_ptr == 2'd2) begin
                            m_axis_tdata <= (acc_tgt3 + 64'sd8388608) >>> FRAC_BITS;
                            m_axis_tlast <= last_flag; 
                            if (last_flag) last_flag <= 1'b0; 
                            tgt_out_ptr <= 2'd0;
                            state <= IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule