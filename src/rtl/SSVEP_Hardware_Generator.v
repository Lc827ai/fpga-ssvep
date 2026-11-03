`timescale 1ns / 1ps

module SSVEP_Hardware_Generator(
    input  wire        pclk,          // 74.25 MHz
    input  wire        rst_n,

    input  wire        btn_start,
    input  wire        ps_stim_en,
    input  wire [1:0]  ps_feedback,

    input  wire        vtc_hsync,
    input  wire        vtc_vsync,
    input  wire        vtc_vde,

    output reg         vid_hsync,
    output reg         vid_vsync,
    output reg         vid_vde,
    output reg  [23:0] vid_data,

    output reg         sync_mark_out
);

    // =========================================================================
    // 1. 复位同步：异步断言、同步释放
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg rst_sync1;
    (* ASYNC_REG = "TRUE" *) reg rst_sync2;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync1 <= 1'b0;
            rst_sync2 <= 1'b0;
        end else begin
            rst_sync1 <= 1'b1;
            rst_sync2 <= rst_sync1;
        end
    end

    wire p_rst_n = rst_sync2;


    // =========================================================================
    // 2. PS/外部控制信号同步到pclk域
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg btn_sync1;
    (* ASYNC_REG = "TRUE" *) reg btn_sync2;

    (* ASYNC_REG = "TRUE" *) reg stim_en_sync1;
    (* ASYNC_REG = "TRUE" *) reg stim_en_sync2;

    (* ASYNC_REG = "TRUE" *) reg [1:0] fb_sync1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] fb_sync2;
    (* ASYNC_REG = "TRUE" *) reg [1:0] fb_sync3;

    reg [1:0] feedback_stable;

    reg btn_sync2_d;
    reg stim_en_sync2_d;

    always @(posedge pclk) begin
        if (!p_rst_n) begin
            btn_sync1      <= 1'b0;
            btn_sync2      <= 1'b0;
            btn_sync2_d    <= 1'b0;

            stim_en_sync1  <= 1'b0;
            stim_en_sync2  <= 1'b0;
            stim_en_sync2_d <= 1'b0;

            fb_sync1       <= 2'b00;
            fb_sync2       <= 2'b00;
            fb_sync3       <= 2'b00;
            feedback_stable <= 2'b00;
        end else begin
            btn_sync1   <= btn_start;
            btn_sync2   <= btn_sync1;
            btn_sync2_d <= btn_sync2;

            stim_en_sync1   <= ps_stim_en;
            stim_en_sync2   <= stim_en_sync1;
            stim_en_sync2_d <= stim_en_sync2;

            fb_sync1 <= ps_feedback;
            fb_sync2 <= fb_sync1;
            fb_sync3 <= fb_sync2;

            // 连续两拍一致时才更新反馈值，降低多位总线切换风险
            if (fb_sync2 == fb_sync3)
                feedback_stable <= fb_sync3;
        end
    end

    wire btn_start_pulse =
        btn_sync2 && !btn_sync2_d;

    wire stim_start_pulse =
        stim_en_sync2 && !stim_en_sync2_d;


    // =========================================================================
    // 3. 像素坐标
    // =========================================================================
    reg [11:0] x_pos;
    reg [11:0] y_pos;

    reg prev_vde;
    reg prev_vsync;

    wire frame_start =
        vtc_vsync && !prev_vsync;

    always @(posedge pclk) begin
        if (!p_rst_n) begin
            x_pos      <= 12'd0;
            y_pos      <= 12'd0;
            prev_vde   <= 1'b0;
            prev_vsync <= 1'b0;
        end else begin
            prev_vde   <= vtc_vde;
            prev_vsync <= vtc_vsync;

            if (vtc_vde) begin
                x_pos <= x_pos + 1'b1;
            end else if (!vtc_vde && prev_vde) begin
                x_pos <= 12'd0;
                y_pos <= y_pos + 1'b1;
            end

            if (frame_start) begin
                x_pos <= 12'd0;
                y_pos <= 12'd0;
            end
        end
    end


    // =========================================================================
    // 4. 5秒刺激状态机
    // =========================================================================
    localparam STATE_IDLE = 1'b0;
    localparam STATE_STIM = 1'b1;

    reg       current_state;
    reg [8:0] frame_timer;

    // 启动请求先锁存，防止窄脉冲没有正好落在VSYNC上
    reg start_pending;

    always @(posedge pclk) begin
        if (!p_rst_n) begin
            start_pending <= 1'b0;
        end else begin
            if (btn_start_pulse || stim_start_pulse)
                start_pending <= 1'b1;

            if (frame_start &&
                current_state == STATE_IDLE &&
                start_pending)
                start_pending <= 1'b0;
        end
    end

    always @(posedge pclk) begin
        if (!p_rst_n) begin
            current_state <= STATE_IDLE;
            frame_timer   <= 9'd0;
        end else if (frame_start) begin
            case (current_state)

                STATE_IDLE: begin
                    if (start_pending) begin
                        current_state <= STATE_STIM;
                        frame_timer   <= 9'd0;
                    end
                end

                STATE_STIM: begin
                    if (frame_timer == 9'd299) begin
                        current_state <= STATE_IDLE;
                        frame_timer   <= 9'd0;
                    end else begin
                        frame_timer <= frame_timer + 1'b1;
                    end
                end

                default: begin
                    current_state <= STATE_IDLE;
                    frame_timer   <= 9'd0;
                end
            endcase
        end
    end


    // =========================================================================
    // 5. 7.5 / 10 / 12 Hz频率生成
    // =========================================================================
    reg [2:0] cnt_8;
    reg [2:0] cnt_6;
    reg [2:0] cnt_5;

    always @(posedge pclk) begin
        if (!p_rst_n || current_state != STATE_STIM) begin
            cnt_8 <= 3'd0;
            cnt_6 <= 3'd0;
            cnt_5 <= 3'd0;
        end else if (frame_start) begin
            if (cnt_8 == 3'd7)
                cnt_8 <= 3'd0;
            else
                cnt_8 <= cnt_8 + 1'b1;

            if (cnt_6 == 3'd5)
                cnt_6 <= 3'd0;
            else
                cnt_6 <= cnt_6 + 1'b1;

            if (cnt_5 == 3'd4)
                cnt_5 <= 3'd0;
            else
                cnt_5 <= cnt_5 + 1'b1;
        end
    end

    wire freq_7_5hz =
        (cnt_8 < 3'd4);

    wire freq_10hz =
        (cnt_6 < 3'd3);

    wire freq_12hz =
        (cnt_5 < 3'd2);


    // =========================================================================
    // 6. 1280×720刺激区域
    // =========================================================================
    wire box_1 =
        (x_pos >= 12'd220 && x_pos < 12'd420) &&
        (y_pos >= 12'd260 && y_pos < 12'd460);

    wire box_2 =
        (x_pos >= 12'd540 && x_pos < 12'd740) &&
        (y_pos >= 12'd260 && y_pos < 12'd460);

    wire box_3 =
        (x_pos >= 12'd860 && x_pos < 12'd1060) &&
        (y_pos >= 12'd260 && y_pos < 12'd460);

    wire border_1 =
        box_1 &&
        (x_pos < 12'd224 ||
         x_pos >= 12'd416 ||
         y_pos < 12'd264 ||
         y_pos >= 12'd456);

    wire border_2 =
        box_2 &&
        (x_pos < 12'd544 ||
         x_pos >= 12'd736 ||
         y_pos < 12'd264 ||
         y_pos >= 12'd456);

    wire border_3 =
        box_3 &&
        (x_pos < 12'd864 ||
         x_pos >= 12'd1056 ||
         y_pos < 12'd264 ||
         y_pos >= 12'd456);


    // =========================================================================
    // 7. 数字1、2、3
    // =========================================================================
    wire num_1 =
        (x_pos > 12'd307 && x_pos < 12'd333) &&
        (y_pos > 12'd100 && y_pos < 12'd220);

    wire num_2 =
        ((x_pos > 12'd600 && x_pos < 12'd680 &&
          y_pos > 12'd100 && y_pos < 12'd127) ||

         (x_pos > 12'd600 && x_pos < 12'd680 &&
          y_pos > 12'd147 && y_pos < 12'd173) ||

         (x_pos > 12'd600 && x_pos < 12'd680 &&
          y_pos > 12'd193 && y_pos < 12'd220) ||

         (x_pos > 12'd653 && x_pos < 12'd680 &&
          y_pos > 12'd100 && y_pos < 12'd173) ||

         (x_pos > 12'd600 && x_pos < 12'd627 &&
          y_pos > 12'd147 && y_pos < 12'd220));

    wire num_3 =
        ((x_pos > 12'd920 && x_pos < 12'd1000 &&
          y_pos > 12'd100 && y_pos < 12'd127) ||

         (x_pos > 12'd920 && x_pos < 12'd1000 &&
          y_pos > 12'd147 && y_pos < 12'd173) ||

         (x_pos > 12'd920 && x_pos < 12'd1000 &&
          y_pos > 12'd193 && y_pos < 12'd220) ||

         (x_pos > 12'd973 && x_pos < 12'd1000 &&
          y_pos > 12'd100 && y_pos < 12'd220));


    // =========================================================================
    // 8. 像素生成
    // =========================================================================
    reg [23:0] theme_color;
    reg [23:0] comb_rgb;

    always @(*) begin
        if (current_state == STATE_IDLE) begin
            case (feedback_stable)
                2'b01:
                    theme_color = 24'h00FF00;

                2'b10:
                    theme_color = 24'hFF0000;

                default:
                    theme_color = 24'hFFFFFF;
            endcase
        end else begin
            theme_color = 24'hFFFFFF;
        end
    end

    always @(*) begin
        if (!vtc_vde) begin
            comb_rgb = 24'h000000;
        end else if (num_1 || num_2 || num_3) begin
            comb_rgb = theme_color;
        end else if (box_1) begin
            comb_rgb =
                border_1
                ? theme_color
                : ((current_state == STATE_STIM && freq_7_5hz)
                   ? 24'hFFFFFF
                   : 24'h000000);
        end else if (box_2) begin
            comb_rgb =
                border_2
                ? theme_color
                : ((current_state == STATE_STIM && freq_10hz)
                   ? 24'hFFFFFF
                   : 24'h000000);
        end else if (box_3) begin
            comb_rgb =
                border_3
                ? theme_color
                : ((current_state == STATE_STIM && freq_12hz)
                   ? 24'hFFFFFF
                   : 24'h000000);
        end else begin
            comb_rgb = 24'h000000;
        end
    end


    // =========================================================================
    // 9. 输出寄存
    // =========================================================================
    always @(posedge pclk) begin
        if (!p_rst_n) begin
            vid_hsync     <= 1'b0;
            vid_vsync     <= 1'b0;
            vid_vde       <= 1'b0;
            vid_data      <= 24'h000000;
            sync_mark_out <= 1'b0;
        end else begin
            vid_hsync     <= vtc_hsync;
            vid_vsync     <= vtc_vsync;
            vid_vde       <= vtc_vde;
            vid_data      <= comb_rgb;
            sync_mark_out <=
                (current_state == STATE_STIM);
        end
    end

endmodule