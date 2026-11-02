`timescale 1ns / 1ps

module SSVEP_Hardware_Generator(
    input  wire        pclk,          // 148.5MHz 像素时钟
    input  wire        rst_n,         
    input  wire        btn_start,     
    input  wire        ps_stim_en,    // PS端眨眼触发信号
    input  wire [1:0]  ps_feedback,   // PS端反馈信号 (00:白, 01:绿, 10:红)
    
    input  wire        vtc_hsync,
    input  wire        vtc_vsync,
    input  wire        vtc_vde,       
    
    output wire        vid_hsync,
    output wire        vid_vsync,
    output wire        vid_vde,
    output wire [23:0] vid_data,      
    
    output wire        sync_mark_out  
);

    assign vid_hsync = vtc_hsync;
    assign vid_vsync = vtc_vsync;
    assign vid_vde   = vtc_vde;

    // 1. 像素坐标生成
    reg [11:0] x_pos, y_pos; 
    reg prev_vde, prev_vsync;
    always @(posedge pclk) begin
        if (!rst_n) begin
            x_pos <= 0; y_pos <= 0;
            prev_vde <= 0; prev_vsync <= 0;
        end else begin
            prev_vde <= vtc_vde; prev_vsync <= vtc_vsync;
            if (vtc_vde) x_pos <= x_pos + 1;
            else if (!vtc_vde && prev_vde) begin
                x_pos <= 0; y_pos <= y_pos + 1;
            end
            if (vtc_vsync && !prev_vsync) begin
                x_pos <= 0; y_pos <= 0;
            end
        end
    end

    // 2. 状态机
    localparam STATE_IDLE = 1'b0;
    localparam STATE_STIM = 1'b1;
    reg current_state;
    reg [8:0] frame_timer; 

    always @(posedge pclk) begin
        if (!rst_n) begin
            current_state <= STATE_IDLE;
            frame_timer <= 0;
        end else if (vtc_vsync && !prev_vsync) begin 
            case (current_state)
                STATE_IDLE: begin
                    if (btn_start || ps_stim_en) begin  
                        current_state <= STATE_STIM;
                        frame_timer <= 0;
                    end
                end
                STATE_STIM: begin
                    if (frame_timer == 299) begin // 5秒
                        current_state <= STATE_IDLE;
                        frame_timer <= 0;
                    end else frame_timer <= frame_timer + 1;
                end
            endcase
        end
    end

    // 3. 频率生成器 (更新为完美的 60Hz 整数分频)
    reg [6:0] flicker_cnt; 
    always @(posedge pclk) begin
        if (!rst_n || current_state != STATE_STIM) flicker_cnt <= 0;
        else if (vtc_vsync && !prev_vsync) begin
            if (flicker_cnt == 119) flicker_cnt <= 0;
            else flicker_cnt <= flicker_cnt + 1;
        end
    end
    
    // ? 新增/修改：Target 1 (7.5Hz), Target 2 (10Hz), Target 3 (12Hz)
    wire freq_7_5hz = (flicker_cnt % 8) < 4; // 8帧一周期 (60/8 = 7.5)
    wire freq_10hz  = (flicker_cnt % 6) < 3; // 6帧一周期 (60/6 = 10.0)
    wire freq_12hz  = (flicker_cnt % 5) < 2; // 5帧一周期 (60/5 = 12.0)

    // 4. 闪烁刺激方块坐标 (保持不变)
    wire box_1 = (x_pos >= 330  && x_pos < 630)  && (y_pos >= 390 && y_pos < 690); 
    wire box_2 = (x_pos >= 810  && x_pos < 1110) && (y_pos >= 390 && y_pos < 690); 
    wire box_3 = (x_pos >= 1290 && x_pos < 1590) && (y_pos >= 390 && y_pos < 690); 

    wire border_1 = box_1 && (x_pos < 335  || x_pos >= 625  || y_pos < 395 || y_pos >= 685);
    wire border_2 = box_2 && (x_pos < 815  || x_pos >= 1105 || y_pos < 395 || y_pos >= 685);
    wire border_3 = box_3 && (x_pos < 1295 || x_pos >= 1585 || y_pos < 395 || y_pos >= 685);

    // 5. 数字字模 (? 修改：全部向上平移了 300 个像素，脱离方块内部)
    // 注意：这里的 num 信号已经脱离了 box_X 的限制，变成了独立的绘制区域
    wire num_1 = (x_pos > 460 && x_pos < 500) && (y_pos > 150 && y_pos < 330);
    wire num_2 = ((x_pos > 900 && x_pos < 1020 && y_pos > 150 && y_pos < 190) || 
                  (x_pos > 900 && x_pos < 1020 && y_pos > 220 && y_pos < 260) || 
                  (x_pos > 900 && x_pos < 1020 && y_pos > 290 && y_pos < 330) || 
                  (x_pos > 980 && x_pos < 1020 && y_pos > 150 && y_pos < 260) || 
                  (x_pos > 900 && x_pos < 940  && y_pos > 220 && y_pos < 330));
    wire num_3 = ((x_pos > 1380 && x_pos < 1500 && y_pos > 150 && y_pos < 190) || 
                  (x_pos > 1380 && x_pos < 1500 && y_pos > 220 && y_pos < 260) || 
                  (x_pos > 1380 && x_pos < 1500 && y_pos > 290 && y_pos < 330) || 
                  (x_pos > 1460 && x_pos < 1500 && y_pos > 150 && y_pos < 330));

    // 6. 主题色定义与合成
    reg [23:0] theme_color;
    always @(*) begin
        // 只有在待机状态，且有反馈信号时，才改变颜色
        if (current_state == STATE_IDLE) begin
            case(ps_feedback)
                2'b01: theme_color = 24'h00FF00; // 识别正确：纯绿
                2'b10: theme_color = 24'hFF0000; // 识别错误：纯红
                default: theme_color = 24'hFFFFFF; // 默认：纯白
            endcase
        end else begin
            theme_color = 24'hFFFFFF; // 刺激闪烁期间保持纯白
        end
    end

    reg [23:0] out_rgb;
    always @(*) begin
        if (!vtc_vde) out_rgb = 24'h000000; 
        else begin
            out_rgb = 24'h000000; // 默认黑底

            // ? 绘制逻辑修改：首先绘制顶部的独立数字标签（不受方块闪烁影响，保持常亮）
            if (num_1 || num_2 || num_3) begin
                out_rgb = theme_color;
            end
            
            // 绘制方块1 (Target 1: 7.5Hz)
            else if (box_1) begin
                if (border_1) out_rgb = theme_color; 
                else out_rgb = (current_state == STATE_STIM && freq_7_5hz) ? 24'hFFFFFF : 24'h000000; 
            end 
            
            // 绘制方块2 (Target 2: 10.0Hz)
            else if (box_2) begin
                if (border_2) out_rgb = theme_color; 
                else out_rgb = (current_state == STATE_STIM && freq_10hz) ? 24'hFFFFFF : 24'h000000; 
            end 
            
            // 绘制方块3 (Target 3: 12.0Hz)
            else if (box_3) begin
                if (border_3) out_rgb = theme_color; 
                else out_rgb = (current_state == STATE_STIM && freq_12hz) ? 24'hFFFFFF : 24'h000000; 
            end
        end
    end

    assign vid_data = out_rgb;
    assign sync_mark_out = (current_state == STATE_STIM);

endmodule