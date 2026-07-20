// ============================================================================
// sdram_smoke_top.sv — standalone hardware bring-up test for the IS42S16160B
// on the iCESugar-Pro. NO Amiga bus involved: the FPGA alone drives clk_12x,
// runs the SDRAM controller through a write/read/verify sweep, and reports the
// result on the RGB LED. This de-risks the one thing simulation can't fully
// vouch for — real DQ read timing and the ODDR SDRAM clock — before we build
// the Amiga-facing fastmem logic on top.
//
// LED meaning (active-low, drive 0 to light):
//   BLUE  blinking  = init done, test RUNNING (sweeping addresses)
//   GREEN solid     = ALL PASS  (every location wrote & read back correctly)
//   RED   solid     = FAIL      (a mismatch was found; test halted)
//   RED   blinking  = init never completed (SDRAM not responding at all)
//
// The sweep: writes a pseudo-random-ish pattern (addr-derived) to a spread of
// addresses across all 4 banks and many rows, then reads them all back and
// compares. Covers: init, activate/precharge across banks, CAS-latency reads,
// byte lanes, and refresh happening in the background during the walk.
//
// Build: this is a TOP module. Constrain clk_12x (L1) and the three LED pins
// (B11/A11/A12) plus all sdram_* pins per base64.lpf. Program to SRAM (Fast-
// Program) — no flash needed for a smoke test.
// ============================================================================
`default_nettype none

module sdram_smoke_top (
    input  wire        clk_12x,       // L1, 85.13 MHz master clock

    output wire        led_r_n,       // B11
    output wire        led_g_n,       // A11
    output wire        led_b_n,       // A12

    // SDRAM pins (IS42S16160B) — names/sites per base64.lpf
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm,
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n
);
    wire clk = clk_12x;

    // ---- power-on reset: hold reset a few cycles after configuration ----
    reg [3:0] rst_cnt = 4'd0;
    reg       reset   = 1'b1;
    always @(posedge clk) begin
        if (rst_cnt != 4'hF) rst_cnt <= rst_cnt + 4'd1;
        reset <= (rst_cnt != 4'hF);
    end

    // ---- controller ----
    reg         req = 1'b0;
    reg         we  = 1'b0;
    reg  [23:0] addr = 24'd0;
    reg  [15:0] wdata = 16'd0;
    reg  [1:0]  byte_en = 2'b11;
    wire        ack, ready;
    wire [15:0] rdata;

    // internal SDRAM clock (before ODDR); controller drives sdram_clk_int,
    // we forward it to the pin through an ODDR primitive below.
    wire sdram_clk_int;

    sdram_ctrl #(
        .CLK_HZ(85_130_000)
    ) ctrl (
        .clk(clk), .reset(reset),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .byte_en(byte_en),
        .ack(ack), .rdata(rdata), .ready(ready),
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dq(sdram_dq),
        .sdram_dqm(sdram_dqm), .sdram_clk(sdram_clk_int), .sdram_cke(sdram_cke),
        .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n)
    );

    // ---- ODDR clock forwarding: drive sdram_clk from a DDR register so the
    // SDRAM sees a clean, phase-aligned copy of the internal clock. On ECP5
    // this is ODDRX1F clocking {D0=1, D1=0} -> a clock that rises with the
    // internal clock. (Simulation of this file isn't the point; the smoke test
    // runs on hardware.)
    // ---- ODDR clock forwarding with 180-degree phase (inverted) ----
    // Driving D0=0,D1=1 makes the SDRAM clock the INVERSE of the internal
    // clock, so the SDRAM samples command/address/write-data in the MIDDLE of
    // the FPGA's stable output window (the FPGA drives on the rising edge of
    // clk; the SDRAM latches on ITS rising edge = clk's falling edge, half a
    // cycle later, when FPGA outputs are settled). This is the standard,
    // most-often-correct phase for a first SDR SDRAM bring-up. If reads still
    // fail, the fallback is in-phase (D0=1,D1=0) plus CAS latency 3.
    ODDRX1F sdram_clk_oddr (
        .SCLK (clk),
        .RST  (1'b0),
        .D0   (1'b0),
        .D1   (1'b1),
        .Q    (sdram_clk)
    );
    // sdram_clk_int is unused as a pin but keeps the controller's port bound;
    // its command/data outputs are what matter and are already registered to clk.
    wire _unused_clk = sdram_clk_int;

    // ---- test pattern: data derived from address so every location is unique
    // and self-checking without a big golden array.
    function [15:0] pat(input [23:0] a);
        pat = a[15:0] ^ {a[7:0], a[23:16]} ^ 16'hA5A5;
    endfunction

    // ---- address sweep: NADDR locations spread across banks/rows ----
    // step chosen to change bank (addr[10:9]) and row (addr[23:11]) frequently
    localparam integer NADDR = 1024;
    localparam [23:0] STEP  = 24'h000241;   // odd, walks col/bank/row

    localparam S_WAIT = 3'd0,   // wait for init
               S_WR   = 3'd1,   // write phase
               S_WR_A = 3'd2,
               S_RD   = 3'd3,   // read phase
               S_RD_A = 3'd4,
               S_PASS = 3'd5,
               S_FAIL = 3'd6;

    reg [2:0]  state = S_WAIT;
    reg [23:0] cur = 24'd0;
    reg [15:0] idx = 16'd0;

    always @(posedge clk) begin
        if (reset) begin
            state <= S_WAIT; req <= 1'b0; we <= 1'b0;
            cur <= 24'd0; idx <= 16'd0;
        end else begin
            case (state)
            S_WAIT: if (ready) begin
                        cur <= 24'd0; idx <= 16'd0; state <= S_WR;
                    end
            // ---- write sweep ----
            S_WR: begin
                addr    <= cur;
                wdata   <= pat(cur);
                byte_en <= 2'b11;
                we      <= 1'b1;
                req     <= 1'b1;
                state   <= S_WR_A;
            end
            S_WR_A: if (ack) begin
                        req <= 1'b0; we <= 1'b0;
                        if (idx == NADDR-1) begin
                            cur <= 24'd0; idx <= 16'd0; state <= S_RD;
                        end else begin
                            cur <= cur + STEP; idx <= idx + 16'd1; state <= S_WR;
                        end
                    end
            // ---- read/verify sweep ----
            S_RD: begin
                addr  <= cur;
                we    <= 1'b0;
                req   <= 1'b1;
                state <= S_RD_A;
            end
            S_RD_A: if (ack) begin
                        req <= 1'b0;
                        if (rdata !== pat(cur)) begin
                            state <= S_FAIL;
                        end else if (idx == NADDR-1) begin
                            state <= S_PASS;
                        end else begin
                            cur <= cur + STEP; idx <= idx + 16'd1; state <= S_RD;
                        end
                    end
            S_PASS: state <= S_PASS;
            S_FAIL: state <= S_FAIL;
            default: state <= S_FAIL;
            endcase
        end
    end

    // ---- latch phase-reaching events so the display is stable ----
    reg init_seen = 1'b0;
    reg done_pass = 1'b0;
    reg done_fail = 1'b0;
    always @(posedge clk) begin
        if (reset) begin
            init_seen <= 1'b0; done_pass <= 1'b0; done_fail <= 1'b0;
        end else begin
            if (ready)           init_seen <= 1'b1;
            if (state == S_PASS) done_pass <= 1'b1;
            if (state == S_FAIL) done_fail <= 1'b1;
        end
    end

    // ---- LED status: SINGLE-COLOUR distinct blink patterns ----
    // To remove ALL colour-blend ambiguity, we use ONLY the green LED and
    // encode the phase as a distinct blink pattern. Count how many times we
    // pass through S_WAIT->running (init events) is not needed; we just show
    // where the FSM ended up. Red and blue are held OFF entirely.
    //
    //   GREEN solid                 = PASS (test completed, all data matched)
    //   GREEN slow blink (~1 Hz)    = FAIL (data mismatch — init worked, reads bad)
    //   GREEN fast blink (~8 Hz)    = running / stuck before pass (init done, looping)
    //   GREEN double-blink heartbeat= init NEVER completed (SDRAM not answering)
    //   GREEN off                   = clock dead / not running
    reg [26:0] tk = 27'd0;
    always @(posedge clk) tk <= tk + 27'd1;
    wire slow_blink = tk[24];                 // ~2.5 Hz
    wire fast_blink = tk[21];                 // ~20 Hz
    // double-blink: two quick pulses then a gap, ~1 Hz frame
    wire dbl = (tk[24:23] == 2'b00) ? tk[20] : 1'b0;

    reg [1:0] phase;   // 0=off,1=initstuck,2=running,3=fail,(solid handled sep)
    always @(*) begin
        if (done_pass)      phase = 2'd0;     // handled as solid below
        else if (done_fail) phase = 2'd3;
        else if (init_seen) phase = 2'd2;
        else                phase = 2'd1;
    end

    reg g;
    always @(*) begin
        if (done_pass)            g = 1'b1;            // solid
        else case (phase)
            2'd3:    g = slow_blink;                    // FAIL
            2'd2:    g = fast_blink;                    // running
            2'd1:    g = dbl;                           // init stuck
            default: g = 1'b0;
        endcase
    end

    // LED polarity: ACTIVE-HIGH on this board (verified empirically via the
    // led_walk test). Drive 1 to LIGHT a colour, 0 to turn it OFF. The "_n"
    // suffix is a misnomer inherited from an incorrect early comment; there is
    // no inversion here.
    assign led_r_n = 1'b0;      // red OFF
    assign led_b_n = 1'b0;      // blue OFF
    assign led_g_n = g;         // green shows the pattern (1 = lit)

endmodule
