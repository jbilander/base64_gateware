`timescale 1ns / 1ps
`default_nettype none
//
// turbomem_zii.v — Zorro II autoconfig DIAG ROM window for Base64 (fx68k build)
//
// The THIRD board in the CFGIN/CFGOUT daisy chain, after fastmem_zii. A 64 KB
// Zorro II I/O board carrying nothing but a block-RAM ROM image, so that
// expansion.library copies our DiagArea into RAM and calls DiagPoint. That is
// the whole point of the board: DiagPoint is where turbomem_add() runs and
// hands the $08000000 window to exec with AddMemList().
//
// Chain: cfgin(pin) -> fastmem_zii -> turbomem_zii -> cfgout(pin)
//
// Structure follows autoconfig_zii.v (nybble registers, base capture at
// $48/$4A, CFGOUT registered on the rising edge of AS) and fastmem_zii.v
// (the $00 guard on the upper address byte, the REGISTERED window decode,
// the internal-mux slave interface). It deliberately does NOT touch either
// of those modules — fastmem_zii's autoconfig stays welded to its OFFER_SPLIT
// size negotiation, exactly as the handover requires.
//
// ---------------------------------------------------------------------------
// WHY THE ROM IMAGE SITS AT WINDOW OFFSET 0 AND DIAG_VEC IS $0000
// ---------------------------------------------------------------------------
// er_InitDiagVec is a BYTE offset from the board base, NOT a word offset.
// Three independent sources agree:
//
//   * RKM Libraries, "Events At DIAG Time", worked example: er_InitDiagVec
//     reads $0080 and the DiagArea hex dump is shown at board offset $0080.
//   * The RKM sample source codes the vector as (DiagStart-RomStart), and
//     asserts the preceding ExpansionRom+ExpansionControl block is exactly
//     $80 BYTES ("IFNE *-RomStart-$80 / FAIL").
//   * UAE's expansion.c writes er_InitDiagVec = $1000 and memcpy()s the
//     DiagArea to expamem + 0x1000 — a byte offset — and that bootrom works
//     on real Kickstarts 1.3 through 3.1.
//
// The "word offset" claim comes from a comment in Commodore's own
// libraries/configregs.i. That comment is wrong, and it is an easy trap: it
// is the only place the word reading appears, and it reads authoritatively.
//
// Rather than rely on winning that argument, the default here is immune to
// it: the ROM image starts at window offset 0 and DIAG_VEC is $0000, so the
// byte and word readings resolve to the SAME address. Nothing to get wrong.
//
// If a zero vector ever proves a problem (no documented special case for it,
// but it is untrodden ground), the fallback needs NO change to this module:
// prepend $80 bytes — 64 lines of "0000" — to the .mem file in the Makefile
// and set DIAG_VEC = 16'h0080. That is the RKM-canonical layout and it costs
// no extra decode logic, just a longer image.
//
// ---------------------------------------------------------------------------
// TIMING: THE WINDOW DECODE IS REGISTERED, FOR THE REASON fastmem_zii GIVES
// ---------------------------------------------------------------------------
// rom_win_r is a registered copy of the two eight-bit comparators. tm_space
// then ANDs it with the LIVE as_n, so the decode is one clock old but the
// assertion is not delayed relative to AS — the same construction fastmem_zii
// uses for fm_space, and safe for the same reason: the 68000 presents the
// address at S1, two master clocks before AS falls.
//
// The EBR address comes from the LIVE a[], because the block RAM's address
// port is itself a register — that is already a normal one-clock hop, and
// using the registered decode there would put it two clocks behind.
//
module turbomem_zii #(
    // ROM_FILE IS DECLARED FIRST AND LEFT UNTYPED ON PURPOSE. In an ANSI
    // parameter port list a declaration that omits its data type can inherit
    // the type of the one before it. Sitting behind
    // "parameter integer ROM_AWID = 12" this string risked being coerced to a
    // 32-bit integer, which truncates "turbomem.mem" (96 bits) to its low four
    // characters. With nothing typed in front of it there is nothing to
    // inherit. sd_subsystem.v gets this right by accident -- ROM_INIT_FILE is
    // its only parameter, so it has no typed neighbour.
    parameter        ROM_FILE  = "turbomem.mem",

    parameter [15:0] MFG_ID    = 16'h144A, // 5194 - OAHR, same as the others
    parameter [7:0]  PROD_ID   = 8'd13,    // 5194/13 - turbomem diag ROM
                                           //   (11 = SD card, 12 = fast RAM)
    parameter [31:0] SERIAL    = 32'd0,

    // er_Type low nybble: {chained, size[2:0]}. 0001 = 64 KB, not chained.
    // 64 KB is the smallest a Zorro II board may ask for.
    parameter [3:0]  SIZE_NIB  = 4'b0001,

    // er_Flags, UNINVERTED. $C0 = prefers expansion space, cannot be shut up.
    // This is the value the RKM ROM-board example uses and the value
    // autoconfig_zii.v already carries for the SD card. The $4C shut-up
    // register is still implemented below regardless — advertising "can't be
    // shut up" and then honouring it anyway costs nothing and cannot hurt.
    parameter [3:0]  FLAGS_NIB = 4'b1100,

    // er_InitDiagVec -- BYTE offset from board base to the DiagArea.
    //
    // $2000 rather than $0000, and NOT because zero is broken. BOTH VALUES
    // WERE TESTED ON HARDWARE AND BOTH WORK: KS 1.3 and KS 3.1.4 each
    // follow a zero vector and call DiagPoint.
    //
    // One round of bring-up produced a board that enumerated correctly at
    // its assigned base while DiagPoint never ran, and this field was
    // blamed for it. The build that fixed it changed several things at
    // once and the actual cause was NEVER ESTABLISHED. Do not read a fix
    // into this parameter. If DiagPoint is not running, the things worth
    // eliminating first are which image is really in the bitstream (dump
    // the first two words at the board base and compare da_Size against
    // what the build reported) and whether synthesis re-ran at all -- a
    // new .mem on its own does not necessarily make Diamond rebuild.
    //
    // $2000 is kept only because every real board uses a non-zero vector --
    // the RKM example $0080, UAE $1000, the SF2000 $0001 -- and there is no
    // reason to be the only one that does not. It costs nothing: the image
    // already mirrors every ROM_WORDS*2 = $2000 bytes through the 64 KB
    // window, so board+$2000 returns rom[0] with no decode change.
    //
    // It is also immune to the byte-versus-word reading of this field,
    // since a word-offset reader lands on board+$4000, which mirrors to
    // rom[0] as well. That question is settled -- it is a BYTE offset; see
    // sd_subsystem.v, whose header records the SF2000's $0001 as meaning
    // odd byte addresses on D[7:0] -- but the immunity is free, so keep it.
    // Any multiple of $2000 works while twice it still fits in the window.
    parameter [15:0] DIAG_VEC  = 16'h2000,

    // ROM depth in WORDS, as a power of two. 12 -> 4096 words = 8 KB = 4 EBRs
    // on the ECP5. turbomem.mem is 101 words today, so this is 40x headroom;
    // the SD driver ROM will want its own instance with a bigger number.
    //
    // CHECK THE MAP REPORT AFTER CHANGING THIS. The handover records a build
    // where syn_maxfan replication pushed the fx68k nanoROM out of EBR; EBR
    // is a contended resource in this design, not free space.
    parameter integer ROM_AWID = 12,

    // Master clocks from AS to DTACK on a ROM cycle. 7 -> ~94 ns, the same
    // deliberately-unhurried figure autoconfig_zii.v uses. The EBR answers in
    // one clock; this is not a speed path. The diag area is read ONCE, at
    // boot, 101 words. Do not optimise it.
    parameter [2:0]  ACK_CLKS  = 3'd7
)(
    input  wire        clk,          // 85.13 MHz core clock
    input  wire        reset,        // active high (ext_reset)

    // ---- Amiga bus (fx68k core outputs, clk domain) ----
    input  wire        cfgin_n,      // from fastmem_zii's CFGOUT, not the pin
    input  wire        as_n,
    input  wire        uds_n,
    input  wire        lds_n,
    input  wire        rw,           // 1 = read
    input  wire [31:1] a,            // FULL internal address
    input  wire [15:0] d_in,         // core write data (oEdb)

    // ---- ROM window slave (-> base64_top muxes) ----
    output wire        tm_space,    // this cycle belongs to the ROM window
    output reg  [15:0] tm_dout,     // ROM read data
    output wire        tm_dtack_n,  // internal DTACK for ROM cycles
    output wire        tm_active,   // isolate CBTs this cycle (optional)

    // ---- autoconfig slave (KS reads/writes our $E8 space) ----
    output wire        tm_ac_access,
    output wire [3:0]  tm_ac_dout,
    output wire        tm_ac_oe,
    output wire        tm_ac_dtack_n,

    // ---- chain + debug ----
    output reg         cfgout_n,     // to the CFGOUT pin
    output wire [7:0]  tm_base,     // assigned A23:A16, for Reveal
    output wire        tm_configured
);

