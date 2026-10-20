// Bench for rtl/s10_crypt_t1.sv / rtl/s10_crypt_t2.sv.
// Streams a vector file written by capture.py (vec_<game>.hex) through the DUT:
//   op 1 = activate(iv), op 2 = deactivate, op 0 = word (cipher -> expected plain from MAME).
// Every 1000th word is preceded by an idle cycle (word_valid = 0, garbage cipher) to check that
// the state only advances on word_valid.
// Plusargs: +VEC=<file>  +PARAMS=<file> (type 2 only, written by capture.py / gen_params.py)
// Parameter TYPE = 1 or 2.
`timescale 1ns/1ps
module tb_crypt;
parameter TYPE = 1;

reg clk = 1'b0;
reg reset = 1'b1;
reg activate = 1'b0;
reg deactivate = 1'b0;
reg [3:0] iv = 4'd0;
reg word_valid = 1'b0;
reg [15:0] cipher = 16'd0;
wire [15:0] plain;
wire active;

reg [1023:0] prm [0:8];

generate
if (TYPE == 1) begin : g_t1
    s10_crypt_t1 dut (
        .clk(clk), .reset(reset), .activate(activate), .iv(iv), .deactivate(deactivate),
        .word_valid(word_valid), .cipher(cipher), .plain(plain), .active(active));
end else begin : g_t2
    s10_crypt_t2 dut (
        .clk(clk), .reset(reset),
        .emask(prm[0]), .dmask(prm[1]), .xmask(prm[2][15:0]), .ivtab(prm[3]),
        .nl_ac(prm[4][63:0]), .nl_ap(prm[5][63:0]), .nl_bc(prm[6][63:0]), .nl_bp(prm[7][63:0]),
        .nl_out(prm[8][15:0]),
        .activate(activate), .iv(iv), .deactivate(deactivate),
        .word_valid(word_valid), .cipher(cipher), .plain(plain), .active(active));
end
endgenerate

always #5 clk = ~clk;

integer fd, r, n, i, words, pass, fail, acts, idles;
reg [35:0] v;
reg [1023:0] vecname, prmname;

initial begin
    if (!$value$plusargs("VEC=%s", vecname)) begin
        $display("ERROR: +VEC=<file> missing"); $finish;
    end
    if (TYPE == 2) begin
        if (!$value$plusargs("PARAMS=%s", prmname)) begin
            $display("ERROR: +PARAMS=<file> missing"); $finish;
        end
        $readmemh(prmname, prm);
    end
    fd = $fopen(vecname, "r");
    if (fd == 0) begin
        $display("ERROR: cannot open vector file"); $finish;
    end
    r = $fscanf(fd, "%h\n", v);
    n = v[31:0];
    words = 0; pass = 0; fail = 0; acts = 0; idles = 0;
    @(negedge clk); @(negedge clk);
    reset = 1'b0;
    for (i = 0; i < n; i = i + 1) begin
        r = $fscanf(fd, "%h\n", v);
        activate = 1'b0; deactivate = 1'b0; word_valid = 1'b0;
        if (v[35:32] == 4'd1) begin
            activate = 1'b1; iv = v[3:0]; acts = acts + 1;
            @(negedge clk);
        end else if (v[35:32] == 4'd2) begin
            deactivate = 1'b1;
            @(negedge clk);
        end else begin
            if ((words % 1000) == 999) begin
                cipher = 16'hDEAD ^ words[15:0];
                idles = idles + 1;
                @(negedge clk);
            end
            word_valid = 1'b1;
            cipher = v[31:16];
            #1;
            if (!active) begin
                fail = fail + 1;
                if (fail <= 10) $display("FAIL word %0d: decrypter not active", words);
            end else if (plain !== v[15:0]) begin
                fail = fail + 1;
                if (fail <= 10) $display("FAIL word %0d: cipher %04h plain %04h expected %04h",
                                         words, v[31:16], plain, v[15:0]);
            end else
                pass = pass + 1;
            words = words + 1;
            @(negedge clk);
        end
    end
    activate = 1'b0; deactivate = 1'b0; word_valid = 1'b0;
    @(negedge clk);
    $fclose(fd);
    $display("RESULT TYPE%0d %0s: activations %0d, words %0d, pass %0d, fail %0d, idle cycles %0d -> %0s",
             TYPE, vecname, acts, words, pass, fail, idles, (fail == 0 && words > 0) ? "PASS" : "FAIL");
    $finish;
end
endmodule
