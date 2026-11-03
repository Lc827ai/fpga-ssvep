`timescale 1ns / 1ps

// Q24-compatible, time-multiplexed biquad. Default widths: 32 bits.
// One shared multiplier datapath, implemented as four registered partial products.
// DATA_WIDTH and COEF_WIDTH must be in 1..32; FRAC_BITS in 1..62.
module eeg_iir_biquad_tdm_7ch #(
    parameter DATA_WIDTH = 32,
    parameter COEF_WIDTH = 32,
    parameter FRAC_BITS = 24,
    parameter signed [COEF_WIDTH-1:0] B0_SEC = 0,
    parameter signed [COEF_WIDTH-1:0] B1_SEC = 0,
    parameter signed [COEF_WIDTH-1:0] B2_SEC = 0,
    parameter signed [COEF_WIDTH-1:0] A1_SEC = 0,
    parameter signed [COEF_WIDTH-1:0] A2_SEC = 0
)(
    input wire aclk,
    input wire aresetn,
    input wire [DATA_WIDTH-1:0] s_axis_tdata,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire s_axis_tlast,
    output reg [DATA_WIDTH-1:0] m_axis_tdata,
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg m_axis_tlast
);
    localparam ST_IDLE = 4'd0, ST_LOAD = 4'd1, ST_MUL = 4'd2,
               ST_PAIR_LO = 4'd3, ST_PAIR_HI = 4'd4, ST_PRODUCT = 4'd5,
               ST_ACC_PREP = 4'd6, ST_ACC_DONE = 4'd7,
               ST_ROUND_PREP = 4'd8, ST_ROUND_DONE = 4'd9,
               ST_OUTPUT = 4'd10, ST_WAIT = 4'd11, ST_ADD = 4'd12,
               ST_READ = 4'd13;
    localparam signed [63:0] ROUND_BIAS = 64'sd1 << (FRAC_BITS-1);
    (* fsm_encoding = "one_hot" *) reg [3:0] state;
    (* max_fanout = 32 *) reg [2:0] ch_ptr;
    reg [2:0] term_ptr;
    reg last_pending;
    reg signed [DATA_WIDTH-1:0] x_hist_1 [0:6];
    reg signed [DATA_WIDTH-1:0] x_hist_2 [0:6];
    reg signed [DATA_WIDTH-1:0] y_hist_1 [0:6];
    reg signed [DATA_WIDTH-1:0] y_hist_2 [0:6];
    reg signed [DATA_WIDTH-1:0] current_x;
    reg signed [DATA_WIDTH-1:0] saved_x1, saved_x2, saved_y1, saved_y2;
    reg [6:0] history_we;
    reg signed [31:0] mult_op_a, mult_op_b;
    // Low halves are unsigned, represented with an explicit zero sign bit.
    wire signed [16:0] a_lo = $signed({1'b0, mult_op_a[15:0]});
    wire signed [16:0] b_lo = $signed({1'b0, mult_op_b[15:0]});
    wire signed [15:0] a_hi = $signed(mult_op_a[31:16]);
    wire signed [15:0] b_hi = $signed(mult_op_b[31:16]);
    (* use_dsp = "yes" *) reg signed [33:0] p_ll;
    (* use_dsp = "yes" *) reg signed [32:0] p_lh, p_hl;
    (* use_dsp = "yes" *) reg signed [31:0] p_hh;
    wire signed [63:0] ll_ext = {{30{p_ll[33]}}, p_ll};
    wire signed [63:0] lh_ext = {{31{p_lh[32]}}, p_lh};
    wire signed [63:0] hl_ext = {{31{p_hl[32]}}, p_hl};
    wire signed [63:0] hh_ext = {{32{p_hh[31]}}, p_hh};
    reg signed [63:0] pair_lo;
    reg subtract_term;
    // Shared limb adder: four registered 16-bit additions, modulo 2^64.
    // No 64-bit carry chain is left in product assembly, MAC or rounding.
    reg [63:0] add_a, add_b, add_result;
    reg add_carry;
    reg [1:0] add_limb;
    reg [3:0] add_return;
    wire [16:0] limb_sum = {1'b0, add_a[15:0]} +
                          {1'b0, add_b[15:0]} + {16'd0, add_carry};
    reg signed [63:0] accumulator, rounded_reg;
    wire signed [63:0] shifted_result = rounded_reg >>> FRAC_BITS;
    integer i;

    assign s_axis_tready = aresetn && (state == ST_IDLE);

    // Registered per-channel write enables; no state decode on history CE paths.
    genvar c;
    generate for (c=0; c<7; c=c+1) begin : hist_bank
        always @(posedge aclk) begin
            if (!aresetn) begin
                history_we[c] <= 0;
                x_hist_1[c] <= 0; x_hist_2[c] <= 0;
                y_hist_1[c] <= 0; y_hist_2[c] <= 0;
            end else begin
                history_we[c] <= (state == ST_ROUND_DONE) && (ch_ptr == c);
                if (history_we[c]) begin
                    x_hist_2[c] <= x_hist_1[c];
                    x_hist_1[c] <= current_x;
                    y_hist_2[c] <= y_hist_1[c];
                    y_hist_1[c] <= shifted_result[DATA_WIDTH-1:0];
                end
            end
        end
    end endgenerate

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= ST_IDLE;
            ch_ptr <= 0;
            term_ptr <= 0;
            last_pending <= 0;
            m_axis_tdata <= 0;
            m_axis_tvalid <= 0;
            m_axis_tlast <= 0;
            current_x <= 0;
            saved_x1 <= 0; saved_x2 <= 0; saved_y1 <= 0; saved_y2 <= 0;
            mult_op_a <= 0;
            mult_op_b <= 0;
            p_ll <= 0; p_lh <= 0; p_hl <= 0; p_hh <= 0;
            pair_lo <= 0; subtract_term <= 0;
            add_a <= 0; add_b <= 0; add_result <= 0;
            add_carry <= 0; add_limb <= 0; add_return <= ST_IDLE;
            accumulator <= 0; rounded_reg <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        current_x <= $signed(s_axis_tdata);
                        last_pending <= s_axis_tlast;
                        term_ptr <= 0;
                        accumulator <= 0;
                        state <= ST_READ;
                    end
                end
                ST_READ: begin
                    saved_x1 <= x_hist_1[ch_ptr];
                    saved_x2 <= x_hist_2[ch_ptr];
                    saved_y1 <= y_hist_1[ch_ptr];
                    saved_y2 <= y_hist_2[ch_ptr];
                    state <= ST_LOAD;
                end
                ST_LOAD: begin
                    subtract_term <= (term_ptr >= 3);
                    case (term_ptr)
                        0: begin mult_op_a <= current_x;        mult_op_b <= B0_SEC; end
                        1: begin mult_op_a <= saved_x1; mult_op_b <= B1_SEC; end
                        2: begin mult_op_a <= saved_x2; mult_op_b <= B2_SEC; end
                        3: begin mult_op_a <= saved_y1; mult_op_b <= A1_SEC; end
                        4: begin mult_op_a <= saved_y2; mult_op_b <= A2_SEC; end
                        default: begin mult_op_a <= 0; mult_op_b <= 0; end
                    endcase
                    state <= ST_MUL;
                end
                ST_MUL: begin
                    p_ll <= a_lo * b_lo;
                    p_lh <= a_lo * b_hi;
                    p_hl <= a_hi * b_lo;
                    p_hh <= a_hi * b_hi;
                    state <= ST_PAIR_LO;
                end
                ST_PAIR_LO: begin
                    add_a <= ll_ext;
                    add_b <= lh_ext <<< 16;
                    add_carry <= 0; add_limb <= 0;
                    add_return <= ST_PAIR_HI;
                    state <= ST_ADD;
                end
                ST_PAIR_HI: begin
                    pair_lo <= add_result;
                    add_a <= hl_ext <<< 16;
                    add_b <= hh_ext <<< 32;
                    add_carry <= 0; add_limb <= 0;
                    add_return <= ST_PRODUCT;
                    state <= ST_ADD;
                end
                ST_PRODUCT: begin
                    add_a <= pair_lo;
                    add_b <= add_result;
                    add_carry <= 0; add_limb <= 0;
                    add_return <= ST_ACC_PREP;
                    state <= ST_ADD;
                end
                ST_ACC_PREP: begin
                    add_a <= accumulator;
                    // A-B = A + ~B + 1. Decode and inversion are registered.
                    add_b <= subtract_term ? ~add_result : add_result;
                    add_carry <= subtract_term; add_limb <= 0;
                    add_return <= ST_ACC_DONE;
                    state <= ST_ADD;
                end
                ST_ACC_DONE: begin
                    accumulator <= add_result;
                    if (term_ptr == 4)
                        state <= ST_ROUND_PREP;
                    else begin
                        term_ptr <= term_ptr + 1'b1;
                        state <= ST_LOAD;
                    end
                end
                ST_ROUND_PREP: begin
                    // Preserve the ORIGINAL positive-bias rounding and 64-bit wrap.
                    add_a <= accumulator;
                    add_b <= ROUND_BIAS;
                    add_carry <= 0; add_limb <= 0;
                    add_return <= ST_ROUND_DONE;
                    state <= ST_ADD;
                end
                ST_ROUND_DONE: begin
                    rounded_reg <= add_result;
                    state <= ST_OUTPUT;
                end
                ST_ADD: begin
                    add_result <= {limb_sum[15:0], add_result[63:16]};
                    add_carry <= limb_sum[16];
                    add_a <= {16'd0, add_a[63:16]};
                    add_b <= {16'd0, add_b[63:16]};
                    if (add_limb == 3)
                        state <= add_return;
                    else
                        add_limb <= add_limb + 1'b1;
                end
                ST_OUTPUT: begin
                    m_axis_tdata <= shifted_result[DATA_WIDTH-1:0];
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast <= last_pending;
                    state <= ST_WAIT;
                end
                ST_WAIT: begin
                    // Keep DATA, VALID and LAST stable throughout backpressure.
                    if (m_axis_tvalid && m_axis_tready) begin
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast <= 1'b0;
                        if (ch_ptr == 6) ch_ptr <= 0;
                        else ch_ptr <= ch_ptr + 1'b1;
                        state <= ST_IDLE;
                    end
                end
                default: begin
                    state <= ST_IDLE;
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast <= 1'b0;
                end
            endcase
        end
    end
endmodule
