# GEMM unit RTL

The GEMM unit is a deterministic, compiler-scheduled streaming pipeline.

## Files

- `gemm_unit.sv`: configuration registers, tile scheduler, and top-level wiring
- `banked_tile_scratchpad.sv`: lane-banked A/B tile storage and readiness tracking
- `tile_address_generator.sv`: programmable base/element/tile address generation
- `output_stationary_systolic_array.sv`: globally stallable INT8 outer-product array with INT32 accumulators
- `stream_fifo.sv`: registered-occupancy ready/valid FIFO
- `vector_engine.sv`: scalar bias, ReLU, shift, and saturation pipeline
- `output_scratchpad.sv`: vector storage and streaming output interface

## GEMM configuration registers

| Address | Function |
| --- | --- |
| `0x0000` | Control: bit 0 enable, bit 1 start job, bit 2 systolic stall |
| `0x0001` | A stream write slot |
| `0x0002` | B stream write slot |
| `0x0003` | A job base word address |
| `0x0004` | B job base word address |
| `0x0005` | A tile stride in words; zero reuses the tile |
| `0x0006` | B tile stride in words; zero reuses the tile |
| `0x0007` | Number of output tiles in the job |
| `0x0008` | Release A tile slot |
| `0x0009` | Release B tile slot |
| `0x0010` | Vector control: bit 0 bias, bit 1 ReLU, bits 13:8 shift |
| `0x0011` | Signed scalar vector bias |
| `0x0020+n` | Loop level `n` count |
| `0x0040+n` | A address stride for loop level `n` |
| `0x0060+n` | B address stride for loop level `n` |

The compiler may submit a job before its operand tiles arrive. The scheduler
waits for both addressed tile-ready bits and launches as soon as the minimum
complete `K_CHUNK` is resident. Tile data remains valid until an explicit
release register write, allowing a zero tile stride to reuse A or B data.
The default six-level loop nest lets the compiler express GEMM and implicit-CNN
reuse: a zero A or B stride retains that operand across the corresponding loop.
