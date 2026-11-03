`timescale 1ns / 1ps

module eeg_spatial_filter_3tgt #(
    parameter DATA_WIDTH = 32,
    parameter FRAC_BITS  = 24, 
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 7
)(
    input  wire                              aclk,
    input  wire                              aresetn,

    // 1. AXI4-Lite 从机接口
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

    // 2. AXI-Stream 接口
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

    reg axi_awready, axi_wready, axi_bvalid;
    reg axi_arready, axi_rvalid;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_arready = axi_arready;
    assign s_axi_rvalid  = axi_rvalid;
    assign s_axi_rdata   = 32'd0;
    assign s_axi_rresp   = 2'b00;
    
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_en_addr;
    wire slv_reg_wren = axi_wready && s_axi_wvalid && axi_awready && s_axi_awvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
        end else begin
            // 写握手
            if (~axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                axi_awready <= 1'b1;
                aw_en_addr  <= s_axi_awaddr;
            end else axi_awready <= 1'b0;
            
            if (~axi_wready && s_axi_wvalid && s_axi_awvalid) axi_wready <= 1'b1;
            else axi_wready <= 1'b0;
            
            if (axi_awready && s_axi_awvalid && ~axi_bvalid && axi_wready && s_axi_wvalid) axi_bvalid <= 1'b1;
            else if (s_axi_bready && axi_bvalid) axi_bvalid <= 1'b0;

            // 规范的读握手（防止总线死锁）
            if (~axi_arready && s_axi_arvalid) axi_arready <= 1'b1;
            else axi_arready <= 1'b0;

            if (axi_arready && s_axi_arvalid && ~axi_rvalid) axi_rvalid <= 1'b1;
            else if (axi_rvalid && s_axi_rready) axi_rvalid <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            reg_w_t1_c0 <= 0; reg_w_t1_c1 <= 0; reg_w_t1_c2 <= 0; reg_w_t1_c3 <= 0; reg_w_t1_c4 <= 0; reg_w_t1_c5 <= 0; reg_w_t1_c6 <= 0;
            reg_w_t2_c0 <= 0; reg_w_t2_c1 <= 0; reg_w_t2_c2 <= 0; reg_w_t2_c3 <= 0; reg_w_t2_c4 <= 0; reg_w_t2_c5 <= 0; reg_w_t2_c6 <= 0;
            reg_w_t3_c0 <= 0; reg_w_t3_c1 <= 0; reg_w_t3_c2 <= 0; reg_w_t3_c3 <= 0; reg_w_t3_c4 <= 0; reg_w_t3_c5 <= 0; reg_w_t3_c6 <= 0;
        end else if (slv_reg_wren) begin
            case (aw_en_addr[6:2])
                5'h00: reg_w_t1_c0 <= s_axi_wdata; 5'h01: reg_w_t1_c1 <= s_axi_wdata; 5'h02: reg_w_t1_c2 <= s_axi_wdata;
                5'h03: reg_w_t1_c3 <= s_axi_wdata; 5'h04: reg_w_t1_c4 <= s_axi_wdata; 5'h05: reg_w_t1_c5 <= s_axi_wdata; 5'h06: reg_w_t1_c6 <= s_axi_wdata;
                5'h07: reg_w_t2_c0 <= s_axi_wdata; 5'h08: reg_w_t2_c1 <= s_axi_wdata; 5'h09: reg_w_t2_c2 <= s_axi_wdata;
                5'h0A: reg_w_t2_c3 <= s_axi_wdata; 5'h0B: reg_w_t2_c4 <= s_axi_wdata; 5'h0C: reg_w_t2_c5 <= s_axi_wdata; 5'h0D: reg_w_t2_c6 <= s_axi_wdata;
                5'h0E: reg_w_t3_c0 <= s_axi_wdata; 5'h0F: reg_w_t3_c1 <= s_axi_wdata; 5'h10: reg_w_t3_c2 <= s_axi_wdata;
                5'h11: reg_w_t3_c3 <= s_axi_wdata; 5'h12: reg_w_t3_c4 <= s_axi_wdata; 5'h13: reg_w_t3_c5 <= s_axi_wdata; 5'h14: reg_w_t3_c6 <= s_axi_wdata;
                default: ;
            endcase
        end
    end

    // =========================================================================
    // AXI-Stream 流水线乘加状态机（彻底消除 32x32 组合逻辑违例）
    // =========================================================================
    localparam ST_RECV    = 3'd0; // 接收数据并锁存权重
    localparam ST_MUL     = 3'd1; // 16x16 分段并行乘法 (进 DSP)
    localparam ST_SUM     = 3'd2; // 部分积错位相加
    localparam ST_ACC     = 3'd3; // 累加进 64 位寄存器
    localparam ST_ROUND   = 3'd4; // 提前加偏置并截断锁存
    localparam ST_SEND    = 3'd5; // 标准 AXI-Stream 握手发送

    localparam signed [63:0] ROUND_BIAS = (64'sd1 << (FRAC_BITS - 1));

    reg [2:0] state;
    reg [2:0] ch_in_ptr;  
    reg [1:0] tgt_out_ptr; 
    reg       last_flag;
    reg       ch_is_first;

    reg signed [31:0] x_reg;
    reg signed [31:0] w1_reg, w2_reg, w3_reg;

    // 拆分高低 16 位用于单周期 DSP 乘法
    wire signed [16:0] x_lo  = $signed({1'b0, x_reg[15:0]});
    wire signed [15:0] x_hi  = $signed(x_reg[31:16]);
    wire signed [16:0] w1_lo = $signed({1'b0, w1_reg[15:0]}), w2_lo = $signed({1'b0, w2_reg[15:0]}), w3_lo = $signed({1'b0, w3_reg[15:0]});
    wire signed [15:0] w1_hi = $signed(w1_reg[31:16]),        w2_hi = $signed(w2_reg[31:16]),        w3_hi = $signed(w3_reg[31:16]);

    (* use_dsp = "yes" *) reg signed [33:0] p1_ll, p2_ll, p3_ll;
    (* use_dsp = "yes" *) reg signed [32:0] p1_lh, p1_hl, p2_lh, p2_hl, p3_lh, p3_hl;
    (* use_dsp = "yes" *) reg signed [31:0] p1_hh, p2_hh, p3_hh;

    reg signed [63:0] prod_t1, prod_t2, prod_t3;
    reg signed [63:0] acc_tgt1, acc_tgt2, acc_tgt3;
    reg signed [31:0] out_t1_reg, out_t2_reg, out_t3_reg;

    assign s_axis_tready = aresetn && (state == ST_RECV);

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

    wire signed [63:0] round_t1 = acc_tgt1 + ROUND_BIAS;
    wire signed [63:0] round_t2 = acc_tgt2 + ROUND_BIAS;
    wire signed [63:0] round_t3 = acc_tgt3 + ROUND_BIAS;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state         <= ST_RECV;
            m_axis_tdata  <= 0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            ch_in_ptr     <= 3'd0;
            tgt_out_ptr   <= 2'd0;
            last_flag     <= 1'b0;
            ch_is_first   <= 1'b1;
            x_reg         <= 0;
            w1_reg <= 0; w2_reg <= 0; w3_reg <= 0;
            p1_ll <= 0; p1_lh <= 0; p1_hl <= 0; p1_hh <= 0;
            p2_ll <= 0; p2_lh <= 0; p2_hl <= 0; p2_hh <= 0;
            p3_ll <= 0; p3_lh <= 0; p3_hl <= 0; p3_hh <= 0;
            prod_t1 <= 0; prod_t2 <= 0; prod_t3 <= 0;
            acc_tgt1 <= 0; acc_tgt2 <= 0; acc_tgt3 <= 0;
            out_t1_reg <= 0; out_t2_reg <= 0; out_t3_reg <= 0;
        end else begin
            case (state)
                ST_RECV: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        x_reg       <= $signed(s_axis_tdata);
                        w1_reg      <= w_t1_mux;
                        w2_reg      <= w_t2_mux;
                        w3_reg      <= w_t3_mux;
                        ch_is_first <= (ch_in_ptr == 3'd0);
                        if (ch_in_ptr == 3'd0) last_flag <= s_axis_tlast;
                        else if (s_axis_tlast) last_flag <= 1'b1;
                        state <= ST_MUL;
                    end
                end

                ST_MUL: begin
                    p1_ll <= x_lo * w1_lo; p1_lh <= x_lo * w1_hi; p1_hl <= x_hi * w1_lo; p1_hh <= x_hi * w1_hi;
                    p2_ll <= x_lo * w2_lo; p2_lh <= x_lo * w2_hi; p2_hl <= x_hi * w2_lo; p2_hh <= x_hi * w2_hi;
                    p3_ll <= x_lo * w3_lo; p3_lh <= x_lo * w3_hi; p3_hl <= x_hi * w3_lo; p3_hh <= x_hi * w3_hi;
                    state <= ST_SUM;
                end

                ST_SUM: begin
                    prod_t1 <= $signed({{30{p1_ll[33]}}, p1_ll}) + ($signed({{15{p1_lh[32]}}, p1_lh, 16'd0}) + $signed({{15{p1_hl[32]}}, p1_hl, 16'd0})) + $signed({p1_hh, 32'd0});
                    prod_t2 <= $signed({{30{p2_ll[33]}}, p2_ll}) + ($signed({{15{p2_lh[32]}}, p2_lh, 16'd0}) + $signed({{15{p2_hl[32]}}, p2_hl, 16'd0})) + $signed({p2_hh, 32'd0});
                    prod_t3 <= $signed({{30{p3_ll[33]}}, p3_ll}) + ($signed({{15{p3_lh[32]}}, p3_lh, 16'd0}) + $signed({{15{p3_hl[32]}}, p3_hl, 16'd0})) + $signed({p3_hh, 32'd0});
                    state <= ST_ACC;
                end

                ST_ACC: begin
                    if (ch_is_first) begin
                        acc_tgt1 <= prod_t1;
                        acc_tgt2 <= prod_t2;
                        acc_tgt3 <= prod_t3;
                    end else begin
                        acc_tgt1 <= acc_tgt1 + prod_t1;
                        acc_tgt2 <= acc_tgt2 + prod_t2;
                        acc_tgt3 <= acc_tgt3 + prod_t3;
                    end

                    if (last_flag || ch_in_ptr == 3'd6) begin
                        ch_in_ptr <= 3'd0;
                        state     <= ST_ROUND;
                    end else begin
                        ch_in_ptr <= ch_in_ptr + 1'b1;
                        state     <= ST_RECV;
                    end
                end

                ST_ROUND: begin
                    out_t1_reg  <= round_t1[FRAC_BITS +: 32];
                    out_t2_reg  <= round_t2[FRAC_BITS +: 32];
                    out_t3_reg  <= round_t3[FRAC_BITS +: 32];
                    // 预装载第 0 个目标输出
                    m_axis_tdata  <= round_t1[FRAC_BITS +: 32];
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= 1'b0;
                    tgt_out_ptr   <= 2'd0;
                    state         <= ST_SEND;
                end

                ST_SEND: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (tgt_out_ptr == 2'd0) begin
                            m_axis_tdata  <= out_t2_reg;
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= 1'b0;
                            tgt_out_ptr   <= 2'd1;
                        end else if (tgt_out_ptr == 2'd1) begin
                            m_axis_tdata  <= out_t3_reg;
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= last_flag;
                            tgt_out_ptr   <= 2'd2;
                        end else begin
                            m_axis_tvalid <= 1'b0;
                            m_axis_tlast  <= 1'b0;
                            last_flag     <= 1'b0;
                            tgt_out_ptr   <= 2'd0;
                            state         <= ST_RECV;
                        end
                    end
                end

                default: state <= ST_RECV;
            endcase
        end
    end
endmodule