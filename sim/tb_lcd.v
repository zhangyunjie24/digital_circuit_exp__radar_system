`timescale 1us/1ns
// tb_lcd —— lcd_ctrl 测试台（按角度维护的距离表：37 格 × 16 级，每格画成一段短弧）
//
// 用一个 ST7565 行为模型接住 8080 写操作（WR 上升沿采样）：解析页/列地址命令，维护 8 页 × 132 列的显存。
// 测试台里另维护一份"期望的距离表"，用和 lcd_ctrl 逐比特相同的整数运算（同一张 sin 表、同样的累加取整）
// 算出期望画面（基线 + 刻度 + 表里每一格的短弧），**每次测距后都和显存逐字节比对**：
// 多一个像素（残留的旧弧）或少一个像素都会被抓到。
//
// 自动检查：
//   1. 初始化命令序列与参考程序一致；/RES 先低后高；写时序（CS、WR 脉宽）
//   2. 自检阶段 LCD 保持空白（不发 A5 全屏点亮）
//   3. 待机：整屏 = 基线 + 0.2/0.4/1/2/4m 刻度
//   4. CONT 去程（1.5m 墙 + 箱子 + 近物体）：每次测距后整屏都与期望完全一致
//   5. 回程（箱子挪走）：旧点被替换掉，不残留；整屏一致
//   6. 超量程 / 无回波：画在最外沿（半径 51）；3.9m 画在 4m 刻度处
//   7. 伪随机距离连扫两个来回（弧挤在一起、同字节多弧）：每次整屏一致（不残留、不丢）
//   8. STEP：45°/90°/135° 落到 48°/90°/138° 三格
//   9. restart：清屏、表清空
module tb_lcd;

reg clk = 0;
always #0.5 clk = ~clk;

reg rst = 1;
reg tick_1ms = 0;
integer us = 0;
always@(posedge clk) begin
	us = us + 1;
	tick_1ms <= (us % 1000 == 0);
end

reg blink_2hz = 0;
reg [1:0] phase = 0;
reg mode_cont = 0, restart = 0;
reg r_strobe = 0, r_valid = 0, r_oor = 0;
reg [11:0] r_angle_bcd = 0;
reg [15:0] r_dist_bcd = 0;
reg [7:0] angle_deg = 0;

wire [7:0] lcd_d;
wire lcd_cs_n, lcd_a0, lcd_wr_n, lcd_rd_n, lcd_rst_n;

lcd_ctrl dut(
	.clk(clk), .rst(rst), .tick_1ms(tick_1ms), .blink_2hz(blink_2hz),
	.phase(phase), .mode_cont(mode_cont), .restart(restart),
	.r_strobe(r_strobe), .r_angle_bcd(r_angle_bcd), .r_dist_bcd(r_dist_bcd),
	.r_valid(r_valid), .r_oor(r_oor), .angle_deg(angle_deg),
	.lcd_d(lcd_d), .lcd_cs_n(lcd_cs_n), .lcd_a0(lcd_a0), .lcd_wr_n(lcd_wr_n),
	.lcd_rd_n(lcd_rd_n), .lcd_rst_n(lcd_rst_n));

integer errors = 0;

// ================= ST7565 模型 =================
reg [7:0] ram [0:7][0:131];
integer m_pg = 0, m_cl = 0;
integer n_cmd = 0;
reg [7:0] cmds [0:63];			// 记录前 64 条命令
reg allon = 0;
integer n_a5 = 0, n_a4 = 0;
reg vol_next = 0;				// 0x81 之后一字节是对比度值，不是命令

integer i, j;
initial begin
	for (i = 0; i < 8; i = i + 1)
		for (j = 0; j < 132; j = j + 1)
			ram[i][j] = 8'hFF;	// 上电内容随机，填满方便看出是否清过
end

always@(posedge lcd_wr_n) begin
	if (rst) ;					// 第 0 时刻 x→1 也算一个上升沿，不是写操作
	else if (lcd_cs_n !== 1'b0) begin
		$display("  [FAIL] WR 上升沿时 CS 不是低"); errors = errors + 1;
	end
	else if (lcd_a0) begin
		ram[m_pg][m_cl] = lcd_d;
		m_cl = (m_cl == 131) ? 0 : m_cl + 1;
	end
	else begin
		if (n_cmd < 64) cmds[n_cmd] = lcd_d;
		n_cmd = n_cmd + 1;
		if (vol_next)                   vol_next = 0;
		else if (lcd_d == 8'h81)        vol_next = 1;
		else if (lcd_d[7:4] == 4'hB)    m_pg = lcd_d[3:0];
		else if (lcd_d[7:4] == 4'h1)    m_cl = {lcd_d[3:0], m_cl[3:0]};
		else if (lcd_d[7:4] == 4'h0)    m_cl = {m_cl[7:4], lcd_d[3:0]};
		else if (lcd_d == 8'hA5) begin allon = 1; n_a5 = n_a5 + 1; end
		else if (lcd_d == 8'hA4) begin allon = 0; n_a4 = n_a4 + 1; end
	end
end

// WR 低脉宽
realtime t_wr_fall;
always@(negedge lcd_wr_n) t_wr_fall = $realtime;
always@(posedge lcd_wr_n) if (!rst && $realtime - t_wr_fall < 0.99) begin
	$display("  [FAIL] WR 低脉宽 %0.2fµs", $realtime - t_wr_fall); errors = errors + 1;
end

function pix;					// 显存里 (col,row) 是否点亮
	input integer c, r;
	begin
		pix = (c < 0 || c > 127 || r < 0 || r > 63) ? 0 : ram[r / 8][c][r % 8];
	end
endfunction

task dump;						// ASCII 打印整屏（每 2 列合成 1 个字符，64 字宽）
	integer c, r;
	reg [8*64:1] line;
	begin
		for (r = 8; r < 64; r = r + 1) begin
			line = "";
			for (c = 0; c < 128; c = c + 2)
				line = {line[8*63:1], (pix(c, r) || pix(c + 1, r)) ? "#" : "."};
			$display("    |%s|", line);
		end
	end
endtask

// ================= 期望画面（和 lcd_ctrl 逐比特相同的算法）=================
integer SIN [0:18];
initial begin
	SIN[0] = 0;
	SIN[1] = 11;
	SIN[2] = 22;
	SIN[3] = 33;
	SIN[4] = 44;
	SIN[5] = 54;
	SIN[6] = 64;
	SIN[7] = 73;
	SIN[8] = 82;
	SIN[9] = 91;
	SIN[10] = 98;
	SIN[11] = 105;
	SIN[12] = 111;
	SIN[13] = 116;
	SIN[14] = 120;
	SIN[15] = 124;
	SIN[16] = 126;
	SIN[17] = 128;
	SIN[18] = 128;
end

integer exp_lvl [0:36];			// 期望的距离表
reg [7:0] exp_ram [0:7][0:127];

function integer meas_lvl;		// 距离 → 距离级（与 lcd_ctrl 相同）；<0 表示超量程
	input integer mm;
	integer d3, d2, d1, r;
	begin
		if (mm < 0) meas_lvl = 0;
		else begin
			d3 = mm / 1000 % 10; d2 = mm / 100 % 10; d1 = mm / 10 % 10;
			r = (d3 == 2 ? 50 : d3 == 1 ? 25 : 0) + d2 * 2 + d2 / 2 + d1 / 4;
			meas_lvl = ((mm < 400) ? (mm / 40) : (mm < 1200) ? (10 + (mm - 400) / 100) : (18 + (mm - 1200) / 400)) + 1;
		end
	end
endfunction

function [4:0] lab;			// 刻度数字（3×5 点阵，与 lcd_ctrl 相同的字形和位置）
	input integer c;
	begin
		case (c)
			96: lab = 5'h12; 97: lab = 5'h1F; 98: lab = 5'h10;
			104: lab = 5'h1D; 105: lab = 5'h15; 106: lab = 5'h17;
			112: lab = 5'h07; 113: lab = 5'h04; 114: lab = 5'h1F;
			default: lab = 5'h00;
		endcase
	end
endfunction

task build_exp;					// 由期望距离表生成期望画面（每格一段 9 点短弧，算法与 lcd_ctrl 逐比特相同）
	integer p, c, kk, rr, fold, wx, wy, ex, ey, ax, ay, n, AX, AY, col, row, left;
	begin
		for (p = 0; p < 8; p = p + 1)
			for (c = 0; c < 128; c = c + 1)
				exp_ram[p][c] = (p != 7) ? 8'h00 :
				                (c == 13 || c == 23 || c == 31 || c == 43 || c == 53 || c == 74 || c == 84 || c == 96 || c == 104 || c == 114) ? (8'hE0 | lab(c)) : (8'h80 | lab(c));
		for (kk = 0; kk <= 36; kk = kk + 1)
			if (exp_lvl[kk] != 0) begin
				rr   = (exp_lvl[kk] - 1) * 2 + 1;
				left = (kk > 18);
				fold = left ? 36 - kk : kk;
				wx = 64 + rr * SIN[18 - fold];		// 7 位小数
				wy = 64 + rr * SIN[fold];
				ex = wy / 512;						// wy[12:9]
				ey = wx / 512;
				for (n = 0; n <= 6; n = n + 1) begin
					// 第 0 点 P；1~3 往一边（x-=ex, y+=ey）；4~6 往另一边（x+=ex, y-=ey）
					if (n <= 3) begin ax = wx / 8 - n * ex;       ay = wy / 8 + n * ey; end
					else        begin ax = wx / 8 + (n - 3) * ex; ay = wy / 8 - (n - 3) * ey; end
					AX = ax >>> 4;						// 带符号取整数部分（向下取整）
					AY = ay >>> 4;
					if (AY >= 0) begin
						col = left ? (63 - AX) : (64 + AX);
						col = col & 127;
						row = 63 - AY;
						exp_ram[row / 8][col] = exp_ram[row / 8][col] | (8'h01 << (row % 8));
					end
				end
			end
	end
endtask

integer n_cmp = 0, n_bad = 0;
task compare;					// 显存与期望画面逐字节比对
	input [8*32:1] when;
	integer p, c, bad;
	begin
		build_exp;
		bad = 0;
		for (p = 0; p < 8; p = p + 1)
			for (c = 0; c < 128; c = c + 1)
				if (ram[p][c] !== exp_ram[p][c]) begin
					if (bad < 3 && n_bad < 10)
						$display("  [FAIL] %0s：第 %0d 页第 %0d 列 = %h，期望 %h", when, p, c, ram[p][c], exp_ram[p][c]);
					bad = bad + 1;
				end
		n_cmp = n_cmp + 1;
		if (bad) begin n_bad = n_bad + 1; errors = errors + 1; end
	end
endtask

integer lit;
task count_lit;					// 扇形区（第 0~60 行）点亮的像素数，不含基线和刻度
	integer c, r;
	begin
		lit = 0;
		for (r = 0; r <= 60; r = r + 1)
			for (c = 0; c < 128; c = c + 1)
				if (pix(c, r)) lit = lit + 1;
	end
endtask

// ================= 场景 =================
// 前方 1.5m 处一面墙（距离 = 1500/sinθ），70°~100° 一个箱子（box mm），20°~40° 一个从 150mm 连续变到 190mm 的近物体
integer box = 250;
function integer prof;
	input integer a;
	real d;
	begin
		if (a >= 70 && a <= 100)     prof = box;
		else if (a >= 20 && a <= 40) prof = 150 + (a - 20) * 2;
		else if (a < 5 || a > 175)   prof = 4000;
		else begin
			d = 1500.0 / $sin(a * 3.14159265 / 180.0);
			prof = (d > 4000.0) ? 4000 : $rtoi(d);
		end
	end
endfunction

function [3:0] dig;				// 个位数字
	input integer v;
	begin dig = v % 10; end
endfunction

// ---- 送一次测量结果，并更新期望距离表；mm < 0 表示超量程 ----
task strobe;
	input integer ang;
	input integer mm;
	begin
		@(negedge clk);
		angle_deg   = ang;
		r_angle_bcd = {dig(ang / 100), dig(ang / 10), dig(ang)};
		r_valid     = 1;
		r_oor       = (mm < 0) || (mm >= 4000);
		r_dist_bcd  = (mm < 0) ? 0 : {dig(mm / 1000), dig(mm / 100), dig(mm / 10), dig(mm)};
		r_strobe    = 1;
		@(negedge clk);
		r_strobe    = 0;
		exp_lvl[(ang + 2) / 5] = r_oor ? 26 : meas_lvl(mm);
		#(80000);				// 等重画完（旧弧、新弧两个矩形，约 2×18 字节、每个约 1.3k 时钟）
	end
endtask

task clear_exp;
	integer kk;
	begin
		for (kk = 0; kk <= 36; kk = kk + 1) exp_lvl[kk] = 0;
	end
endtask

integer a, miss, k, pass, maxlit;
reg [7:0] want_init [0:14];

initial begin
	want_init[0] = 8'hE2; want_init[1] = 8'h2C; want_init[2] = 8'h2E; want_init[3] = 8'h2F;
	want_init[4] = 8'h24; want_init[5] = 8'h81; want_init[6] = 8'h1C; want_init[7] = 8'hA2;
	want_init[8] = 8'hC8; want_init[9] = 8'hA0; want_init[10] = 8'h40; want_init[11] = 8'hB0;
	want_init[12] = 8'h10; want_init[13] = 8'h00; want_init[14] = 8'hAF;
	clear_exp;

	#(10.3);
	if (lcd_rst_n !== 0) begin $display("  [FAIL] 复位时 /RES 应为低"); errors = errors + 1; end
	rst = 0;

	// ======================================================
	$display("==== 1. 初始化 + 自检（LCD 保持空白）====");
	phase = 0;
	for (k = 0; k < 8; k = k + 1) begin	// 自检 2 秒压缩成 8 × 50ms
		blink_2hz = ~blink_2hz;
		#(50000);
	end
	miss = 0;
	for (k = 0; k < 15; k = k + 1) if (cmds[k] !== want_init[k]) miss = miss + 1;
	if (miss) begin $display("  [FAIL] 初始化命令有 %0d 条不符", miss); errors = errors + 1; end
	else $display("  [ok]   初始化 15 条命令与 lcd_12864.vhd 一致，/RES 已释放=%b", lcd_rst_n);
	if (n_a5 != 0) begin
		$display("  [FAIL] 自检时发了 %0d 次 A5（全屏点亮）", n_a5); errors = errors + 1;
	end
	else $display("  [ok]   自检：LCD 不闪（没有 A5 全屏点亮命令）");

	// ======================================================
	$display("==== 2. 待机：整屏 = 基线 + 0.2/0.4/1/2/4m 刻度 ====");
	blink_2hz = 1;
	phase = 1;
	#(20000);
	k = n_bad;
	compare("待机");
	if (n_bad == k) $display("  [ok]   待机画面与期望一致");

	// ======================================================
	$display("==== 3. CONT 去程 0°→178°（1.5m 墙 + 250mm 箱子 + 近物体），每次测距后整屏比对 ====");
	phase = 2; mode_cont = 1;
	@(negedge clk); restart = 1; @(negedge clk); restart = 0;
	#(20000);
	clear_exp;
	k = n_bad;
	for (a = 0; a <= 178; a = a + 2) begin
		strobe(a, prof(a));
		compare("去程");
	end
	if (n_bad == k) $display("  [ok]   去程 90 次测距，每次整屏都与期望一致");
	count_lit;
	$display("         屏上 %0d 个像素（短弧，每格最多 9 个）", lit);

	$display("==== 4. 回程 180°→0°（箱子挪到 400mm）：旧点被替换 ====");
	box = 400;
	k = n_bad;
	for (a = 180; a >= 0; a = a - 2) begin
		strobe(a, prof(a));
		compare("回程");
	end
	if (n_bad == k) $display("  [ok]   回程 91 次测距，每次整屏都与期望一致（箱子原位置的旧点都已擦掉）");
	$display("  屏幕（每字符 = 2 列 × 1 行，第 1~7 页）：");
	dump;

	$display("==== 5. 超量程 / 无回波画在最外沿；3.9m 在 4m 刻度处 ====");
	k = n_bad;
	strobe(90, -1);
	compare("90° 超量程");
	strobe(84, 3900);
	compare("84° 3.9m");
	if (n_bad == k) $display("  [ok]   90° 超量程画在最外沿（半径 51）、84° 3.9m 画在 4m 刻度处，整屏一致");

	// ======================================================
	$display("==== 5b. 三段折线的分段边界：39/40、399/400、1199/1200、3999 毫米 ====");
	k = n_bad;
	strobe(10, 39);   compare("39mm");
	strobe(20, 40);   compare("40mm");
	strobe(30, 399);  compare("399mm");
	strobe(40, 400);  compare("400mm");
	strobe(50, 1199); compare("1199mm");
	strobe(60, 1200); compare("1200mm");
	strobe(70, 1599); compare("1599mm");
	strobe(80, 1600); compare("1600mm");
	strobe(100, 3999); compare("3999mm");
	if (n_bad == k) $display("  [ok]   各分段边界两侧整屏一致");

	// ======================================================
	$display("==== 6. 压力：伪随机距离 50~3990mm，连扫两个来回 ====");
	k = n_bad;
	maxlit = 0;
	for (pass = 0; pass < 2; pass = pass + 1) begin
		for (a = 0; a <= 180; a = a + 2) begin
			strobe(a, 50 + ((a * 37 + pass * 101) % 395) * 10);
			compare("随机去程");
			count_lit; if (lit > maxlit) maxlit = lit;
		end
		for (a = 178; a >= 2; a = a - 2) begin
			strobe(a, 50 + ((a * 53 + pass * 71) % 395) * 10);
			compare("随机回程");
			count_lit; if (lit > maxlit) maxlit = lit;
		end
	end
	if (n_bad == k) $display("  [ok]   随机距离 4 个单程共 %0d 次测距，每次整屏一致；屏上像素最多 %0d（≤37×7，不会越积越多）", 2 * 181, maxlit);
	if (maxlit > 37 * 7) begin $display("  [FAIL] 屏上像素 %0d > 259", maxlit); errors = errors + 1; end

	// ======================================================
	$display("==== 7. STEP：45°/90°/135° ====");
	mode_cont = 0;
	@(negedge clk); restart = 1; @(negedge clk); restart = 0;
	#(20000);
	clear_exp;
	k = n_bad;
	compare("restart 后");
	strobe(0, 600);
	strobe(45, 300);
	strobe(90, 1200);
	strobe(135, 2100);
	strobe(180, 900);
	compare("STEP");
	if (exp_lvl[9] == 0 || exp_lvl[18] == 0 || exp_lvl[27] == 0) begin
		$display("  [FAIL] 45°/90°/135° 应落在第 9/18/27 格（45°/90°/135°）"); errors = errors + 1;
	end
	if (n_bad == k) $display("  [ok]   STEP 5 个方向（5° 一格，45°/135° 正好落在格上）整屏一致");

	$display("==== 8. restart：清屏、表清空 ====");
	r_valid = 0;
	@(negedge clk); restart = 1; @(negedge clk); restart = 0;
	#(20000);
	clear_exp;
	k = n_bad;
	compare("restart");
	if (n_bad == k) $display("  [ok]   restart 后只剩基线和刻度");

	$display("");
	$display("         共比对 %0d 次整屏", n_cmp);
	if (errors == 0) $display("==== ALL PASS ====");
	else             $display("==== %0d ERROR(S) ====", errors);
	$finish;
end

endmodule
