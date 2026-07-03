# Clock architecture

## Sources
| Clock | Origin | Ball | Notes |
|---|---|---|---|
| clk_7m  | Motherboard 7M via 74LVC1G17 + 33R | C7 (PCLKT0_1) | 7.09379 MHz PAL / 7.15909 MHz NTSC |
| clk_12x | ICS570B CLK output via 33R | L1 (PCLKT6_1) | 85.13 / 85.91 MHz |
| clk_25m | On-module oscillator | P6 (GPLL0 dedicated input) | Always present |

## ICS570B configuration (Base64 revC)
S0/S1 float (mid level). FBIN is driven from the **CLK/2** output through
33R, so the zero-delay feedback loop closes on the divide-by-2 node:
CLK = 12x input, CLK/2 = 6x input, both phase-aligned to the 7M input.
The ECP5 PLL cannot lock below 8 MHz, which is why the external multiplier
exists at all; 85 MHz is a valid EHXPLLL reference if other frequencies
(e.g. a faster SDRAM clock) are ever needed.

## Domains
Single master domain: everything runs on clk_12x. Because it is
phase-locked to the bus, 7M is treated as *data*, not as a clock: it is
2FF-synchronized and its rising edge reloads the divide-by-12 phase
counter (PHASE_OFS trims alignment — tune on hardware against E/C1/C3).

- Compatibility mode: enPhi1 @ count 0, enPhi2 @ count 6 -> 7.09 MHz effective.
- Turbo mode (later): enables alternate every clock -> 42.5 MHz effective,
  external cycles re-timed onto 7M phases by the bus bridge.
- Fallback if 85 MHz misses timing: enables every other clock -> 21.3 MHz.