localparam integer ROM_WORDS = (1 << ROM_AWID);

reg [7:0] base;
reg       configured;
reg       shutup;

assign tm_base       = base;
assign tm_configured = configured;

wire ds_n = uds_n & lds_n;

// ---------------------------------------------------------------------------
// Autoconfig space: $00E8xxxx while CFGIN is low and we have not yet dropped
// CFGOUT. The a[31:24]==$00 guard is the one fastmem_zii documents — without
// it $01E8xxxx and every other alias lands on the config registers.
// ---------------------------------------------------------------------------
wire ac_access = !cfgin_n && cfgout_n && (a[31:24] == 8'h00)
                 && (a[23:16] == 8'hE8) && !as_n;
wire ac_read   = ac_access && rw && !ds_n;

assign tm_ac_access  = ac_access;
assign tm_ac_oe      = ac_read;
assign tm_ac_dtack_n = ~(ac_access && !ds_n);

// ---------------------------------------------------------------------------
// Read registers. Nybbles on D15:12, INVERTED except $00, $02, $40, $42.
// a[6:1] indexes the $00..$7E register set, so it repeats every 128 bytes
// through $E8xxxx — which is what a real board does.
// ---------------------------------------------------------------------------
reg [3:0] ac_nib;
always @(*) begin
    case (a[6:1])
        6'h00: ac_nib = 4'b1101;            // (00) 11 = Zorro II
                                            //      0  = do NOT add to mem list
                                            //      1  = ERTF_DIAGVALID
        6'h01: ac_nib = SIZE_NIB;           // (02) not chained, 64 KB
        6'h02: ac_nib = ~PROD_ID[7:4];      // (04) product number
        6'h03: ac_nib = ~PROD_ID[3:0];      // (06)
        6'h04: ac_nib = ~FLAGS_NIB;         // (08) er_Flags
        6'h05: ac_nib = ~4'b0000;           // (0A)
        6'h08: ac_nib = ~MFG_ID[15:12];     // (10) manufacturer
        6'h09: ac_nib = ~MFG_ID[11:8];      // (12)
        6'h0A: ac_nib = ~MFG_ID[7:4];       // (14)
        6'h0B: ac_nib = ~MFG_ID[3:0];       // (16)
        6'h0C: ac_nib = ~SERIAL[31:28];     // (18) serial number
        6'h0D: ac_nib = ~SERIAL[27:24];     // (1A)
        6'h0E: ac_nib = ~SERIAL[23:20];     // (1C)
        6'h0F: ac_nib = ~SERIAL[19:16];     // (1E)
        6'h10: ac_nib = ~SERIAL[15:12];     // (20)
        6'h11: ac_nib = ~SERIAL[11:8];      // (22)
        6'h12: ac_nib = ~SERIAL[7:4];       // (24)
        6'h13: ac_nib = ~SERIAL[3:0];       // (26)
        6'h14: ac_nib = ~DIAG_VEC[15:12];   // (28) er_InitDiagVec
        6'h15: ac_nib = ~DIAG_VEC[11:8];    // (2A)
        6'h16: ac_nib = ~DIAG_VEC[7:4];     // (2C)
        6'h17: ac_nib = ~DIAG_VEC[3:0];     // (2E)
        6'h20: ac_nib = 4'b0000;            // (40) no interrupts, NOT inverted
        6'h21: ac_nib = 4'b0000;            // (42) NOT inverted
        default: ac_nib = 4'b1111;          // raw F -> reads back as 0
    endcase
end
assign tm_ac_dout = ac_nib;

// ---------------------------------------------------------------------------
// CFGOUT, registered at end-of-cycle so the $E8 decode is stable for the
// whole bus cycle in which we become configured / shut up.
// ---------------------------------------------------------------------------
reg as_n_q;
always @(posedge clk) as_n_q <= as_n;
wire as_rise = as_n & ~as_n_q;

// Write strobe: leading edge of DS during one of our autoconfig writes.
wire ac_wr = ac_access && !ds_n && !rw;
reg  ac_wr_q;
always @(posedge clk) ac_wr_q <= ac_wr;
wire wr_stb = ac_wr & ~ac_wr_q;

always @(posedge clk) begin
    if (reset) begin
        configured <= 1'b0;
        shutup     <= 1'b0;
        base       <= 8'h00;
        cfgout_n   <= 1'b1;
    end else begin
        if (as_rise)
            cfgout_n <= ~(configured | shutup);

        if (wr_stb) begin
            case (a[6:1])
                6'h24: begin                 // ($48) written second, latches
                    base[7:4]  <= d_in[15:12];
                    configured <= 1'b1;
                end
                6'h25: base[3:0] <= d_in[15:12];  // ($4A) written first
                6'h26: shutup    <= 1'b1;         // ($4C) shut up
                default: ;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// ROM window decode
//
// MUST be gated on `configured`. Before configuration base is $00, and an
// ungated compare would claim $0000xxxx — the exception vector table — from
// the first instruction fetch after reset. That is a dead machine with no
// diagnostics, which is exactly what the bring-up stages exist to avoid.
//
// Not gated on `shutup`: if we were shut up we never got a base, so
// `configured` is already false. (fastmem_zii sets shutup alongside
// configured purely to drop CFGOUT and end its negotiation; a single-offer
// board like this one does not need that.)
// ---------------------------------------------------------------------------
wire tm_win = configured && (a[31:24] == 8'h00) && (a[23:16] == base);

reg rom_win_r;
always @(posedge clk) rom_win_r <= tm_win;

assign tm_space  = rom_win_r && !as_n;
assign tm_active = tm_space;

// ---------------------------------------------------------------------------
// The ROM itself
//
// $readmemh wants one word per line, four hex digits, big-endian — which is
// exactly what the existing Makefile's hexdump '2/1 "%02x"' produces, and why
// it must stay '2/1' and not '1/2'.
//
// The image is ROM_WORDS deep but turbomem.mem is only 101 lines, so the
// image MIRRORS every ROM_WORDS*2 bytes through the 64 KB window. Harmless —
// expansion.library only ever looks at the first copy — but worth knowing if
// you are staring at a memory dump wondering why the DiagArea repeats.
//
// Words past the end of the file are left at whatever the tool defaults to.
// Synplify zero-fills; Icarus leaves them X. Nothing reads them.
//
// THE DECLARATION BELOW IS DELIBERATELY THE SAME SHAPE AS sd_subsystem.v's,
// which is the one ROM in this project known to load from impl1/ on real
// hardware. A bare "initial $readmemh(...)" with no begin/end, no `ifdef and
// no syn_romstyle attribute. If EBR inference ever needs forcing, add
// (* syn_romstyle = "block_rom" *) back -- but change one thing at a time and
// confirm against the block RAM count, because a ROM that quietly falls into
// LUTs and a ROM that quietly loads no data look identical from the Amiga.
//
// If you would rather not depend on the tool's zero-fill at all, pad
// turbomem.mem to ROM_WORDS lines of "0000" in the Makefile -- the four-hex-
// digit check already there will pass, and this becomes a non-question.
// ---------------------------------------------------------------------------
reg [15:0] rom [0:ROM_WORDS-1];
initial $readmemh(ROM_FILE, rom);

reg [15:0] rom_q;
always @(posedge clk) rom_q <= rom[a[ROM_AWID:1]];

// ---------------------------------------------------------------------------
// DTACK for ROM cycles, and the read data hold.
//
// tm_space already carries !as_n, so the counter self-clears when the core
// negates AS and DTACK is held for exactly the rest of the cycle. Writes into
// the window are acknowledged and discarded: a window that answers reads but
// hangs on a stray write is a worse failure than one that quietly ignores it.
// ---------------------------------------------------------------------------
reg [2:0] ack_cnt;
reg       tm_hold;

always @(posedge clk) begin
    if (reset || !tm_space) begin
        ack_cnt  <= 3'd0;
        tm_hold <= 1'b0;
    end else begin
        if (ack_cnt != ACK_CLKS) ack_cnt  <= ack_cnt + 3'd1;
        else                     tm_hold <= 1'b1;
    end
end

assign tm_dtack_n = ~tm_hold;

// Freeze the EBR output once the cycle is acked, so tm_dout cannot move
// under the core between DTACK and the core's latch point.
always @(posedge clk) begin
    if (!tm_hold) tm_dout <= rom_q;
end

endmodule

`default_nettype wire
