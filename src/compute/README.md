# Compute core GEMM programming model

The physical systolic array is 8x8. Software controls the active tile and K
walk with these registers:

```text
0xf000_0080  GEMM M (1..8)
0xf000_0084  GEMM N (1..8)
0xf000_0088  GEMM K
0xf000_008c  bit 0 clear accumulator, bit 1 finalize/drain
0xf000_0000  command value 2 launches GEMM
```

For multiple K tiles, launch the first tile with `clear=1, finalize=0`, middle
tiles with `clear=0, finalize=0`, and the last tile with
`clear=0, finalize=1`. Only the final launch drains the accumulated result to
C. A standalone operation uses `clear=1, finalize=1`.

## A/B GEMM layout

A uses one bank per active output row:

```text
A bank = m within the tile
A address = A_BASE + k / 8
A byte lane = k % 8
```

B distributes K across banks and packs output columns into each word:

```text
B bank = k % 8
B address = B_BASE + k / 8
B byte lane = n within the tile
```

The launcher pre-issues synchronous BRAM addresses, so crossing K=8, 16, ...
does not insert a MAC bubble.

## Resident matrix capacity

With the default `ADDR_WIDTH=9`, `DATA_WIDTH=64`, and eight banks, every A, B,
or C memory contains:

```text
8 banks x 512 words/bank x 8 bytes/word = 32 KiB
```

For one launcher tile at base address zero:

- A maximum shape: 8 x 4096 INT8 elements
- B maximum shape: 4096 x 8 INT8 elements
- common maximum K: 4096

Nonzero bases reduce the maximum K:

```text
Kmax = min(8 * (512 - A_BASE), 8 * (512 - B_BASE))
```

Multiple M/N tiles can coexist in A/B at different base offsets. For a given
K, each tile consumes `ceil(K/8)` addresses per bank:

```text
resident A rows    <= 8 * floor(512 / ceil(K/8))
resident B columns <= 8 * floor(512 / ceil(K/8))
```

C has 4096 physical 64-bit words. Compute drain currently writes one result
byte into the low byte of each word, so it holds 4096 computed output elements
despite occupying 32 KiB. With padded 8x8 tile allocation, C holds 64 full
tiles; the largest square fully resident result is 64x64. Equivalently, one
column tile can use up to 512x8 results. Software selects each tile's storage
region with `C_BASE`.

The accumulator remains 16 bits and the final C value remains 8 bits after
post-processing. The address capacity above does not imply numerical safety
for K=4096: overflow/quantization must be considered separately.
