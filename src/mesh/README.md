# 16x16 two-channel torus mesh

`torus_mesh` is a parameterized ready/valid network. Its defaults are:

- 16 columns by 16 rows
- 40-bit address and 64-bit data
- two independent channels on every west/east and north/south link
- west/north receive, east/south transmit
- east and south wrap-around links

## Address and routing

For the default 16x16 configuration, the address fields are:

```text
39          36 35          32 31                         0
+--------------+--------------+----------------------------+
| destination X| destination Y| endpoint address / tag     |
+--------------+--------------+----------------------------+
```

Routing is deterministic X-then-Y. A packet travels east until its X
coordinate matches, then south until its Y coordinate matches, then exits at
the local port.

## Compile-time endpoint mask

`NODE_ENABLE_MASK[y * MESH_X + x]` controls whether a coordinate has a local
endpoint. This is a parameter, not a runtime signal, so a disabled node's local
input buffer and local delivery path are removed during elaboration/synthesis.
The transit path remains because every coordinate is required for torus
routing. A packet addressed directly to a disabled endpoint is discarded.

## Integration test

From the repository root:

```bash
verilator --binary --timing -j 0 \
  src/mesh/mesh_elastic_buffer.sv \
  src/mesh/torus_mesh_router.sv \
  src/mesh/torus_mesh.sv \
  src/tb/torus_mesh_tb.sv \
  --top-module torus_mesh_tb

./obj_dir/Vtorus_mesh_tb
```

The test instantiates the full 16x16 topology with a sparse endpoint mask and
checks disabled-node transit, two-channel concurrency, X/Y wrap-around,
backpressure stability, disabled-destination dropping, and west/north
contention.

## Standalone global scratchpad module

`global_scratchpad` is a standalone router endpoint, like a compute module. It
connects directly to one router's local input/output ready-valid ports; the
mesh itself does not instantiate scratchpad storage.

`CAPACITY_BYTES` controls capacity. The module derives its BRAM depth and
address width automatically. Capacity must contain a power-of-two number of
whole data words. Examples for the default 64-bit data width are:

| `CAPACITY_BYTES` | Words | Approximate RAMB36 count |
|---:|---:|---:|
| 4096 | 512 | 1 |
| 8192 | 1024 | 2 |
| 16384 | 2048 | 4 |

Channel 0 receives direct writes, reads, and DMA configuration packets. The
internal DMA also injects destination writes on channel 0. Channel 1 injects
direct-read responses. Address opcodes in the local 32-bit address are:

```text
0x0...  direct scratchpad word write
0x1...  direct scratchpad word read
0x2...  read response
0xf...  DMA control write
```

For the default 16x16 mesh, a read request uses:

```text
39:36  scratchpad destination X
35:32  scratchpad destination Y
31:28  opcode = 1
27:24  response destination X
23:20  response destination Y
19:0   tag and scratchpad word address
```

### Internal DMA registers

DMA is configured by channel 0 control writes:

```text
0xf000_0008  source scratchpad word address
0xf000_0010  transfer length in 64-bit words
0xf000_0018  40-bit destination mesh base address
0xf000_0020  destination address stride
0xf000_0000  command; data bit 0 starts DMA
```

The destination is a complete mesh address. To transfer to another
scratchpad, use that node's coordinates and opcode 0 in the destination base.
To transfer to a compute unit, use the compute node's coordinates and its
32-bit A/B/C destination address. Therefore the DMA datapath does not need a
hard-coded destination type.

The focused scratchpad integration test is:

```bash
verilator --binary --timing -j 0 \
  src/mesh/mesh_elastic_buffer.sv \
  src/mesh/torus_mesh_router.sv \
  src/mesh/torus_mesh.sv \
  src/mesh/global_scratchpad.sv \
  src/tb/torus_mesh_scratchpad_tb.sv \
  --top-module torus_mesh_scratchpad_tb

./obj_dir/Vtorus_mesh_scratchpad_tb
```

## AXI4 Full slave bridge

`axi4_mesh_bridge` is a synthesizable AXI4 Full slave endpoint. Its ports use
the standard `s_axi_*` names and Xilinx `X_INTERFACE_INFO` metadata so Vivado
IP packaging and block design can identify the `S_AXI` interface and its
associated clock/reset.

For the default 16x16 mesh, an AXI write address maps directly to:

```text
39:36  mesh destination X
35:32  mesh destination Y
31:0   target endpoint address
```

AXI writes are posted. `BRESP=OKAY` means every write beat was accepted into
the source router, not that the remote endpoint has completed the operation.
Consequently a scratchpad direct write address or a compute command/register
address can be issued through the same AXI slave.

AXI reads are converted automatically to the scratchpad read-request format.
The bridge inserts its `X_COORD` and `Y_COORD` as the response destination and
waits for the returning channel-1 packet before asserting `RVALID`.

Current AXI behavior is deliberately bounded and deterministic:

- 64-bit full-width transfers (`AxSIZE=3`)
- FIXED and INCR bursts
- up to 256 beats (`AxLEN`)
- one transaction outstanding; read and write transactions are serialized
- all write strobes must be asserted
- WRAP, narrow, or partial-strobe transactions return `SLVERR`
- `MESH_ADDR_STRIDE`, default 1, controls the mesh address increment per beat
- AXI reads target the scratchpad response protocol; compute-node reads need a
  compatible addressed response before they can use this read path

The focused AXI/mesh test performs a two-beat scratchpad write/read burst,
stalls the AXI R channel to check stability, and sends a compute command with a
single AXI write:

```bash
verilator --binary --timing -j 0 \
  src/mesh/mesh_elastic_buffer.sv \
  src/mesh/torus_mesh_router.sv \
  src/mesh/torus_mesh.sv \
  src/mesh/global_scratchpad.sv \
  src/mesh/axi4_mesh_bridge.sv \
  src/tb/axi4_mesh_bridge_tb.sv \
  --top-module axi4_mesh_bridge_tb

./obj_dir/Vaxi4_mesh_bridge_tb
```
