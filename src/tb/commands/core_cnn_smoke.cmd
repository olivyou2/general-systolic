# 3x3, one-channel input; 2x2 all-one kernel; output tile is 2x2.
# The input is broadcast to all A banks so the launcher can read eight
# output positions in parallel.  The four valid output rows are followed by
# four zero rows in the 8x8 array.

WRITE f0000040 0000000000000001   # cnn_input_broadcast = 1
WRITE f0000044 0000000000000000   # input base
WRITE f0000048 0000000000000000   # weight base
WRITE f000004c 0000000000000003   # input width = 3
WRITE f0000050 0000000000000003   # input height = 3
WRITE f0000054 0000000000000001   # input channels = 1
WRITE f0000058 0000000000000202   # kernel width=2, height=2
WRITE f000005c 0000000000010001   # stride x=1, y=1
WRITE f0000060 0000000000000000   # pad left/right = 0
WRITE f0000064 0000000000000000   # pad top/bottom = 0
WRITE f0000068 0000000000000000   # output origin x/y = 0
WRITE f000006c 0000000000000002   # output tile width = 2

# CHW input bytes 1..9, packed little-endian by eight values per word.
WRITE 00000000 0807060504030201
WRITE 00000001 0000000000000009

# Four K rows, one B bank per row; every output-channel lane is one.
WRITE 10000000 0101010101010101
WRITE 10000200 0101010101010101
WRITE 10000400 0101010101010101
WRITE 10000600 0101010101010101

WRITE f0000000 0000000000000003   # CNN launch
WAIT 20
EXPECT_NONE 4                     # no device output before DMA

# Explicit C -> device DMA.  C stores eight rows, packed across banks.
WRITE f0000020 0000000000000000   # destination = external
WRITE f0000024 0000000000000000   # C source base
WRITE f000002c 0000000000000008   # eight result rows
WRITE f0000000 0000000000000001   # DMA start
READY 0                           # hold the first DMA word
WAIT 10
READY 1

EXPECT 0c0c0c0c0c0c0c0c
EXPECT 1010101010101010
EXPECT 1818181818181818
EXPECT 1c1c1c1c1c1c1c1c
EXPECT 0000000000000000
EXPECT 0000000000000000
EXPECT 0000000000000000
EXPECT 0000000000000000
END
