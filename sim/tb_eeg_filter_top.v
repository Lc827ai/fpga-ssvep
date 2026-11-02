`timescale 1ns / 1ps

module tb_eeg_filter_top;

    parameter integer FS = 500;
    parameter integer N_SAMPLES = 1000;
    parameter integer N_CH = 7;

    parameter real Q24 = 16777216.0;
    parameter real PI  = 3.14159265358979323846;

    reg aclk;
    reg aresetn;

    reg  [31:0] s_axis_tdata;
    reg         s_axis_tvalid;
    wire        s_axis_tready;
    reg         s_axis_tlast;

    wire [31:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready;
    wire        m_axis_tlast;

    eeg_filter_top dut (
        .aclk          (aclk),
        .aresetn       (aresetn),

        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),

        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast)
    );

    // ============================================================
    // 100 MHz functional simulation clock
    // ============================================================
    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    integer n;
    integer ch;
    integer x_q24;

    integer fin;
    integer fout;

    integer out_ch_ptr;
    integer out_count;

    real t;
    real x_real;

    // ============================================================
    // AXI Stream input task
    // ============================================================
    task send_word;
        input [31:0] data_word;
        input        last_word;
        begin
            @(negedge aclk);

            while (s_axis_tready !== 1'b1)
                @(negedge aclk);

            s_axis_tdata  = data_word;
            s_axis_tlast  = last_word;
            s_axis_tvalid = 1'b1;

            @(posedge aclk);

            @(negedge aclk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
        end
    endtask

    // ============================================================
    // Capture output stream
    //
    // 输入顺序：
    //   t0: ch0 ch1 ... ch6
    //   t1: ch0 ch1 ... ch6
    //
    // 输出顺序保持相同，因此每7个输出取第1个作为CH0。
    // ============================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            out_ch_ptr <= 0;
            out_count  <= 0;
        end
        else if (m_axis_tvalid && m_axis_tready) begin

            if (out_ch_ptr == 0) begin

                $fwrite(
                    fout,
                    "%0d\n",
                    $signed(m_axis_tdata)
                );

                out_count <= out_count + 1;

                // 每50个CH0样点强制刷新一次文件缓存
                if ((out_count % 50) == 0)
                    $fflush(fout);
            end

            if (out_ch_ptr == 6)
                out_ch_ptr <= 0;
            else
                out_ch_ptr <= out_ch_ptr + 1;
        end
    end

    // ============================================================
    // Main
    // ============================================================
    initial begin

        aresetn        = 1'b0;
        s_axis_tdata   = 32'd0;
        s_axis_tvalid  = 1'b0;
        s_axis_tlast   = 1'b0;
        m_axis_tready  = 1'b1;

        out_ch_ptr     = 0;
        out_count      = 0;

        // 使用相对路径，文件会生成在Vivado xsim工作目录
        fin = $fopen(
            "iir_input_ch0.txt",
            "w"
        );

        fout = $fopen(
            "iir_output_ch0.txt",
            "w"
        );

        $display(
            "fin handle  = %0d",
            fin
        );

        $display(
            "fout handle = %0d",
            fout
        );

        if (fin == 0) begin
            $display(
                "ERROR: cannot open iir_input_ch0.txt"
            );
            $finish;
        end

        if (fout == 0) begin
            $display(
                "ERROR: cannot open iir_output_ch0.txt"
            );
            $finish;
        end

        // reset
        repeat (10)
            @(posedge aclk);

        aresetn = 1'b1;

        repeat (5)
            @(posedge aclk);

        // ========================================================
        // Generate:
        // 1 Hz + 10 Hz + 80 Hz
        // ========================================================
        for (
            n = 0;
            n < N_SAMPLES;
            n = n + 1
        ) begin

            t = n * 1.0 / FS;

            x_real =
                  0.35 * $sin(
                      2.0 * PI * 1.0 * t
                  )
                + 0.50 * $sin(
                      2.0 * PI * 10.0 * t
                  )
                + 0.30 * $sin(
                      2.0 * PI * 80.0 * t
                  );

            x_q24 = $rtoi(
                x_real * Q24
            );

            $fwrite(
                fin,
                "%0d\n",
                x_q24
            );

            if ((n % 50) == 0)
                $fflush(fin);

            for (
                ch = 0;
                ch < N_CH;
                ch = ch + 1
            ) begin

                send_word(
                    x_q24,
                    (
                        (n == N_SAMPLES - 1)
                        &&
                        (ch == N_CH - 1)
                    )
                );
            end
        end

        // 输入文件写完，立即关闭
        $fflush(fin);
        $fclose(fin);

        $display(
            "All input words sent."
        );

        // ========================================================
        // 不再等待m_axis_tlast。
        // 直接等待CH0输出达到1000点。
        // ========================================================
        wait(
            out_count >= N_SAMPLES
        );

        repeat (20)
            @(posedge aclk);

        $fflush(fout);
        $fclose(fout);

        $display(
            "============================================"
        );

        $display(
            "IIR simulation finished."
        );

        $display(
            "Input CH0 samples  = %0d",
            N_SAMPLES
        );

        $display(
            "Output CH0 samples = %0d",
            out_count
        );

        $display(
            "Files are generated in xsim working directory:"
        );

        $display(
            "iir_input_ch0.txt"
        );

        $display(
            "iir_output_ch0.txt"
        );

        $display(
            "============================================"
        );

        #100;

        $finish;
    end

    // ============================================================
    // Timeout protection
    // 如果输出链路卡死，避免仿真永远不结束。
    // ============================================================
    initial begin
        #5000000;

        $display(
            "ERROR: simulation timeout."
        );

        $display(
            "Current output CH0 count = %0d",
            out_count
        );

        if (fout != 0) begin
            $fflush(fout);
            $fclose(fout);
        end

        $finish;
    end

endmodule
