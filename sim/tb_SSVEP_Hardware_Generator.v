`timescale 1ns / 1ps

module tb_SSVEP_Hardware_Generator;

    reg         pclk;
    reg         rst_n;
    reg         btn_start;
    reg         ps_stim_en;
    reg  [1:0]  ps_feedback;
    reg         vtc_hsync;
    reg         vtc_vsync;
    reg         vtc_vde;

    wire        vid_hsync;
    wire        vid_vsync;
    wire        vid_vde;
    wire [23:0] vid_data;
    wire        sync_mark_out;

    SSVEP_Hardware_Generator dut (
        .pclk          (pclk),
        .rst_n         (rst_n),
        .btn_start     (btn_start),
        .ps_stim_en    (ps_stim_en),
        .ps_feedback   (ps_feedback),
        .vtc_hsync     (vtc_hsync),
        .vtc_vsync     (vtc_vsync),
        .vtc_vde       (vtc_vde),
        .vid_hsync     (vid_hsync),
        .vid_vsync     (vid_vsync),
        .vid_vde       (vid_vde),
        .vid_data      (vid_data),
        .sync_mark_out (sync_mark_out)
    );

    // ------------------------------------------------------------
    // 顶层调试信号：显式零扩展，保证显示为非负整数
    // ------------------------------------------------------------
    wire        dbg_current_state;
    wire [15:0] dbg_frame_timer_u;
    wire [15:0] dbg_flicker_cnt_u;
    wire        dbg_freq_7_5hz;
    wire        dbg_freq_10hz;
    wire        dbg_freq_12hz;

    assign dbg_current_state = dut.current_state;
    assign dbg_frame_timer_u = {7'b0, dut.frame_timer};
    assign dbg_flicker_cnt_u = {9'b0, dut.flicker_cnt};
    assign dbg_freq_7_5hz = dut.freq_7_5hz;
    assign dbg_freq_10hz  = dut.freq_10hz;
    assign dbg_freq_12hz  = dut.freq_12hz;

    // ------------------------------------------------------------
    // 100 MHz功能仿真时钟
    // ------------------------------------------------------------
    initial pclk = 1'b0;
    always #5 pclk = ~pclk;

    // ------------------------------------------------------------
    // 连续VSYNC：
    // 每1 us一个仿真帧
    // 低900 ns，高100 ns
    // ------------------------------------------------------------
    initial begin
        vtc_vsync = 1'b0;
        forever begin
            #900 vtc_vsync = 1'b1;
            #100 vtc_vsync = 1'b0;
        end
    end

    // ------------------------------------------------------------
    // 主控制
    // ------------------------------------------------------------
    initial begin
        rst_n       = 1'b0;
        btn_start   = 1'b0;
        ps_stim_en  = 1'b0;
        ps_feedback = 2'b00;
        vtc_hsync   = 1'b0;
        vtc_vde     = 1'b0;

        // 100 ns后释放复位
        #100;
        rst_n = 1'b1;

        // 等到2.2 us后拉高刺激请求；
        // 会被2.9 us附近的VSYNC上升沿采样
        #2100;
        ps_stim_en = 1'b1;

        // 保持1.2 us，确保跨过至少一个VSYNC上升沿
        #1200;
        ps_stim_en = 1'b0;

        // 等待足够长时间覆盖300帧自动停止
        #310000;

        $finish;
    end

endmodule
