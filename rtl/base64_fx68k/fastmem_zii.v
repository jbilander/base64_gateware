`timescale 1ns / 1ps
`default_nettype none
//
// fastmem_zii.v — Zorro II autoconfig fast RAM for Base64, bridging the Amiga
// bus to the verified sdram_ctrl (IS42S16160B). Up to 8 MB in the 24-bit Z2
// fast window ($200000-$9FFFFF), with gottagofast-style GRACEFUL FALLBACK:
// offer 8 MB, and if Kickstart can't place it (told to shut up), offer 4 MB,
// then 2 MB, then 1 MB. Optionally offer a 2 MB + 4 MB pair (6 MB) to fit
// around a pre-existing board like an A590/2091 (OFFER_SPLIT).
//
// Design notes matching the rest of Base64:
//  * Fully SYNCHRONOUS to the core clock (like autoconfig_zii_b64), not the
//    async negedge-UDS style of the original gottagofast. Cleaner and matches
//    the proven internal-mux approach.
//  * addr_match[7:0] is a bitmap of which 1 MB slots in the 8 MB window we own
//    (slot i = address region ($2+i)00000). One SDRAM answers all owned slots;
//    the SPLIT case lets us own two separately-assigned blocks.
//  * Bus slave via internal muxing: we produce fm_space (this cycle is ours),
//    fm_dout/fm_dtack_n for the read/ack mux, and a `req` to the controller.
//    NO pin contention — base64_top muxes these into the core inputs.
//  * fm_active tells base64_top to OPEN the switchable CBTs (isolate this
//    cycle from the motherboard) so CPU<->SDRAM traffic never reaches the bus.
//
// Address translation: the Amiga byte address within our window maps to a
// linear SDRAM WORD address. Slot bitmap -> which 1 MB region; low 20 bits ->
// offset in that MB. We pack owned slots CONTIGUOUSLY in SDRAM (slot presence
// order) so a fragmented 6 MB (2+4) still uses a dense 0..6MB SDRAM range.
//
module fastmem_zii #(
    parameter [15:0] MFG_ID   = 16'h144A,   // reuse OAHR id; product distinct
    parameter [7:0]  PROD_ID  = 8'd12,      // 5194/12 = Base64 fast RAM
    parameter [31:0] SERIAL   = 32'd0,
    parameter        OFFER_SPLIT = 1'b1     // 1: after 2M, also offer 4M (6M total)
)(
    input  wire        clk,
    input  wire        reset,        // active high (~s_reset_n | ~pwrup_done)

    // ---- Amiga bus (fx68k core outputs, clk domain) ----
    input  wire        cfgin_n,      // synchronized CFGIN
    input  wire        as_n,
    input  wire        uds_n,
    input  wire        lds_n,
    input  wire        rw,           // 1 = read
    input  wire [23:1] a,
    input  wire [15:0] d_in,         // core write data (oEdb)

    // ---- to base64_top muxes ----
    output wire        fm_space,     // this cycle belongs to fast RAM (memory)
    output reg  [15:0] fm_dout,      // RAM read data (valid when fm_space & rw & ack)
    output reg         fm_dtack_n,   // internal DTACK for our RAM cycles
    output wire        fm_active,    // isolate CBTs this cycle (CPU<->SDRAM)
    output reg         cfgout_n,     // autoconfig chain out

    // ---- autoconfig slave outputs (KS reads/writes our $E8 space) ----
    output wire        fm_ac_access, // this cycle is our autoconfig space
    output wire [3:0]  fm_ac_dout,   // autoconfig read nibble (-> D15:12)
    output wire        fm_ac_oe,     // drive the nibble this cycle
    output wire        fm_ac_dtack_n,// DTACK for autoconfig cycles

    // ---- to sdram_ctrl handshake ----
    output reg         req,
    output reg         we,
    output reg  [23:0] saddr,        // SDRAM word address
    output reg  [15:0] wdata,
    output reg  [1:0]  byte_en,
    input  wire        ack,
    input  wire [15:0] rdata,
    input  wire        sdram_ready
);

// ---------------------------------------------------------------------------
// Autoconfig
// ---------------------------------------------------------------------------
reg        configured;
reg        shutup;
reg [2:0]  ac_state;
reg [7:0]  addr_match;   // owned 1 MB slots in $2..$9

// state order: SPLIT requires offering 2M before 4M (KS config-overflow bug,
// per gottagofast). Non-split just walks 8->4->2->1.
localparam OFFER_8M = 3'd0,
           OFFER_4M = 3'd1,
           OFFER_2M = 3'd2,
           OFFER_1M = 3'd3,
           OFFER_S4 = 3'd4,   // split: the 4M half offered after the 2M half
           DONE     = 3'd5;

wire ds_n = uds_n & lds_n;

