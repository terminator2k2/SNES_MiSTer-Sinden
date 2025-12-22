// =====================================================
// lightgun.sv
// Original MiSTer lightgun logic + fixed 20px white border
// =====================================================
module lightgun
(
    input         CLK,
    input         RESET,

    input  [24:0] MOUSE,
    input         MOUSE_XY,

    input  [7:0]  JOY_X, JOY_Y,
    input         F, C, T, P,

    input         HDE, VDE,
    input         CLKPIX,
    
    output [2:0]  TARGET,
    input         SIZE,       // 0 = 256px mode, 1 = 512px hi-res mode
    input         GUN_TYPE,

    input         PORT_LATCH,
    input         PORT_CLK,
    output        PORT_P6,
    output [1:0]  PORT_DO,

    // Border control
    input         border_en_gun,
    output reg    border,
	// Dynamic Sinden border size (menu controlled)
    input  [3:0] border_h,  // horizontal border width selector (5–20)
    input  [3:0] border_v  // vertical border height selector (5–20)
);

parameter CROSS_SZ  = 8'd3;
wire [9:0] border_w_px = 10'd5 + {6'd0, border_h};
wire [9:0] border_h_px = 10'd5 + {6'd0, border_v};

//---------------------------------------------------------
// Port / Gun I/O
//---------------------------------------------------------
reg Ttr; // trigger toggle
reg Fb = 0, Pb = 0;

reg [2:0] reload_pend;
reg [2:0] reload;

reg [7:0] JOY_LATCH0;
reg [31:0] JUSTIFIER_LATCH;

