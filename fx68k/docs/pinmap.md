# Base64 revC — 68000 socket to ECP5 ball mapping

Derived by tracing `Base64.net` (KiCad) through the SN74CBTD3861 switches to the
SODIMM-200 connector, joined with the iCESugar-Pro v1.3 netlist annotations,
cross-validated against the LFE5U-25F BG256 pin table (0 mismatches).

## Clocks
| Signal | Path | SODIMM | ECP5 ball | Pad function |
|---|---|---|---|---|
| 7M (buffered) | CPU pin 15 → 74LVC1G17 → 33R | 118 | **C7** | PCLKT0_1 (primary clock) |
| 12x (85.1 MHz) | ICS570B CLK → 33R | 115 | **L1** | PCLKT6_1 (primary clock) |
| 25 MHz osc | on-module | — | **P6** | PL47C / GPLL0 dedicated input |

ICS570B: S0/S1 floating (M/M), FBIN driven from the **CLK/2** output via 33R —
zero-delay loop closes on the ÷2 node, so CLK = 12× input, CLK/2 = 6× input,
both phase-aligned to the 7M input.

## 68000 socket signals
| 68k pin | Signal | Dir (FPGA) | Carrier net | SODIMM | ECP5 ball | Switch |
|---|---|---|---|---|---|---|
| 29 | A1 | out (3-state) | PT18A | 63 | **A5** | U8 |
| 30 | A2 | out (3-state) | PT22B | 61 | **B6** | U8 |
| 31 | A3 | out (3-state) | PT18B | 59 | **A6** | U8 |
| 32 | A4 | out (3-state) | PT27B | 57 | **B7** | U8 |
| 33 | A5 | out (3-state) | PT29A | 51 | **A7** | U8 |
| 34 | A6 | out (3-state) | PT35B | 49 | **B8** | U8 |
| 35 | A7 | out (3-state) | PT29B | 41 | **A8** | U8 |
| 36 | A8 | out (3-state) | PR17C | 70 | **J13** | U7 |
| 37 | A9 | out (3-state) | PR20C | 68 | **J14** | U7 |
| 38 | A10 | out (3-state) | PR38A | 50 | **N13** | U7 |
| 39 | A11 | out (3-state) | PR41A | 48 | **P13** | U7 |
| 40 | A12 | out (3-state) | PT6B | 67 | **A4** | U7 |
| 41 | A13 | out (3-state) | PT11B | 69 | **B4** | U7 |
| 42 | A14 | out (3-state) | PT6A | 71 | **A3** | U7 |
| 43 | A15 | out (3-state) | PT4B | 73 | **B3** | U7 |
| 44 | A16 | out (3-state) | PR44D | 46 | **N12** | U7 |
| 45 | A17 | out (3-state) | PR47C | 42 | **P11** | U7 |
| 46 | A18 | out (3-state) | PT62D | 90 | **C13** | U4 |
| 47 | A19 | out (3-state) | PT62A | 92 | **D13** | U4 |
| 48 | A20 | out (3-state) | PT58D | 94 | **C12** | U4 |
| 50 | A21 | out (3-state) | PT58A | 96 | **D12** | U4 |
| 51 | A22 | out (3-state) | PT49B | 98 | **C11** | U4 |
| 52 | A23 | out (3-state) | PT51A | 100 | **D11** | U4 |
| 6 | AS | out (3-state) | PT44B | 102 | **C10** | U4 |
| 22 | BERR | in | PR29A | 66 | **K13** | U6 |
| 11 | BG | out (3-state) | PT62B | 86 | **E13** | U5 |
| 12 | BGACK | in | PT58B | 88 | **E12** | U5 |
| 13 | BR | in | PR5C | 84 | **E14** | U5 |
| 5 | D0 | bidir | PL29A | 154 | **K4** | U2 |
| 4 | D1 | bidir | PL20C | 152 | **J3** | U2 |
| 3 | D2 | bidir | PL17C | 150 | **J4** | U2 |
| 2 | D3 | bidir | PL14D | 148 | **H3** | U2 |
| 1 | D4 | bidir | PL14C | 146 | **G3** | U2 |
| 64 | D5 | bidir | PL11B | 144 | **G4** | U2 |
| 63 | D6 | bidir | PL5D | 142 | **F3** | U2 |
| 62 | D7 | bidir | PL8C | 140 | **F4** | U2 |
| 61 | D8 | bidir | PT9A | 136 | **E4** | U3 |
| 60 | D9 | bidir | PL2C | 134 | **C3** | U3 |
| 59 | D10 | bidir | PT9B | 132 | **D4** | U3 |
| 58 | D11 | bidir | PT11A | 130 | **C4** | U3 |
| 57 | D12 | bidir | PT13B | 128 | **D5** | U3 |
| 56 | D13 | bidir | PT15A | 126 | **C5** | U3 |
| 55 | D14 | bidir | PT20B | 124 | **D6** | U3 |
| 54 | D15 | bidir | PT22A | 122 | **C6** | U3 |
| 10 | DTACK | in | PR8C | 82 | **F13** | U5 |
| 20 | E | out (3-state) | PR11B | 78 | **G13** | U5 |
| 28 | FC0 | out (3-state) | PR35C | 58 | **M13** | U6 |
| 27 | FC1 | out (3-state) | PR44C | 54 | **M12** | U6 |
| 26 | FC2 | out (3-state) | PR38B | 52 | **P14** | U6 |
| 17 | HALT | bidir, open-drain | PR17B | 74 | **H13** | U5 |
| 25 | IPL0 | in | PR32C | 60 | **L14** | U6 |
| 24 | IPL1 | in | PR29C | 62 | **L13** | U6 |
| 23 | IPL2 | in | PR20D | 64 | **K14** | U6 |
| 8 | LDS | out (3-state) | PT38B | 110 | **C9** | U4 |
| 18 | RESET | bidir, open-drain | PR14D | 72 | **H14** | U5 |
| 9 | RW | out (3-state) | PT40A | 112 | **D9** | U4 |
| 7 | UDS | out (3-state) | PT47A | 104 | **D10** | U4 |
| 19 | VMA | out (3-state) | PR5D | 80 | **F14** | U5 |
| 21 | VPA | in | PR14C | 76 | **G14** | U5 |