// autoconfig region: $E8xxxx while unconfigured and CFGIN low
wire ac_access = !cfgin_n && cfgout_n && (a[23:16] == 8'hE8) && !as_n;
wire ac_read   = ac_access && rw && !ds_n;

// ---- autoconfig slave outputs ----
// (fm_ac_dout = ac_nib is assigned after the ac_nib computation below, since
// ac_nib is declared there.)
assign fm_ac_access  = ac_access;
assign fm_ac_oe      = ac_read;
assign fm_ac_dtack_n = ~(ac_access && !ds_n);

// size code at register 0x01 per current offer
reg [3:0] size_code;
always @(*) begin
    case (ac_state)
        OFFER_8M: size_code = 4'b0000;   // 8 MB
        OFFER_4M: size_code = 4'b0111;   // 4 MB
        OFFER_2M: size_code = 4'b0110;   // 2 MB
        OFFER_1M: size_code = 4'b0101;   // 1 MB
        OFFER_S4: size_code = 4'b0111;   // 4 MB (split second block)
        default:  size_code = 4'b0000;
    endcase
end

// autoconfig read data (nibble on D15:12), inverted except 00/02/40/42
reg [3:0] ac_nib;
always @(*) begin
    case (a[8:1])
        8'h00: ac_nib = 4'b1110;              // Zorro II, link to mem free pool, no ROM
        8'h01: ac_nib = size_code;
        8'h02: ac_nib = ~PROD_ID[7:4];
        8'h03: ac_nib = ~PROD_ID[3:0];
        8'h04: ac_nib = ~4'b1000;             // board not in 8M autoconfig space? (matches ggf)
        8'h05: ac_nib = ~4'b0000;
        8'h08: ac_nib = ~MFG_ID[15:12];
        8'h09: ac_nib = ~MFG_ID[11:8];
        8'h0A: ac_nib = ~MFG_ID[7:4];
        8'h0B: ac_nib = ~MFG_ID[3:0];
        8'h0C: ac_nib = ~SERIAL[31:28];
        8'h0D: ac_nib = ~SERIAL[27:24];
        8'h0E: ac_nib = ~SERIAL[23:20];
        8'h0F: ac_nib = ~SERIAL[19:16];
        8'h10: ac_nib = ~SERIAL[15:12];
        8'h11: ac_nib = ~SERIAL[11:8];
        8'h12: ac_nib = ~SERIAL[7:4];
        8'h13: ac_nib = ~SERIAL[3:0];
        8'h20: ac_nib = 4'b0000;
        8'h21: ac_nib = 4'b0000;
        default: ac_nib = 4'b1111;
    endcase
end

// autoconfig read nibble to D15:12 (ac_nib declared above)
assign fm_ac_dout = ac_nib;

// CFGOUT registered at end-of-cycle (rising edge of AS)
reg as_n_q;
always @(posedge clk) as_n_q <= as_n;
wire as_rise = as_n & ~as_n_q;

// write strobe (leading edge of DS during our AC write)
wire ac_wr = ac_access && !ds_n && !rw;
reg  ac_wr_q;
always @(posedge clk) ac_wr_q <= ac_wr;
wire wr_stb = ac_wr & ~ac_wr_q;

// The high nibble Kickstart writes to reg 0x24/0x25 encodes WHERE in the 8 MB
// window it placed the block. We OR the corresponding slot bits into
// addr_match, following gottagofast's mapping.
always @(posedge clk) begin
    if (reset) begin
        configured <= 1'b0;
        shutup     <= 1'b0;
        ac_state   <= OFFER_8M;
        addr_match <= 8'h00;
        cfgout_n   <= 1'b1;
    end else begin
        if (as_rise)
            cfgout_n <= ~(configured | shutup);

        if (wr_stb) begin
            case (a[8:1])
                // shut up: KS couldn't place this offer
                8'h26: begin
                    case (ac_state)
                        OFFER_8M: begin ac_state <= OFFER_4M; end
                        OFFER_4M: begin ac_state <= OFFER_2M; end
                        OFFER_2M: begin ac_state <= OFFER_1M; end
                        OFFER_1M: begin shutup <= 1'b1; ac_state <= DONE; end
                        OFFER_S4: begin shutup <= 1'b1; ac_state <= DONE; end
                        default:  begin shutup <= 1'b1; ac_state <= DONE; end
                    endcase
                end
                // base address assigned (high nibble in d_in[15:12] at 0x24)
                8'h24: begin
                    case (ac_state)
                        OFFER_8M: begin
                            addr_match <= 8'hFF;              // all 8 slots
                            configured <= 1'b1; shutup <= 1'b1; ac_state <= DONE;
                        end
                        OFFER_4M: begin
                            case (d_in[15:12])
                                4'h2: addr_match <= addr_match | 8'b00001111;
                                4'h4: addr_match <= addr_match | 8'b00111100;
                                4'h6: addr_match <= addr_match | 8'b11110000;
                                default: ;
                            endcase
                            configured <= 1'b1; shutup <= 1'b1; ac_state <= DONE;
                        end
                        OFFER_2M: begin
                            case (d_in[15:12])
                                4'h2: addr_match <= addr_match | 8'b00000011;
                                4'h4: addr_match <= addr_match | 8'b00001100;
                                4'h6: addr_match <= addr_match | 8'b00110000;
                                4'h8: addr_match <= addr_match | 8'b11000000;
                                default: ;
                            endcase
                            configured <= 1'b1;
                            if (OFFER_SPLIT) begin
                                ac_state <= OFFER_S4;        // offer 4M next
                            end else begin
                                shutup <= 1'b1; ac_state <= DONE;
                            end
                        end
                        OFFER_S4: begin
                            case (d_in[15:12])
                                4'h2: addr_match <= addr_match | 8'b00001111;
                                4'h4: addr_match <= addr_match | 8'b00111100;
                                4'h6: addr_match <= addr_match | 8'b11110000;
                                default: ;
                            endcase
                            shutup <= 1'b1; ac_state <= DONE;
                        end
                        OFFER_1M: begin
                            case (d_in[15:12])
                                4'h2: addr_match <= addr_match | 8'b00000001;
                                4'h3: addr_match <= addr_match | 8'b00000010;
                                4'h4: addr_match <= addr_match | 8'b00000100;
                                4'h5: addr_match <= addr_match | 8'b00001000;
                                4'h6: addr_match <= addr_match | 8'b00010000;
                                4'h7: addr_match <= addr_match | 8'b00100000;
                                4'h8: addr_match <= addr_match | 8'b01000000;
                                4'h9: addr_match <= addr_match | 8'b10000000;
                                default: ;
                            endcase
                            configured <= 1'b1; shutup <= 1'b1; ac_state <= DONE;
                        end
                        default: ;
                    endcase
                end
                default: ;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// Fast-RAM address decode: which slot does A[23:20] fall in, and do we own it?
// slot index = A[23:20] - 2  (region $2..$9 -> slot 0..7)
// ---------------------------------------------------------------------------
wire [3:0] region = a[23:20];
wire       in_window = configured && (region >= 4'h2) && (region <= 4'h9);
wire [2:0] slot = region[2:0] - 3'd2;     // 0..7
wire       owns = in_window && addr_match[slot];

assign fm_space  = owns && !as_n;
assign fm_active = fm_space;              // isolate CBTs on our cycles

// Dense SDRAM packing: count owned slots below `slot` to get the block's base
// MB offset within SDRAM (so fragmented ownership stays contiguous in RAM).
function [3:0] popcount_below;
    input [7:0] mask;
    input [2:0] upto;    // count bits [upto-1:0]
    integer i;
    begin
        popcount_below = 4'd0;
        for (i=0;i<8;i=i+1)
            if (i < upto && mask[i]) popcount_below = popcount_below + 4'd1;
    end
endfunction

wire [3:0] dense_mb = popcount_below(addr_match, slot);   // which MB in SDRAM
// SDRAM WORD address: {dense_mb (which 1MB), A[19:1] within the MB}
// 1 MB = 512K words -> 19-bit word offset = A[19:1].
wire [23:0] sdram_word = {1'b0, dense_mb, a[19:1]};

// ---------------------------------------------------------------------------
// Bus <-> controller bridge FSM (complete within one 68000 cycle)
// ---------------------------------------------------------------------------
localparam B_IDLE = 2'd0,
           B_REQ  = 2'd1,
           B_DONE = 2'd2;
reg [1:0] bstate;

always @(posedge clk) begin
    if (reset) begin
        bstate     <= B_IDLE;
        req        <= 1'b0;
        we         <= 1'b0;
        fm_dtack_n <= 1'b1;
        fm_dout    <= 16'd0;
    end else begin
        case (bstate)
        B_IDLE: begin
            fm_dtack_n <= 1'b1;
            req        <= 1'b0;
            // start when our space is selected and data strobes are valid
            if (fm_space && !ds_n && sdram_ready) begin
                saddr   <= sdram_word;
                we      <= ~rw;
                wdata   <= d_in;
                byte_en <= ~{uds_n, lds_n};   // uds->high byte, lds->low byte
                req     <= 1'b1;
                bstate  <= B_REQ;
            end
        end
        B_REQ: begin
            if (ack) begin
                req    <= 1'b0;
                if (rw) fm_dout <= rdata;
                fm_dtack_n <= 1'b0;            // terminate the CPU cycle
                bstate <= B_DONE;
            end
        end
        B_DONE: begin
            // hold DTACK asserted until the CPU ends the cycle (AS high)
            if (as_n) begin
                fm_dtack_n <= 1'b1;
                bstate     <= B_IDLE;
            end
        end
        default: bstate <= B_IDLE;
        endcase
    end
end

endmodule
