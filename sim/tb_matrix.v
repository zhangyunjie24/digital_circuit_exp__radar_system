`timescale 1us/1ns
// tb_matrix —— 点阵三件套（dir_mem + matrix_ctrl + matrix_driver）自检测试台
//
// 检查方法：逐行统计一整行 1ms 内每一列红/绿通道点亮的时钟数，
// 换算回"红子槽数/绿子槽数"，和期望值比对。
// 期望值在本文件里按 design.md 的像素表独立写一遍，不引用 DUT 里的表。
module tb_matrix;

reg clk = 0;
always #0.5 clk = ~clk;		// 1MHz（timescale 1us → 半周期 0.5µs）

reg rst;
reg [1:0] phase;
reg blink_2hz;
reg [2:0] cur_dir;

reg clear, wr_en;
reg [2:0] wr_idx, wr_color;

wire [14:0] colors;
wire [2:0]  row_idx;
wire [7:0]  col_on;
wire [8:0]  grp_color;
wire [7:0]  row;
wire [15:0] row_color;

dir_mem dir_mem_1(
	.clk(clk), .rst(rst), .clear(clear),
	.wr_en(wr_en), .wr_idx(wr_idx), .wr_color(wr_color), .colors(colors));

matrix_ctrl matrix_ctrl_1(
	.phase(phase), .blink_2hz(blink_2hz), .cur_dir(cur_dir),
	.colors(colors), .row_idx(row_idx), .col_on(col_on), .grp_color(grp_color));

matrix_driver matrix_driver_1(
	.clk(clk), .rst(rst), .col_on(col_on), .grp_color(grp_color),
	.row_idx(row_idx), .row(row), .row_color(row_color));

integer errors = 0;

// ================= 期望模型（按 design.md 的像素表独立写一遍）=================
localparam P_SELFTEST = 2'd0, P_STANDBY = 2'd1, P_SCAN = 2'd2;
localparam C_OFF = 3'd0, C_GREEN = 3'd1, C_YGRN = 3'd2,
           C_YEL = 3'd3, C_ORG = 3'd4, C_RED = 3'd5;
localparam D0 = 4'd0, D45 = 4'd1, D90 = 4'd2, D135 = 4'd3, D180 = 4'd4,
           CENTER = 4'd5, NONE = 4'd15;

// 图2-1 的 17 个像素：行1~8 从上到下，列1~8 从左到右
function [3:0] exp_owner;
	input integer r, c;
	begin
		exp_owner = NONE;
		if (r==1 && c==4) exp_owner = D90;
		if (r==2 && c==1) exp_owner = D135;
		if (r==2 && c==4) exp_owner = D90;
		if (r==2 && c==7) exp_owner = D45;
		if (r==3 && c==2) exp_owner = D135;
		if (r==3 && c==4) exp_owner = D90;
		if (r==3 && c==6) exp_owner = D45;
		if (r==4 && c==3) exp_owner = D135;
		if (r==4 && c==4) exp_owner = D90;
		if (r==4 && c==5) exp_owner = D45;
		if (r==5 && c==1) exp_owner = D180;
		if (r==5 && c==2) exp_owner = D180;
		if (r==5 && c==3) exp_owner = D180;
		if (r==5 && c==4) exp_owner = CENTER;
		if (r==5 && c==5) exp_owner = D0;
		if (r==5 && c==6) exp_owner = D0;
		if (r==5 && c==7) exp_owner = D0;
	end
endfunction

// 测试用的 5 个方向颜色（由测试流程写入 dir_mem 后，这里保存一份副本做期望）
reg [2:0] tb_colors [0:4];

function [2:0] exp_color;
	input integer r, c;
	reg [3:0] o;
	begin
		o = exp_owner(r, c);
		case(phase)
			P_SELFTEST: exp_color = blink_2hz ? C_YEL : C_OFF;	// 整屏黄，与图案无关
			P_STANDBY:  exp_color = (o == NONE) ? C_OFF : C_GREEN;
			P_SCAN:     exp_color = (o == NONE)   ? C_OFF :
			                        (o == CENTER) ? tb_colors[cur_dir] :
			                                        tb_colors[o];
			default:    exp_color = C_OFF;
		endcase
	end
endfunction

// 颜色码 → 期望的红色时段长度（µs，即一行 1000 个时钟里红通道点亮的周期数）
// 绿 = 1000 - 红；"灭"两者都是 0。这里独立写一遍，不引用 DUT 的调色板。
function integer exp_red_us;
	input [2:0] col;
	begin
		case(col)
			C_GREEN: exp_red_us = 0;
			C_YGRN:  exp_red_us = 40;
			C_YEL:   exp_red_us = 100;
			C_ORG:   exp_red_us = 250;
			C_RED:   exp_red_us = 1000;
			default: exp_red_us = 0;
		endcase
	end
endfunction

function integer exp_grn_us;
	input [2:0] col;
	begin
		if (col == C_OFF) exp_grn_us = 0;
		else              exp_grn_us = 1000 - exp_red_us(col);
	end
endfunction

// ================= 采一整帧并比对 =================
integer cnt_r [0:63];
integer cnt_g [0:63];

task check_frame;
	input [8*24:1] name;
	integer r, c, k, idx, drow, got_r, got_g, want_r, want_g;
	begin
		for (k = 0; k < 64; k = k + 1) begin cnt_r[k] = 0; cnt_g[k] = 0; end
		
		// 对齐到 row_idx=0 这一行的**开头**：
		// 先等到离开第 0 行（否则可能在第 0 行中间就开始计数，窗口会跨到邻行）
		@(posedge clk);
		while (row === ~(8'b1 << 0)) @(posedge clk);
		while (row !== ~(8'b1 << 0)) @(posedge clk);
		
		// 逐行统计：每行 1000 个时钟
		for (r = 0; r < 8; r = r + 1) begin
			for (k = 0; k < 1000; k = k + 1) begin
				for (c = 0; c < 8; c = c + 1) begin
					idx = r*8 + c;
					if (row_color[8+c]) cnt_r[idx] = cnt_r[idx] + 1;	// 高 8 位 = 红
					if (row_color[c])   cnt_g[idx] = cnt_g[idx] + 1;	// 低 8 位 = 绿
				end
				@(posedge clk);
			end
		end
		
		// 比对：硬件行 r ↔ 图上行 (8-r)，硬件列 c ↔ 图上列 (c+1)
		for (r = 0; r < 8; r = r + 1) begin
			drow = 8 - r;
			for (c = 0; c < 8; c = c + 1) begin
				idx    = r*8 + c;
				got_r  = cnt_r[idx];
				got_g  = cnt_g[idx];
				want_r = exp_red_us(exp_color(drow, c+1));
				want_g = exp_grn_us(exp_color(drow, c+1));
				if (got_r < want_r - 3 || got_r > want_r + 3 ||
				    got_g < want_g - 3 || got_g > want_g + 3) begin
					$display("  [FAIL] %0s 图上(%0d,%0d): 红 %0d/%0d 绿 %0d/%0d (实测/期望 µs)",
					         name, drow, c+1, got_r, want_r, got_g, want_g);
					errors = errors + 1;
				end
				// 红绿同时点亮会导致行电流翻倍，查一下互斥
				if (cnt_r[idx] + cnt_g[idx] > 1003) begin
					$display("  [FAIL] %0s 图上(%0d,%0d): 红绿时段重叠 (%0d+%0d)",
					         name, drow, c+1, cnt_r[idx], cnt_g[idx]);
					errors = errors + 1;
				end
			end
		end
		$display("  [ok] case done: %0s", name);
	end
endtask

task write_dir;
	input [2:0] idx, col;
	begin
		@(posedge clk);
		wr_idx = idx; wr_color = col; wr_en = 1;
		tb_colors[idx] = col;
		@(posedge clk);
		wr_en = 0;
	end
endtask

// ================= 测试流程 =================
integer i;
initial begin
	rst = 1; phase = P_SELFTEST; blink_2hz = 1; cur_dir = 0;
	clear = 0; wr_en = 0; wr_idx = 0; wr_color = 0;
	for (i = 0; i < 5; i = i + 1) tb_colors[i] = C_OFF;
	
	#10;
	// ---- 1. 复位态：全灭 ----
	if (row !== 8'hFF || row_color !== 16'h0000) begin
		$display("  [FAIL] 复位态未熄灭: row=%h row_color=%h", row, row_color);
		errors = errors + 1;
	end
	else $display("  复位态全灭 OK");
	
	rst = 0;
	#10;
	
	// ---- 2. 自检：整屏黄闪 ----
	blink_2hz = 1; check_frame("selftest-on");
	blink_2hz = 0; check_frame("selftest-off");
	
	// ---- 3. 待机：图2-1 全绿 ----
	phase = P_STANDBY; blink_2hz = 1;
	check_frame("standby-pattern");
	
	// ---- 4. 扫描：方向寄存器初始为灭 ----
	phase = P_SCAN; cur_dir = 0;
	check_frame("scan-nodata");
	
	// ---- 5. 扫描：5 个方向写入 5 种不同颜色，验证每像素独立配色 ----
	write_dir(0, C_RED);	// 0°   红
	write_dir(1, C_ORG);	// 45°  橙
	write_dir(2, C_YEL);	// 90°  黄
	write_dir(3, C_YGRN);	// 135° 黄绿
	write_dir(4, C_GREEN);	// 180° 绿
	cur_dir = 2;			// 圆心应跟随 90° = 黄
	check_frame("scan-5colors");
	
	// ---- 6. 圆心实时跟随当前方向 ----
	cur_dir = 4;			// 圆心应变成绿
	check_frame("center-follow");
	
	// ---- 7. 单个方向更新不影响其它方向 ----
	write_dir(2, C_RED);	// 只把 90° 改成红
	check_frame("one-dir-update");
	
	// ---- 8. clear 清空 ----
	@(posedge clk); clear = 1; @(posedge clk); clear = 0;
	for (i = 0; i < 5; i = i + 1) tb_colors[i] = C_OFF;
	check_frame("clear-all");
	
	$display("");
	if (errors == 0) $display("==== RESULT: PASS (0 errors) ====");
	else             $display("==== RESULT: FAIL (%0d errors) ====", errors);
	$finish;
end

endmodule