assign PORT_DO = {1'b1, GUN_TYPE ? JUSTIFIER_LATCH[31] : JOY_LATCH0[7]};
assign TARGET  = {{2{~Ttr & ~offscreen & draw}}, Ttr & ~offscreen & draw};

//---------------------------------------------------------
// State Registers
//---------------------------------------------------------
reg old_clk, old_f, old_p, old_t, old_latch;
reg old_pix, old_hde, old_vde, old_ms;
reg [15:0] hde_d;

reg [9:0] hcnt;        // horizontal pixel counter
reg [9:0] vcnt;        // vertical line counter
reg [9:0] hcnt_max;    // measured active width per line
reg [9:0] vtotal;      // measured active height
reg [16:0] jy1, jy2;

reg [8:0] lg_x, lg_y, x, y;
reg [8:0] xm, xp, ym, yp; 

reg offscreen = 0, draw = 0;
reg [21:0] port_p6_sr;
reg reload_pressed;

//---------------------------------------------------------
// Port latch and trigger logic
//---------------------------------------------------------
always @(posedge CLK) begin
    old_clk   <= PORT_CLK;
    old_latch <= PORT_LATCH;

    if (old_latch & ~PORT_LATCH) begin
        Pb <= 0;
        if (~Ttr) Fb <= 0;
    end

    old_t <= T;
    if (~old_t & T) Ttr <= ~Ttr;
    if (RESET) Ttr <= 1;

    old_f <= F;
    if (~old_f & F) Fb <= 1;
    if (old_f & ~F) Fb <= 0;

    old_p <= P;
    if (~old_p & P) Pb <= 1;

    if (PORT_LATCH) begin
        JOY_LATCH0 <= ~{Fb, C, Ttr, Pb, 2'b00, offscreen, 1'b0};
        JUSTIFIER_LATCH <= ~{24'b000000000000111001010101,
                              reload ? 1'b1 : (reload_pend ? 1'b0 : F),
                              1'b0, P, 1'b0, 4'b1000};
    end
    else if (~old_clk & PORT_CLK) begin
        JOY_LATCH0      <= JOY_LATCH0 << 1;
        JUSTIFIER_LATCH <= JUSTIFIER_LATCH << 1;
    end
end

//---------------------------------------------------------
// Mouse / joystick and pixel timing logic
//---------------------------------------------------------
wire [9:0] new_x = {lg_x[8], lg_x} + {{2{MOUSE[4]}}, MOUSE[15:8]};
wire [9:0] new_y = {lg_y[8], lg_y} - {{2{MOUSE[5]}}, MOUSE[23:16]};

wire [8:0] j_x = {~JOY_X[7], JOY_X[6:0]};
wire [8:0] j_y = {~JOY_Y[7], JOY_Y[6:0]};

always @(posedge CLK) begin
    old_pix <= CLKPIX;

    jy1 <= {8'd0, j_y} * vtotal;
    jy2 <= jy1;

    old_ms <= MOUSE[24];
    if (MOUSE_XY) begin
        if (old_ms ^ MOUSE[24]) begin
            if (new_x[9])      lg_x <= 0;
            else if (new_x[8]) lg_x <= 255;
            else               lg_x <= new_x[8:0];

            if (new_y[9])           lg_y <= 0;
            else if (new_y > vtotal) lg_y <= vtotal;
            else                     lg_y <= new_y[8:0];
        end
    end
    else begin
        lg_x <= j_x;
        lg_y <= jy2[16:8];
        if (jy2[16:8] > vtotal) lg_y <= vtotal;
    end

    if (~old_pix & CLKPIX) begin
        hde_d <= {hde_d[14:0], HDE};
        old_hde <= hde_d[15];

        // Horizontal count during HDE
        if (HDE) begin
            if (~&hcnt) hcnt <= hcnt + 1'd1;
        end else begin
            hcnt <= 0;
        end

        // Capture visible width
        if (old_hde && ~HDE) begin
            hcnt_max <= hcnt;
        end

        // Vertical count
        if (old_hde & ~hde_d[15]) begin
            if (~VDE) begin
                vcnt <= 0;
                if (vcnt) vtotal <= vcnt - 1'd1;
            end
            else if (~&vcnt) vcnt <= vcnt + 1'd1;
        end

        old_vde <= VDE;
        if (~old_vde & VDE) begin
            x  <= lg_x;
            y  <= lg_y;
            xm <= lg_x - CROSS_SZ;
            xp <= lg_x + CROSS_SZ;
            ym <= lg_y - CROSS_SZ;
            yp <= lg_y + CROSS_SZ;

            offscreen <= !lg_y[7:1] || lg_y >= (vtotal - 1'd1) ||
                         !lg_x[7:1] || &lg_x[7:1] ||
                         reload_pend || reload;

            if (reload_pend && !reload) begin
                reload_pend <= reload_pend - 3'd1;
                if (reload_pend == 3'd1) reload <= 3'd5;
            end
            else if (reload) reload <= reload - 3'd1;
        end

        port_p6_sr <= {port_p6_sr[20:0],
                       ~(HDE && VDE && x == hcnt && y == vcnt) || offscreen };
    end

    reload_pressed <= C;
    if (GUN_TYPE && C && ~reload_pressed)
        reload_pend <= 3'd5;

    PORT_P6 <= port_p6_sr[21];

    draw <= (((SIZE || ($signed(hcnt) >= $signed(xm) && hcnt <= xp)) && y == vcnt) ||
             ((SIZE || ($signed(vcnt) >= $signed(ym) && vcnt <= yp)) && x == hcnt));
end

//---------------------------------------------------------
// Border Drawing Logic (menu-controlled, adaptive)
//---------------------------------------------------------
always @(posedge CLK) begin
    border <= 1'b0;

    if (border_en_gun && HDE && VDE) begin
        if (hcnt_max != 0) begin
            if ((hcnt < border_w_px) ||
                (hcnt >= (hcnt_max - border_w_px)) ||
                (vcnt < border_h_px) ||
                (vcnt >= (vtotal - border_h_px)))
                border <= 1'b1;
        end else begin
            if (SIZE) begin
                if ((hcnt < border_w_px) ||
                    (hcnt >= (10'd512 - border_w_px)) ||
                    (vcnt < border_h_px) ||
                    (vcnt >= (vtotal - border_h_px)))
                    border <= 1'b1;
            end else begin
                if ((hcnt < border_w_px) ||
                    (hcnt >= (10'd256 - border_w_px)) ||
                    (vcnt < border_h_px) ||
                    (vcnt >= (vtotal - border_h_px)))
                    border <= 1'b1;
            end
        end
    end
end

endmodule