## CBT output enables (active low; U5/U6 hardwired enabled)
| Switch | Group | Carrier net | SODIMM | ECP5 ball |
|---|---|---|---|---|
| U2 | D0–D7 | PL20D | 156 | **K3** |
| U3 | D8–D15 | PL5C | 138 | **E3** |
| U4 | RW/LDS/UDS/AS, A18–A23 | PT35A | 114 | **C8** |
| U7 | A8–A17 | PR47D | 44 | **P12** |
| U8 | A1–A7 | PT15B | 65 | **B5** |

## Autoconfig header J2
| Signal | Dir | ECP5 ball | Note |
|---|---|---|---|
| /CFGIN | in | **B1** | 10k pullup to 5V on carrier |
| /CFGOUT | out | **B2** | drive = CFGIN pass-through until autoconfig implemented |

## Module resources (fixed, from iCESugar-Pro netlist)
SDRAM IS42S16160 (32 MB): A0–A12 = H15 B13 B12 J16 J15 R12 K16 R13 T13 K15 A13 R14 T14;
BA0/1 = G15 B14; DQ0–15 = F16 E15 F15 D14 E16 C15 D16 B15 R16 P16 P15 N16 N14 M16 M15 L15;
DQM0/1 = C16 T15; CLK=R15 CKE=L16 nRAS=B16 nCAS=G16 nWE=A15 nCS=A14.

SD card: CLK=J12 CMD=H12 D0=K12 D1=L12 D2=F12 D3=G12.

RGB LED (active low): R=B11 G=A11 B=A12. UART to iCELink USB-CDC: FPGA-TX=B9, FPGA-RX=A9.

Notes: module net names "PT58D"/"PT62D" are misnomers — actual balls C12/C13 (PT56B/PT60B).
All module I/O banks are 3.3 V. ECP5 user I/O have weak pull-ups while unconfigured, which
holds the five CBT OE lines high (switches off / bus isolated) until the bitstream loads.
