#!/usr/bin/env python3
"""Generate sim/system/tb_s10.vhd: full-system NVC testbench (psx_mister + System 10 board).

The psx_mister port list is parsed from rtl/psx_mister.vhd so the testbench follows RTL changes;
ports not listed in CONN are tied to zero (inputs) or left open (outputs).
"""
import os, re

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "..", "rtl")

src = open(os.path.join(RTL, "psx_mister.vhd"), encoding="latin-1").read()
ent = src[src.index("entity psx_mister is"):src.index("end entity", src.index("entity psx_mister is"))]
ports = []
for m in re.finditer(r"^\s+([A-Za-z0-9_]+)\s*:\s*(in|out|buffer|inout)\s+([^;:=]+?)(?:\s*:=[^;]*)?;?\s*(?:--.*)?$", ent[ent.index("port"):], re.M):
    ports.append((m.group(1), m.group(2), m.group(3).strip()))

CONN = {
    "clk1x": "clk1x", "clk2x": "clk2x", "clk3x": "clk3x", "clkvid": "clkvid",
    "reset": "psx_reset", "pause": "'0'", "hps_busy": "'0'", "fastboot": "'0'", "ram8mb": "'1'",
    "TURBO_MEM": "'1'", "TURBO_COMP": "'1'", "TURBO_CACHE": "'1'", "TURBO_CACHE50": "'1'", "interlaced480pHack": "'0'",
    "biosregion": '"01"', "region": '"01"', "videoout_on": "'1'",
    "ram_refresh": "ram_refresh", "ram_dataWrite": "ram_dataWrite", "ram_dataRead32": "ram_dataRead32",
    "ram_Adr": "ram_Adr", "ram_cntDMA": "ram_cntDMA", "ram_be": "ram_be", "ram_rnw": "ram_rnw",
    "ram_ena": "ram_ena", "ram_dma": "ram_dma", "ram_cache": "ram_iscache", "ram_done": "ram_done",
    "ram_dmafifo_adr": "ram_dmafifo_adr", "ram_dmafifo_data": "ram_dmafifo_data",
    "ram_dmafifo_empty": "ram_dmafifo_empty", "ram_dmafifo_read": "ram_dmafifo_read",
    "cache_wr": "cache_wr", "cache_data": "cache_data", "cache_addr": "cache_addr",
    "dma_wr": "dma_wr", "dma_reqprocessed": "dma_reqprocessed", "dma_data": "dma_data",
    "DDRAM_BUSY": "DDRAM_BUSY", "DDRAM_BURSTCNT": "DDRAM_BURSTCNT", "DDRAM_ADDR": "DDRAM_ADDR",
    "DDRAM_DOUT": "DDRAM_DOUT", "DDRAM_DOUT_READY": "DDRAM_DOUT_READY", "DDRAM_RD": "DDRAM_RD",
    "DDRAM_DIN": "DDRAM_DIN", "DDRAM_BE": "DDRAM_BE", "DDRAM_WE": "DDRAM_WE",
    "spuram_dataRead": "(others => '0')", "spuram_done": "'0'",
    "hsync": "hsync", "vsync": "vsync", "hblank": "hblank", "vblank": "vblank",
    "video_ce": "video_ce", "video_interlace": "video_interlace",
    "video_r": "video_r", "video_g": "video_g", "video_b": "video_b",
    "sound_out_left": "audio_l", "sound_out_right": "audio_r",
    "zn_system11": "'1'", "zn_platform": '"0000"', "zn_dsw": 'x"FF"',
    "s10_addr": "s10_addr", "s10_wdata": "s10_wdata", "s10_wmask": "s10_wmask", "s10_size": "s10_size",
    "s10_rd": "s10_rd", "s10_wr": "s10_wr", "s10_rdata": "s10_rdata", "s10_stall": "s10_stall",
    "s10_irq10": "s10_irq10", "s10_exio": "s10_exio_on", "s10_ddr_request": "s10_ddr_request", "s10_ddr_ack": "s10_ddr_ack",
    "s10_ddr_burstcnt": "s10_ddr_burstcnt", "s10_ddr_addr": "s10_ddr_addr", "s10_ddr_din": "s10_ddr_din",
    "s10_ddr_be": "s10_ddr_be", "s10_ddr_we": "s10_ddr_we", "s10_ddr_rd": "s10_ddr_rd",
    "s12_rdma_start": "rdma_start", "s12_rdma_valid": "rdma_valid", "s12_rdma_pop": "rdma_pop", "s12_rdma_want": "rdma_want",
    "s12_rdma_data": "rdma_data",
    "savestate_number": "0", "SPUon": "'1'",
}

def tie(typ):
    t = typ.lower()
    if t.startswith("std_logic_vector") or t.startswith("unsigned") or t.startswith("signed"):
        return "(others => '0')"
    if t.startswith("integer") or t.startswith("natural"):
        return "0"
    if "joypad" in t:
        return None
    return "'0'"

pm = []
for name, d, typ in ports:
    if name in CONN:
        pm.append(f"         {name:24s} => {CONN[name]}")
    elif d == "in":
        v = tie(typ)
        if v is not None:
            pm.append(f"         {name:24s} => {v}")
    else:
        pm.append(f"         {name:24s} => open")
portmap = ",\n".join(pm)

tb = open(os.path.join(HERE, "tb_s10.template.vhd")).read().replace("@@PSX_PORTMAP@@", portmap)
open(os.path.join(HERE, "tb_s10.vhd"), "w").write(tb)
print("wrote tb_s10.vhd with", len(pm), "psx_mister ports")
