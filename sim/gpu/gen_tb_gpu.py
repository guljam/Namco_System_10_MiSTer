#!/usr/bin/env python3
"""Generate sim/gpu/tb_gpu.vhd: GPU-only replay bench (rtl/gpu.vhd + DDR3 VRAM model).

Feeds a GP0 word stream (gp0.txt in the run directory, one hex word per line, '#' comments)
through the DMA channel-2 interface and reports how long the GPU takes to draw it.
"""
import os, re
HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "..", "rtl")
src = open(os.path.join(RTL, "gpu.vhd"), encoding="latin-1").read()
ent = src[src.index("entity gpu is"):src.index("end entity", src.index("entity gpu is"))]
ports = []
for m in re.finditer(r"^\s+([A-Za-z0-9_]+)\s*:\s*(in|out|buffer|inout)\s+([^;:=]+?)(?:\s*:=[^;]*)?;?\s*(?:--.*)?$", ent[ent.index("port"):], re.M):
    ports.append((m.group(1), m.group(2), m.group(3).strip()))
CONN = {
    "clk1x": "clk1x", "clk2x": "clk2x", "clk2xIndex": "clk2xIndex", "clkvid": "clkvid", "ce": "'1'", "reset": "reset",
    "videoout_on": "'1'", "DMA_GPU_writeEna": "dma_we", "DMA_GPU_write": "dma_word", "gpu_dmaRequest": "dma_req",
    "dmaOn": "dma_on", "DMA_GPU_waiting": "dma_on",
    "vram_BUSY": "DDRAM_BUSY", "vram_DOUT": "DDRAM_DOUT", "vram_DOUT_READY": "DDRAM_DOUT_READY",
    "vram_BURSTCNT": "DDRAM_BURSTCNT", "vram_ADDR": "vram_ADDR", "vram_DIN": "DDRAM_DIN", "vram_BE": "DDRAM_BE",
    "vram_WE": "DDRAM_WE", "vram_RD": "DDRAM_RD", "gpustat_out": "gpustat", "bus_addr": "bus_addr",
    "bus_dataWrite": "bus_dw", "bus_write": "bus_wr", "bus_read": "bus_rd", "bus_dataRead": "bus_dr", "bus_stall": "bus_stall",
}
def tie(t):
    t = t.lower()
    if t.startswith(("std_logic_vector", "unsigned", "signed")): return "(others => '0')"
    if t.startswith(("integer", "natural")): return "0"
    return "'0'"
pm = []
for n, d, t in ports:
    if n in CONN: pm.append(f"         {n:24s} => {CONN[n]}")
    elif d == "in": pm.append(f"         {n:24s} => {tie(t)}")
    else: pm.append(f"         {n:24s} => open")
tb = open(os.path.join(HERE, "tb_gpu.template.vhd")).read().replace("@@GPU_PORTMAP@@", ",\n".join(pm))
open(os.path.join(HERE, "tb_gpu.vhd"), "w", newline="\n").write(tb)
print("wrote tb_gpu.vhd with", len(pm), "gpu ports")
