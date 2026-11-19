// matrix_ctrl（pattern_mapper）—— 按阶段生成当前行哪几列点亮、三组列各是什么颜色（纯组合）
//
// 像素表来自 design.md 对图2-1的精确读取（行1~8从上到下，列1~8从左到右）：
//   共同圆心：(5,4)
//   90°线： (1,4) (2,4) (3,4) (4,4) (5,4)
//   45°线： (5,4) (4,5) (3,6) (2,7)
//   135°线：(5,4) (4,3) (3,2) (2,1)
//   0°线：  (5,4) (5,5) (5,6) (5,7)
//   180°线：(5,4) (5,3) (5,2) (5,1)
module matrix_ctrl(
	input [1:0] phase,			// 0=SELFTEST, 1=STANDBY, 2=SCAN
	input blink_2hz,
	input [2:0] cur_dir,		// 当前正在扫描的方向，圆心实时跟随它
	input [14:0] colors,		// 5 个方向的持久颜色，方向 i 在 [3i+2:3i]
	input [2:0] row_idx,		// 来自 matrix_driver 的硬件行号（0 = 最下面一行）
	
	// 【资源】原来输出每列各自的 3 位颜色码（24 位），matrix_driver 再逐列把颜色码换成红/绿，
	//   8 列各做一份。其实一行里只有三组颜色来源（第 1~3 列、第 4 列、第 5~8 列），
	//   改为输出"哪几列点亮" + 三组颜色，driver 只需把 3 个颜色换成红/绿，再按列开关
	output reg [7:0] col_on,	// 本行哪几列点亮（bit j = 第 j 列，j=0 为最左）
	output reg [8:0] grp_color	// 三组的颜色码：[2:0] 第 1~3 列，[5:3] 第 4 列，[8:6] 第 5~8 列
);

localparam P_SELFTEST = 2'd0,
           P_STANDBY  = 2'd1,
           P_SCAN     = 2'd2;

// 颜色码
localparam C_OFF    = 3'd0,
           C_GREEN  = 3'd1,
           C_YELLOW = 3'd3;

// 方向编码（与 modules.md 一致）
localparam D0 = 4'd0, D45 = 4'd1, D90 = 4'd2, D135 = 4'd3, D180 = 4'd4,
           CENTER = 4'd5, NONE = 4'd15;

// 硬件行列方向：由 exp7/top.v 的字模（Z/Y/J/心形）渲染反推确认 ——
//   row_idx=7 是最上面一行、row_idx=0 是最下面 → 与图上"行1~8从上到下"相反，需翻转
//   bit0 是最左列 → 与图上"列1~8从左到右"一致，不需翻转
// 上板若发现上下/左右颠倒，改这两个常量即可。
localparam ROW_FLIP = 1'b1;
localparam COL_FLIP = 1'b0;

wire [3:0] doc_row = ROW_FLIP ? (4'd8 - row_idx) : (row_idx + 4'd1);


// 圆心颜色 = 当前扫描方向的实时颜色
wire [2:0] center_color = (cur_dir < 3'd5) ? colors[cur_dir*3 +: 3] : C_OFF;

wire [2:0] c0   = colors[ 2: 0];		// 0°
wire [2:0] c45  = colors[ 5: 3];
wire [2:0] c90  = colors[ 8: 6];
wire [2:0] c135 = colors[11: 9];
wire [2:0] c180 = colors[14:12];
wire r5 = (doc_row == 4'd5);

// 【资源】同一组的几列（第 1~3 列、第 4 列、第 5~7 列）颜色来源相同，先按"是不是第 5 行"选出一组颜色（3 位），
//   再逐列只用"这一列在本行是否有像素"去开关，不再给每列各做一份 3 位的多路选择
wire [2:0] g_l = r5 ? c180 : c135;		// 第 1~3 列：第 5 行是 180°，其余是 135°
wire [2:0] g_m = r5 ? center_color : c90;	// 第 4 列：第 5 行是圆心，其余是 90°
wire [2:0] g_r = r5 ? c0 : c45;			// 第 5~7 列：第 5 行是 0°，其余是 45°

// 这一列在本行有像素（第 8 列没有）
reg [7:0] on;
always@(*) begin
	on[0] = r5 || (doc_row == 4'd2);
	on[1] = r5 || (doc_row == 4'd3);
	on[2] = r5 || (doc_row == 4'd4);
	on[3] = r5 || (doc_row >= 4'd1 && doc_row <= 4'd4);
	on[4] = r5 || (doc_row == 4'd4);
	on[5] = r5 || (doc_row == 4'd3);
	on[6] = r5 || (doc_row == 4'd2);
	on[7] = 1'b0;
end

always@(*) begin
	case(phase)
		P_SELFTEST: begin					// 整屏黄闪
			col_on    = 8'hFF;
			grp_color = blink_2hz ? {3{C_YELLOW}} : {3{C_OFF}};
		end
		P_STANDBY: begin					// 图案全绿
			col_on    = on;
			grp_color = {3{C_GREEN}};
		end
		P_SCAN: begin
			col_on    = on;
			grp_color = {g_r, g_m, g_l};
		end
		default: begin
			col_on    = 8'h00;
			grp_color = {3{C_OFF}};
		end
	endcase
end

endmodule
