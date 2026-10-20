#!/usr/bin/env python3
"""Generate sim/system/tb_s12.vhd: full-system NVC testbench (psx_mister + s12_ch3 + s12_sub).

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
    "reset": "psx_reset_m", "pause": "'0'", "hps_busy": "'0'", "fastboot": "'0'", "ram8mb": "'1'",
    "TURBO_MEM": "TURBO", "TURBO_COMP": "TURBO", "TURBO_CACHE": "TCACHE", "interlaced480pHack": "HACK480", "TURBO_CACHE50": "TC50",
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
    "zn_system11": "'1'", "zn_platform": '"0000"', "zn_dsw": 'x"FF"',
    "s12_sh_addr": "sh_addr", "s12_sh_wdata": "sh_wdata", "s12_sh_be": "sh_be", "s12_sh_we": "sh_we",
    "s12_sh_rdata": "sh_rdata", "s12_rdma_start": "rdma_start", "s12_rdma_src": "rdma_src",
    "s12_rdma_valid": "rdma_valid", "s12_rdma_pop": "rdma_pop", "s12_rdma_data": "rdma_data",
    "savestate_number": "0", "SPUon": "'1'",
    "ee_dl_wr": "tb_ee_wr", "ee_dl_addr": "tb_ee_addr", "ee_dl_data": "tb_ee_data",
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

tb = open(os.path.join(HERE, "tb_s12.template.vhd")).read().replace("@@PSX_PORTMAP@@", portmap)
open(os.path.join(HERE, "tb_s12.vhd"), "w").write(tb)
print("wrote tb_s12.vhd with", len(pm), "psx_mister ports")
