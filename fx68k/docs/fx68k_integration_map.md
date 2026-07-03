# fx68k as a second core in base64_gateware — integration map

How `tg68wrapper.sv` translates when the kernel is `fx68k_sys` instead of
TG68KdotC_Kernel. Goal: an `fx68kwrapper.sv` that is port-compatible with
`tg68wrapper.sv` (same module interface: clocks, cpu_req/cpu_resp,
socket_miscin, sdr_in/out, uart/spi pins), so projects choose a core by
instantiating one wrapper or the other.

## Core hookup

| tg68wrapper (TG68)                          | fx68kwrapper (fx68k_sys)                         |
|---------------------------------------------|--------------------------------------------------|
| `clkena` pacing, min 4 clks apart           | gone — pacing is `PACE` inside fx68k_sys; wait states = withholding `cyc_done` (fx68k's native DTACK mechanism) |
| `tg68_state` (FETCH/INTERNAL/READ/WRITE)    | `cyc_req` pulse + `wr`/`ifetch` flags; INTERNAL cycles never surface (core keeps running between requests) |
| `if (tg68_state==STATE_INTERNAL) clkena<=1` | delete — nothing to tick                          |
| `clkena <= 1'b1` (complete cycle)           | `cyc_done <= 1'b1` (+ rdata valid that clock)     |
| `tg68_din <= X`                             | `rdata <= X` with `cyc_done`                      |
| `tg68_dout / tg68_addr / uds / lds / wr`    | `wdata / addr / ds[1] / ds[0] / wr` (note ds already active-high: `dm <= ds`) |
| `CPU(2'b11)` — 68020 mode                   | n/a — fx68k is 68000-only: `sel_fast32` region (0x40000000) is unreachable; 24-bit fastram at 0x200000, softkick, peripherals all unchanged |
| `IPL(socket_miscin.ipl)` raw                | `ipl_n` (fx68k_sys synchronizes internally)       |
| `IPL_autovector(1'b0)` + bridge autovector  | IACK autovectored via VPA inside fx68k_sys        |
| `berr(1'b0)`                                | BERRn tied high inside fx68k_sys                  |
| `nResetOut` + `cpureset_d` feedback guard   | `reset_out` (active high) — same guard pattern applies |

## FSM skeleton delta

The DECODE state simplifies: instead of "pace clkena, look at tg68_state",
it waits for `cyc_req` (or a JTAG request) and latches nothing extra —
addr/wr/ds/wdata are held stable by fx68k_sys until `cyc_done`:

    DECODE: if (jtag pending) ... as today ...
            else if (cyc_req_latched) begin
                if (sel_fast24) -> FASTRAM (as today, sdram_we <= wr, etc.)
                else            -> REQ
            end

Every `clkena <= 1'b1; state <= DECODE;` becomes
`cyc_done <= 1'b1; state <= DECODE;`. Everything else — address decode,
softkick/overlay, boot ROM, UART/SPI/SERDAT, JTAG user commands, jcapture —
carries over verbatim (jcapture taps: replace `tg68_state` with
`{ifetch, wr}` or similar, `clkena` with `cyc_done`).

`sel_fast24` timing note: in tg68wrapper the fast24 select is combinational
off the live address for speed. With fx68k_sys the address is stable from
`cyc_req` until `cyc_done`, so the same combinational select off `addr`
works; there is no clkena race to beat.

## What stays open (needs files from the repo to finalize)

1. `base64_m68k_pkg.sv` / `cpu_pkg.sv` / `sdram_pkg.sv` — exact struct
   fields for cpu_request/cpu_response/m68k_clocks/m68k_misc_in.
2. `m68k_bridge.sv` — confirm the req/ack toggle protocol details and how
   IPL/reset are conveyed, so `cpu_req.*` driving in fx68kwrapper matches.
3. `hostclocks.sv` — where the 570B/12x adaptation lands; proposal: expose
   the divide-by-12 phase counter and per-phase enables (enPhi1/enPhi2 plus
   a "phase index" for the bridge), so the same generator serves the TG68
   bridge timing and fx68k compat mode (`USE_EXT_PHASES=1`).

## The two projects, restated

- **base64_fx68k** (turbo lineage, in-tree beside his): fx68kwrapper per
  the mapping above. Inherits boot ROM, softkick, SD, SDRAM, jcapture.
  Socket timing = m68k_bridge's, instruction timing = exact 68000.
- **base64_fx68k_compat** (cycle-exact lineage): separate top; fx68k pins
  essentially straight to the socket, enables from hostclocks' 7M-locked
  phases; bridge/decode/bootrom bypassed. Shares hostclocks + constraints
  only. The autoconfig block (his `sel_autoconfig` branch is currently
  empty) is the piece that should be written once, core-neutral, and used
  by both lineages.
