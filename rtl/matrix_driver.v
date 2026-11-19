// matrix_driver —— 8x8 双色点阵底层驱动：行扫描 + 每像素红绿混色
//
// 与 exp7 的区别（exp7 的 matrix_color 只能整屏一个占空比，这里每个像素独立配色）：
//   exp7: row_color = {col,col} & {p×8, ~p×8}      —— 一行 8 个点共用同一个 p
//   本模块: 每列各自查自己的颜色码 → 各自决定当前时刻红/绿哪个点亮
//
// 时序：每行 1000µs（8 行一帧 = 8ms，帧率 125Hz）。
// 混色：一行的 1000µs 里，前 TH 微秒点红、剩下的点绿（沿用 exp7"红绿分时、不同时点亮"
//       的性质，一行电流上限和 exp7 一致）。红+绿 = 1000µs，所以每个点亮的像素
//       总点亮时间恒定，不同颜色之间亮度一致。
module matrix_driver(
	input clk,
	input rst,
	input [7:0] col_on,			// 当前行哪几列点亮（j=0 为最左）
	input [8:0] grp_color,		// 三组列的颜色码：[2:0] 第 1~3 列，[5:3] 第 4 列，[8:6] 第 5~8 列
	
	output reg [2:0] row_idx,	// 当前扫描行，给 matrix_ctrl（0 = 最下面一行）
	output reg [7:0] row,		// 行选，低有效
	output reg [15:0] row_color	// 列数据：高 8 位红、低 8 位绿
);

// 红绿通道归属：上板已验证（待机图案显示为绿色），高 8 位是红。
localparam RED_HIGH = 1'b1;

localparam ROW_US = 10'd1000;	// 一行的时长（µs），同时也是 PWM 周期

// ---- 调色板：每种颜色的"红色时段"长度（µs，占一行 1000µs 的前多少）----
// 剩下的时间就是绿色。0 = 纯绿，1000 = 纯红。
//
// 上板实测：红 LED 比绿亮得多（约 9:1），所以真正的黄色在 100µs 附近而不是 500µs。
// 原先按 10 个子槽做（分辨率 1/10），绿到黄之间只剩一格，档位拉不开，
// 现在直接用行内的 µs 计数器当 PWM 相位，分辨率 1/1000。
// 调色时只改下面这四个数：数字越大越偏红。
localparam [9:0] TH_GREEN = 10'd0,		// 绿   ：全程绿
                 TH_YGRN  = 10'd40,		// 黄绿
                 TH_YEL   = 10'd100,	// 黄
                 TH_ORG   = 10'd250,	// 橙
                 TH_RED   = ROW_US;		// 红   ：全程红

// ---- 行节拍 / PWM 相位（同一个计数器）----
reg [9:0] pwm_cnt;
always@(posedge clk or posedge rst) begin
	if (rst) begin
		pwm_cnt <= 0;
		row_idx <= 0;
	end
	else if (pwm_cnt == ROW_US - 1) begin
		pwm_cnt <= 0;
		row_idx <= row_idx + 1'b1;
	end
	else
		pwm_cnt <= pwm_cnt + 1'b1;
end

// ---- 6 种颜色各比较一次，各组再从中选，比每组各做一次比较省资源 ----
wire [5:0] red_phase;			// 该颜色此刻处于"红色时段"
assign red_phase[0] = 1'b0;					// 灭（用不到）
assign red_phase[1] = (pwm_cnt < TH_GREEN);	// 绿
assign red_phase[2] = (pwm_cnt < TH_YGRN);	// 黄绿
assign red_phase[3] = (pwm_cnt < TH_YEL);	// 黄
assign red_phase[4] = (pwm_cnt < TH_ORG);	// 橙
assign red_phase[5] = 1'b1;					// 红

localparam [5:0] LIT = 6'b111110;	// 颜色码 0 = 灭，其余都点亮

// ---- 每组判断此刻红/绿哪个点亮，再按列开关 ----
// 【资源】原来 8 列各自查一遍颜色码；一行只有 3 组颜色来源，按组查只要 3 份
integer g, j;
reg [2:0] g_red, g_grn;
reg [2:0] cc;
always@(*) begin
	for (g = 0; g < 3; g = g + 1) begin
		cc       = grp_color[g*3 +: 3];
		g_red[g] = LIT[cc] &&  red_phase[cc];
		g_grn[g] = LIT[cc] && !red_phase[cc];
	end
end

// 第 j 列属于哪一组：0~2 → 组 0，3 → 组 1，4~7 → 组 2
function [1:0] grp_of;
	input [2:0] j;
	begin
		grp_of = (j < 3'd3) ? 2'd0 : (j == 3'd3) ? 2'd1 : 2'd2;
	end
endfunction

reg [7:0] red_on, grn_on;
always@(*) begin
	for (j = 0; j < 8; j = j + 1) begin
		red_on[j] = col_on[j] && g_red[grp_of(j)];
		grn_on[j] = col_on[j] && g_grn[grp_of(j)];
	end
end

always@(posedge clk or posedge rst) begin
	if (rst) begin
		row       <= 8'hFF;		// 低有效 → 全不选中
		row_color <= 16'h0000;
	end
	else begin
		row       <= ~(8'b1 << row_idx);
		row_color <= RED_HIGH ? {red_on, grn_on} : {grn_on, red_on};
	end
end

endmodule
