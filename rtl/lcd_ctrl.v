// lcd_ctrl —— LCD12864（ST7565R，8080 并口）雷达图显示：按角度维护距离表，屏幕显示这张表
//
// 版面（128×64，8 页 × 128 列，每个字节是某列竖着的 8 个像素，bit0 在上）：
//   扇形雷达图，圆心在底边正中 (col 63.5, row 63)，0° 指右、180° 指左（与点阵一致）
//     - 底边一条基线，基线上 0.2 / 0.4 / 1 / 2 / 4m 处各一根 3 像素高的刻度，1 / 2 / 4m 刻度旁（右半边）写数字（距离到半径是三段折线，近处细远处粗，距圆心 10/20/32/40/50 列）
//     - 距离点：**距离表** 37 格（每 5° 一格：0°,5°,…,180°）× 5 位（存「级-1」0~24，31 = 无点；半径 = 2u+1，距离 → u 是三段折线：0~400mm 每级 40mm、400~1200mm 每级 100mm、1200~4000mm 每级 400mm，画在级中心 2u+1）
//       每次测距更新它所在那一格：新值替换旧值，屏上旧的擦掉、新的画上——不会越积越多
//       超量程 / 无回波（r_oor，含 4000mm 以上）：画在最外沿（u = 25，半径 51，比 4m 刻度再外一点）；
//       只有"还没有测量数据"才是无点（u = 31）
//     - 每格画成一小段**短弧**（以圆心为中心、±2.7°，比格间距的一半略宽）：相邻格距离级相同时弧首尾相接，
//       连成物体的轮廓；距离级不同的地方断开成台阶（用户想要"把相近的点连起来"；真正画直线连相邻点
//       需要读邻格、算线段、重画线段经过的所有字节，约 +400 LE，放不下；短弧每格只画自己，约 +100 LE）
//     - 只有切换模式、阶段变化时清屏（距离表一起清空）
//   自检阶段：LCD 保持空白（题目的自检只要求点阵/数码管/LED；原来用"全屏点亮"命令 A5/A4 跟着闪，
//     加短弧后资源用到 1269/1270，去掉省约 10 LE）
//   复位（SW7=0）：/RES 拉低，LCD 复位后显示关闭 → 满足"所有显示器件不显示"
//   （角度/距离数字由数码管显示；为了给距离表腾资源，LCD 顶部文字行和 1m/2m 弧形距离环都去掉了，
//     距离环改成基线上的刻度——刻度算在"背景"里，重画任何字节都自带，不用逐点枚举）
//
// 没有显存（EPM1270 没有块 RAM，屏幕只写不读）：写一个字节会覆盖同列同页的另外 7 个像素。
//   解决办法是"按表精确重画字节"：要改某个字节时，从背景（基线 + 刻度）开始，把距离表 37 格的点
//   逐个算一遍坐标，落在这个字节里的都 OR 进来，再一次写入。
//   每次测距：以旧弧、新弧的中心为准各框一个 ±4 像素的矩形（弧半宽 ≤2.6 像素），矩形里的字节逐个重画，
//   一共约 2×18 个字节、每个约 1.3k 时钟，约 50ms（CONT 每 100ms 测一次，来得及）。
//   之前几版没有距离表，只能"叠加"或"沿射线整条擦"，前者点越积越多，后者把相邻角度的点一起擦掉。
//
// 距离表用 37 级循环移位寄存器实现（148 个触发器）：读写都在表头 tbl[0]，要访问哪一格就转到哪一格；
//   重画时转一整圈，正好依次取出每一格。不用 31 选 1 的多路选择器（4 位 × 31 选 1 要上百个 LE）。
//
// 画弧：从行走得到的点 P 出发，往两边各"转" 4 小步，每步 x -= y/64、y += x/64（转约 0.9°，只是移位加减），
//   3 步 = 2.7°，半径只变 0.2%。坐标在"折叠后"的右半边算（>90° 的格按 180°-θ），所以 90° 那格的弧会跨过中线，
//   弧上坐标用带符号数；0°/180° 的弧有一半落到底边以下，裁掉。
//   每格 5 位而不是 6 位，是为了在剩下的资源里多存几个角度（用户的取舍：角度 5° 一格、距离近处 4cm 一级（折线）、量程 4m）。
//   【资源】第一版（2° 一项的 sin 表 + 弧形环逐点枚举 + 文字行）746 LE、整体放不下；改用格号查表（-45）、
//   去掉格号除法（-30）、弧形环改基线刻度（-120）后 549 LE。
//
// 画法："射线行走"：查 sin 表得到 (cosθ, sinθ)，从圆心出发每步 x += cosθ、y += sinθ，
//   走 t 步就是半径 t 处的像素。sin/cos 用 7 位小数（×128），最多走 55 步，累计误差 <0.3 像素。
//   >90° 按 180°-θ 走、画在左半边。圆心取 63.5（128 列正中）：右半边 col = 64+X = {1,X}，
//   左半边 col = 63-X = {0,~X}，row = 63-Y = ~Y，都不用加法器。
//
// 写时序（规格书 8080：周期 ≥240ns、WR 低 ≥140ns）：每字节 4 拍 = 4µs
//   拍0：A0/数据就位、CS 拉低   拍1：WR 拉低   拍2：WR 拉高（上升沿锁存）   拍3：CS 拉高
// 初始化命令照抄参考程序 lcd_12864.vhd，命令之间各等 1ms。
//
// 样式演变（都按上板反馈改过）：外沿轨迹点 → 题目图 2-2 的扫描线 → 留点 + 短指针 → 试过沿射线擦旧点
// → 留点、一个来回清一次 → 去掉指针、量程 2.2m、不清屏叠加（"越打越多"）→ 现在：按角度维护距离表
// （STEP 的 45°/90°/135° 正好落在格上）
module lcd_ctrl(
	input clk,
	input rst,
	input tick_1ms,
	input blink_2hz,			// 未用（原自检闪烁）
	input [1:0] phase,
	input mode_cont,			// 未用（原文字行显示模式名）
	input restart,

	input r_strobe,				// 新的测量结果已锁存
	input [11:0] r_angle_bcd,	// 未用（原文字行）
	input [15:0] r_dist_bcd,
	input r_valid,
	input r_oor,
	input [7:0] angle_deg,		// 二进制角度。更新在 r_strobe 后几 ms 内完成，此时舵机还在本档，所以直接用

	output reg [7:0] lcd_d,
	output reg lcd_cs_n,
	output reg lcd_a0,			// 0=命令 1=数据
	output reg lcd_wr_n,
	output lcd_rd_n,
	output reg lcd_rst_n
);

assign lcd_rd_n = 1'b1;			// 只写不读

localparam P_SELFTEST = 2'd0,
           P_SCAN     = 2'd2;

// ================= 主状态机 =================
localparam M_RST   = 4'd0,		// /RES 拉低
           M_RWAIT = 4'd1,		// /RES 释放后等待
           M_INIT  = 4'd2,		// 写初始化命令
           M_IWAIT = 4'd3,		// 初始化命令之间等 1ms
           M_IDLE  = 4'd4,
           M_ADDR  = 4'd6,		// 设页地址 + 列地址（3 条命令）
           M_DATA  = 4'd7,		// 写数据字节
           M_WC    = 4'd9,		// 行走：初始化（sin / cos 是组合查表，不用另等一拍；原来的 M_WS 已去掉）
           M_WSTEP = 4'd10,		// 行走：前进一步
           M_NEXT  = 4'd11,		// 行走结束：重画流程的下一步
           M_LOOK  = 4'd12,		// 把距离表转到这一格（表头角度离测量角度最近），读旧值、写新值
           M_ARC   = 4'd13;		// 画弧：9 个点

localparam J_CLR  = 1'b0,		// 清屏（第 0~7 页）
           J_REND = 1'b1;		// 写一个重画好的字节

// 重画一个字节的步骤
localparam RP_ADDR   = 3'd0,	// 刚走到旧弧 / 新弧的中心：记下它，作为矩形中心
           RP_BYTE0  = 3'd1,	// 开始重画 (tpg, tcl) 这个字节：从背景开始累积
           RP_SEL    = 3'd2,	// 取距离表的下一格
           RP_WALKED = 3'd3,	// 刚走到这一格的点：开始画弧
           RP_CELL   = 3'd4,	// 这一格的弧画完：转下一格
           RP_DONE   = 3'd5;	// 字节已写出

// 重画完一个字节之后做什么
localparam SQ_OLD  = 1'b0,		// 刚重画完旧弧所在矩形，接着画新弧
           SQ_NEW  = 1'b1;		// 刚重画完新弧所在矩形，结束

reg [3:0] state;
reg       job;
reg [1:0] ph;					// 写时序的拍 0~3
reg [3:0] k;					// 初始化命令序号 / 地址命令步
reg [2:0] wcnt;					// 等待的 ms 数



// ---- 待办事件 ----
reg [1:0] prev_phase;
reg pend_clr, pend_upd;

// ---- 行走器 ----
reg [13:0] wx, wy;				// 坐标，7 位小数（初值 0.5，取整数部分即四舍五入）
reg [5:0]  wend;				// 还要走几步（= 半径，像素），倒计数

// ---- 重画 ----
reg [2:0] rop;
reg       seq;
// 【资源】清屏的页 / 列和重画的目标页 / 列不会同时用，共用 tpg / tcl
reg [2:0] tpg;					// 目标字节：页、列、累积的内容（清屏时是当前页 / 列）
reg [6:0] tcl;
reg [7:0] acc;
reg [3:0] colc;					// 矩形里当前页已重画了几列 0~8
reg       pg2;					// 矩形的第二页（矩形高 9 行，恒占相邻两页，不需要存最后一页的页号）

// ---- 画弧 ----
reg [3:0] ex, ey;				// 画弧每步的位移（走到 P 时锁存）
reg [3:0] acnt;					// 画弧第几拍 0~9
reg [5:0] ccount;				// 枚举距离表：已转过几格

// ---- 距离表：37 格 × 4 位循环移位寄存器 ----
reg [4:0] tbl [0:36];
reg [5:0] head_k;				// tbl[0] 那一格的格号（0~36），画点用
reg       tbl_clr;				// 清空距离表（单拍）

// ---- 一次更新 ----
reg [4:0] new_lvl;
// 表头这一格就是测量角度所在格：就近取整，(测量角度 + 3) - 表头角度 ∈ [0, 5]
// （不用除以 6 求格号：转表时直接比较，省掉除法循环和格号寄存器）
wire [7:0] head_ang = {head_k[5:0], 2'b0} + {2'b0, head_k};	// tbl[0] 那一格的角度 = 5 × 格号
wire [7:0] ang_diff = angle_deg + 8'd2 - head_ang;	// 处理期间舵机还在本档，角度不变，直接用
wire at_cell = (ang_diff < 8'd5);

// ================= sin 表：sin(6k°) × 128，k = 0~15 =================
// 所有要画的点（距离表 31 格、环点）的角度都是 5° 的倍数，行走器直接用"格号" k（角度 = 5k，0~36）。
// 【资源】最早按角度值查 2° 一项的 46 项表，加上折叠 180-θ、θ/2、45-θ/2 这些 8 位运算共约 160 LE；
//   改用格号后折叠只是 30-k、cos 查 15-k，表也只有 16 项
function [7:0] sin_f;
	input [4:0] idx;
	case (idx)
		5'd0: sin_f = 8'd0;			// 0°
		5'd1: sin_f = 8'd11;			// 5°
		5'd2: sin_f = 8'd22;			// 10°
		5'd3: sin_f = 8'd33;			// 15°
		5'd4: sin_f = 8'd44;			// 20°
		5'd5: sin_f = 8'd54;			// 25°
		5'd6: sin_f = 8'd64;			// 30°
		5'd7: sin_f = 8'd73;			// 35°
		5'd8: sin_f = 8'd82;			// 40°
		5'd9: sin_f = 8'd91;			// 45°
		5'd10: sin_f = 8'd98;			// 50°
		5'd11: sin_f = 8'd105;			// 55°
		5'd12: sin_f = 8'd111;			// 60°
		5'd13: sin_f = 8'd116;			// 65°
		5'd14: sin_f = 8'd120;			// 70°
		5'd15: sin_f = 8'd124;			// 75°
		5'd16: sin_f = 8'd126;			// 80°
		5'd17: sin_f = 8'd128;			// 85°
		5'd18: sin_f = 8'd128;			// 90°
		default: sin_f = 8'd128;		// 90°
	endcase
endfunction
function [7:0] cos_f;
	input [4:0] idx;
	case (idx)
		5'd0: cos_f = 8'd128;			// cos 0°
		5'd1: cos_f = 8'd128;			// cos 5°
		5'd2: cos_f = 8'd126;			// cos 10°
		5'd3: cos_f = 8'd124;			// cos 15°
		5'd4: cos_f = 8'd120;			// cos 20°
		5'd5: cos_f = 8'd116;			// cos 25°
		5'd6: cos_f = 8'd111;			// cos 30°
		5'd7: cos_f = 8'd105;			// cos 35°
		5'd8: cos_f = 8'd98;			// cos 40°
		5'd9: cos_f = 8'd91;			// cos 45°
		5'd10: cos_f = 8'd82;			// cos 50°
		5'd11: cos_f = 8'd73;			// cos 55°
		5'd12: cos_f = 8'd64;			// cos 60°
		5'd13: cos_f = 8'd54;			// cos 65°
		5'd14: cos_f = 8'd44;			// cos 70°
		5'd15: cos_f = 8'd33;			// cos 75°
		5'd16: cos_f = 8'd22;			// cos 80°
		5'd17: cos_f = 8'd11;			// cos 85°
		5'd18: cos_f = 8'd0;			// cos 90°
		default: cos_f = 8'd0;
	endcase
endfunction

wire [4:0] k_fold = (head_k > 6'd18) ? (6'd36 - head_k) : head_k[4:0];		// 0~18（>90° 折到左半边）
// 【资源】sin / cos 直接组合查表（cos 查 15-k = ~k，免费），不再锁存成 wc / ws 两个 8 位寄存器
wire       wleft = (head_k > 6'd18);				// >90°：画在左半边
wire [7:0] ws = sin_f(k_fold);
wire [7:0] wc = cos_f(k_fold);

// ---- 当前像素（走到第 wt 步）----
wire [5:0] X = wx[12:7];
wire [5:0] Y = wy[12:7];
wire [5:0] drow = ~Y;									// row = 63 - Y = ~Y
wire [6:0] dcl  = wleft ? {1'b0, ~X} : {1'b1, X};

// ---- 弧上当前点的像素 ----
// 【资源】画弧不再另设 ax / ay 两个 11 位寄存器和两个加法器，直接在行走器的 wx / wy 上继续走：
//   同一对加法器，行走时加 (cos, sin)，画弧时加 ∓(ex, ey)。wx / wy 多一位符号位（弧可能越过圆心线）。
//   弧点的像素和原来逐点相同：原来的 4 位小数点 = 现在 7 位小数点的高 4 位，多出来的低 3 位不到 1 个单位，不会改变取整。
wire signed [6:0] AXs = wx[13:7];						// 整数部分（带符号）
wire signed [6:0] AYs = wy[13:7];
// 【资源】63-X 写成 64 + ~X，两边共用一个加法器；63-Y 的低 6 位就是 ~Y，Y<0（落到底边以下）看符号位，不用加法器
wire [6:0] acol = 7'd64 + (AXs ^ {7{wleft}});
wire [5:0] arow = ~AYs[5:0];
wire ahit = !AYs[6] && (arow[5:3] == tpg) && (acol == tcl);
wire [7:0] amask = 8'h01 << arow[2:0];
// 每步转 1/64 弧度：x 移 y/64 像素 = wy/512 → 取 wy[12:9]（4 位，单位 1/16 像素 = 8 个 1/128）。
// ex / ey 在走到 P 时锁存（之后 wx / wy 就不是 P 了）。
// 弧上 7 个点 P-3d … P+3d，d = (-ex, +ey)：acnt 0~2 先往回走 3 步（x+=ex, y-=ey）到 P-3d，
//   acnt 3~9 逐点检查、再往前一步（x-=ex, y+=ey）。
wire arcing = (state == M_ARC);
wire fwd    = (acnt >= 4'd3);
wire sub_x  = arcing &&  fwd;
wire sub_y  = arcing && !fwd;
wire [13:0] xa = arcing ? ({7'b0, ex, 3'b0} ^ {14{sub_x}}) : {6'b0, wc};
wire [13:0] ya = arcing ? ({7'b0, ey, 3'b0} ^ {14{sub_y}}) : {6'b0, ws};
wire [13:0] wx_next = wx + xa + sub_x;
wire [13:0] wy_next = wy + ya + sub_y;

// ---- 矩形：中心 ±4 像素（弧半宽 ≤ 54×sin2.7° = 2.6 像素）----
// 不做边界裁剪：弧心离圆心 ≤54，列号在 10~118，±4 不会出界；行号 +4 可能超过 63 回绕成第 0 页，
// 只是多重画几个第 0 页的空字节，无害
// 【资源】9 行高的矩形不管怎么放都恰好占两页（行号回绕到第 0 页时也是 7、0 两页），
//   所以只要记"第二页画过没有"一位，不用再存末页页号和算 drow+4

// ---- 距离 → 距离级：三段折线，近处细、远处粗（近似对数）----
//   0 ~ 400mm   ：每级  40mm（u = 0~9）    → 半径 0~20 像素
//   400 ~ 1200mm：每级 100mm（u = 10~17）  → 半径 20~36 像素
//   1200 ~ 4000mm：每级 400mm（u = 18~24） → 半径 36~50 像素
// 直接从 BCD 算，不做乘除：t = 十位以上的"十毫米数"= 10×百位+十位（0~39），h = "百毫米数"= 10×千位+百位（0~39）
//   段 1：u = t/4；段 2：u = 6 + h；段 3：u = 15 + h/4。结果与按真实毫米数算完全一致（测试台里逐项核对）。
wire [3:0] d3 = r_dist_bcd[15:12];
wire [3:0] d2 = r_dist_bcd[11:8];
wire [3:0] d1 = r_dist_bcd[7:4];
// 【资源】三段共用一个"10a+b"加法器和一个"+偏移"加法器（原来 t10、h100 各一个，+6、+15 又各一个）
wire       seg1 = (d3 == 4'd0 && d2 < 4'd4);				// < 400mm
wire [5:0] tens = {seg1 ? d2 : d3, 1'b0} + {seg1 ? d2 : d3, 3'b0} + (seg1 ? d1 : d2);	// 段 1：t；段 2/3：h
wire       seg2 = !seg1 && (tens < 6'd12);					// < 1200mm
wire [4:0] u_lvl = (seg2 ? tens[4:0] : {1'b0, tens[5:2]}) + (seg1 ? 5'd0 : seg2 ? 5'd6 : 5'd15);
// 【资源】表里存「级-1」（0~24），31 = 无点：画点半径直接是 {存值,1}，不用加减 1
// 无回波 / 超量程（r_oor）画在最外沿：u = 25（半径 51，比 4m 刻度的半径 50 再外一点）
wire [4:0] meas_lvl = !r_valid ? 5'd31 : r_oor ? 5'd25 : u_lvl;

// 存值 u = 级-1 → 画点的半径：这一级的中心 u×2+1
function [5:0] rdisp;
	input [4:0] lvl;
	begin
		rdisp = {lvl, 1'b1};
	end
endfunction

// ================= 背景：底边基线 + 刻度 + 刻度数字 =================
// 右半边在 1 / 2 / 4m 刻度旁（第 56~60 行）写出数字 1 2 4（单位 m）；0.2 / 0.4m 刻度和左半边只有刻度线、不写数字。
// 【资源】每个字符占 4 列、起点都是 4 的倍数：用 c[6:2] 选字符、c[1:0] 选字符内第几列，
//   字形表只是几位的小函数，不用对 7 位列号逐列比较（逐列写 17 个常量要多花约 25 LE）
//   字符格（c[6:2]）：24 = "1"（96~98）、26 = "2"（104~106）、28 = "4"（112~114）
function [4:0] lab;
	input [6:0] c;
	reg [2:0] g;					// 字形编号：0 无、2 "2"、3 "4"、4 "1"
	begin
		case (c[6:2])
			5'd26: g = 3'd2;
			5'd28: g = 3'd3;
			5'd24: g = 3'd4;
			default:      g = 3'd0;
		endcase
		// 3×5 点阵字：每列 5 位，bit0 在最上（第 56 行），bit4 在最下（第 60 行）
		case ({g, c[1:0]})
			{3'd2, 2'd0}: lab = 5'h1D;  {3'd2, 2'd1}: lab = 5'h15;  {3'd2, 2'd2}: lab = 5'h17;	// "2"
			{3'd3, 2'd0}: lab = 5'h07;  {3'd3, 2'd1}: lab = 5'h04;  {3'd3, 2'd2}: lab = 5'h1F;	// "4"
			{3'd4, 2'd0}: lab = 5'h12;  {3'd4, 2'd1}: lab = 5'h1F;  {3'd4, 2'd2}: lab = 5'h10;	// "1"
			default:      lab = 5'h00;
		endcase
	end
endfunction

function [7:0] bg;
	input [2:0] p;
	input [6:0] c;
	begin
		if (p != 3'd7)
			bg = 8'h00;
		else if (c == 7'd13 || c == 7'd23 || c == 7'd31 || c == 7'd43 || c == 7'd53 || c == 7'd74 || c == 7'd84 || c == 7'd96 || c == 7'd104 || c == 7'd114)
			bg = 8'hE0 | {3'b0, lab(c)};	// 0.2 / 0.4 / 1 / 2 / 4m 刻度（距圆心 10/20/32/40/50 列）：3 像素高的短竖线
		else
			bg = 8'h80 | {3'b0, lab(c)};	// 底边基线
	end
endfunction

// ================= 初始化命令（照抄 lcd_12864.vhd）=================
reg [7:0] init_cmd;
always@(*) begin
	case (k)
		4'd0:  init_cmd = 8'hE2;	// 软复位
		4'd1:  init_cmd = 8'h2C;	// 升压步骤 1
		4'd2:  init_cmd = 8'h2E;	// 升压步骤 2
		4'd3:  init_cmd = 8'h2F;	// 升压步骤 3
		4'd4:  init_cmd = 8'h24;	// 粗调对比度
		4'd5:  init_cmd = 8'h81;	// 微调对比度（双字节命令）
		4'd6:  init_cmd = 8'h1C;
		4'd7:  init_cmd = 8'hA2;	// 1/9 偏压
		4'd8:  init_cmd = 8'hC8;	// COM 反向：第 0 页在上
		4'd9:  init_cmd = 8'hA0;	// ADC 正常：第 0 列在左
		4'd10: init_cmd = 8'h40;	// 起始行 0
		4'd11: init_cmd = 8'hB0;
		4'd12: init_cmd = 8'h10;
		4'd13: init_cmd = 8'h00;
		default: init_cmd = 8'hAF;	// 开显示
	endcase
end
localparam INIT_LAST = 4'd14;

// ================= 本拍要写的字节 =================
wire [2:0] a_pg = tpg;
wire [6:0] a_cl = (job == J_CLR) ? 7'd0 : tcl;

reg       w_a0;
reg [7:0] w_dat;
always@(*) begin
	w_a0  = 1'b0;
	w_dat = 8'h00;
	case (state)
		M_INIT: w_dat = init_cmd;
		M_ADDR: case (k)
					4'd0:    w_dat = {5'b10110, a_pg};			// 页地址
					4'd1:    w_dat = {5'b00010, a_cl[6:4]};		// 列地址高 4 位
					default: w_dat = {4'b0000, a_cl[3:0]};		// 列地址低 4 位
				endcase
		M_DATA: begin
			w_a0  = 1'b1;
			w_dat = (job == J_CLR) ? bg(tpg, tcl) : acc;
		end
		default: ;
	endcase
end

wire writing = (state == M_INIT) || (state == M_ADDR) || (state == M_DATA);
wire wdone   = writing && (ph == 2'd3);		// 本字节写完（拍 3）

// ================= 距离表 =================
// 转一格：tbl[i] ← tbl[i+1]，表头格号 +1、角度 +6；写：只写表头
wire tbl_rot = ((state == M_NEXT) && (((rop == RP_SEL) && (ccount != 6'd37) && (tbl[0] == 5'd31)) || (rop == RP_CELL)))
            || ((state == M_LOOK) && !at_cell);
wire tbl_wr  = (state == M_LOOK) && at_cell;

integer i;
always@(posedge clk or posedge rst) begin
	if (rst) begin
		for (i = 0; i < 37; i = i + 1)
			tbl[i] <= 5'd31;
		head_k   <= 0;
	end
	else if (tbl_clr) begin
		for (i = 0; i < 37; i = i + 1)
			tbl[i] <= 5'd31;
		head_k   <= 0;
	end
	else if (tbl_rot) begin
		for (i = 0; i < 36; i = i + 1)
			tbl[i] <= tbl[i + 1];
		tbl[36]  <= tbl[0];
		head_k   <= (head_k == 6'd36) ? 6'd0 : head_k + 1'b1;
	end
	else if (tbl_wr)
		tbl[0] <= new_lvl;
end

// 【资源】tcl 的三种改法（+1、回退 8 列、从弧心 -4 开始）共用一个加法器
wire       tcl_ld   = (state == M_NEXT) && (rop == RP_ADDR);
wire       tcl_back = (job == J_REND) && (colc == 4'd8);
wire [6:0] tcl_step = (tcl_ld ? dcl : tcl) + (tcl_ld ? -7'd4 : tcl_back ? -7'd8 : 7'd1);
// tpg 同理：+1 换页、从弧心所在行 -4 算起 = (row-4)/8
wire [2:0] tpg_step = (tcl_ld ? drow[5:3] : tpg) + (tcl_ld ? ((drow[2:0] < 3'd4) ? 3'b111 : 3'd0) : 3'd1);

// ================= 主流程 =================
always@(posedge clk or posedge rst) begin
	if (rst) begin
		state      <= M_RST;
		job        <= J_CLR;
		ph         <= 0;
		k          <= 0;
		wcnt       <= 0;
		prev_phase <= P_SELFTEST;
		pend_clr   <= 1'b0;
		pend_upd   <= 1'b0;
		wx         <= 0;
		wy         <= 0;
		wend       <= 0;
		rop        <= RP_ADDR;
		seq        <= SQ_OLD;
		tpg        <= 0;
		tcl        <= 0;
		acc        <= 0;
		colc       <= 0;
		pg2        <= 1'b0;
		ex         <= 0;
		ey         <= 0;
		acnt       <= 0;
		ccount     <= 0;
		tbl_clr    <= 1'b0;
		new_lvl    <= 5'd31;
		lcd_d      <= 8'h00;
		lcd_cs_n   <= 1'b1;
		lcd_a0     <= 1'b0;
		lcd_wr_n   <= 1'b1;
		lcd_rst_n  <= 1'b0;
	end
	else begin
		tbl_clr <= 1'b0;

		// ---------- 8080 写时序 ----------
		if (writing) begin
			case (ph)
				2'd0: begin
					lcd_a0   <= w_a0;
					lcd_d    <= w_dat;
					lcd_cs_n <= 1'b0;
				end
				2'd1: lcd_wr_n <= 1'b0;
				2'd2: lcd_wr_n <= 1'b1;
				2'd3: lcd_cs_n <= 1'b1;
			endcase
			ph <= ph + 1'b1;
		end
		else
			ph <= 0;

		// ---------- 主流程 ----------
		case (state)
			M_RST: begin
				lcd_rst_n <= 1'b0;
				if (tick_1ms) begin
					if (wcnt == 3'd2) begin
						wcnt      <= 0;
						lcd_rst_n <= 1'b1;
						state     <= M_RWAIT;
					end
					else
						wcnt <= wcnt + 1'b1;
				end
			end

			M_RWAIT: begin
				if (tick_1ms) begin
					if (wcnt == 3'd5) begin
						wcnt  <= 0;
						k     <= 0;
						state <= M_INIT;
					end
					else
						wcnt <= wcnt + 1'b1;
				end
			end

			M_INIT: begin
				if (wdone) begin
					if (k == INIT_LAST) begin
						pend_clr <= 1'b1;
						state    <= M_IDLE;
					end
					else begin
						k     <= k + 1'b1;
						state <= M_IWAIT;
					end
				end
			end

			M_IWAIT: begin
				if (tick_1ms)
					state <= M_INIT;
			end

			M_IDLE: begin
				k <= 0;
				if (pend_clr) begin
					// 清屏（背景 = 基线 + 刻度）+ 清空距离表
					pend_clr  <= 1'b0;
					pend_upd  <= 1'b0;
					tbl_clr   <= 1'b1;
					job       <= J_CLR;
					tpg       <= 3'd0;
					state     <= M_ADDR;
				end
				else if (pend_upd) begin
					// 测距更新：转到这一格写表 → 重画旧点、新点所在字节
					pend_upd <= 1'b0;
					new_lvl  <= meas_lvl;
					state    <= M_LOOK;
				end
			end

			M_ADDR: begin
				if (wdone) begin
					if (k == 4'd2) begin
						k     <= 0;
						if (job == J_CLR) tcl <= 0;
						state <= M_DATA;
					end
					else
						k <= k + 1'b1;
				end
			end

			M_DATA: begin
				if (wdone) begin
					if (job == J_CLR) begin
						tcl <= tcl_step;
						if (tcl == 7'd127) begin			// 只清能显示的 128 列（后 4 列不显示）
							if (tpg == 3'd7)
								state <= M_IDLE;
							else begin
								tpg   <= tpg_step;
								state <= M_ADDR;
							end
						end
					end
					else begin							// J_REND：一个字节重画完
						rop   <= RP_DONE;
						state <= M_NEXT;
					end
				end
			end

			// ---------- 转到这一格：读旧值、写新值（tbl_rot / tbl_wr 在距离表那段）----------
			M_LOOK: begin
				if (at_cell) begin
					if (tbl[0] == new_lvl)
						state <= M_IDLE;					// 没变，不用重画
					else if (tbl[0] != 5'd31) begin
						seq   <= SQ_OLD;				// 先重画旧点所在字节（表里已是新值，旧点自然消失）
						wend  <= rdisp(tbl[0]);
						rop   <= RP_ADDR;
						state <= M_WC;
					end
					else begin
						seq   <= SQ_NEW;				// 原来没点：只画新点
						wend  <= rdisp(new_lvl);
						rop   <= RP_ADDR;
						state <= M_WC;
					end
				end
			end

			// ---------- 射线行走 ----------
			M_WC: begin
				wx    <= 14'd64;			// 0.5：取整数部分即四舍五入
				wy    <= 14'd64;
				state <= (wend == 6'd0) ? M_NEXT : M_WSTEP;
			end

			M_WSTEP: begin
				wend <= wend - 1'b1;
				wx <= wx_next;
				wy <= wy_next;
				if (wend == 6'd1)
					state <= M_NEXT;
			end

			// ---------- 画弧：先往回走 3 步到 P-3d，再逐点检查、往前走，共 7 个点 ----------
			M_ARC: begin
				if (fwd && ahit)
					acc <= acc | amask;
				acnt <= acnt + 1'b1;
				wx   <= wx_next;
				wy   <= wy_next;
				if (acnt == 4'd9) begin
					rop   <= RP_CELL;
					state <= M_NEXT;
				end
			end

			// ---------- 重画一个字节 ----------
			M_NEXT: begin
				case (rop)
					RP_ADDR: begin
						// 旧弧 / 新弧的中心 = 刚走到的这个点；矩形从左上角的字节开始
						colc <= 0;
						pg2  <= 1'b0;
						tpg  <= tpg_step;							// = (row-4)/8
						tcl  <= tcl_step;
						rop  <= RP_BYTE0;
					end
					RP_BYTE0: begin
						acc    <= bg(tpg, tcl);
						ccount <= 0;
						rop    <= RP_SEL;
					end
					RP_SEL: begin
						if (ccount == 6'd37) begin
							job   <= J_REND;			// 37 格都看过了：写出这个字节
							k     <= 0;
							state <= M_ADDR;
						end
						else if (tbl[0] != 5'd31) begin
							wend  <= rdisp(tbl[0]);
							rop   <= RP_WALKED;
							state <= M_WC;
						end
						else
							ccount <= ccount + 1'b1;		// 空格：转一格（tbl_rot）
					end
					RP_WALKED: begin
						ex    <= wy[12:9];
						ey    <= wx[12:9];
						acnt  <= 0;
						state <= M_ARC;
					end
					RP_CELL: begin
						ccount <= ccount + 1'b1;			// 转一格（tbl_rot）
						rop    <= RP_SEL;
					end
					default: begin						// RP_DONE：矩形里的下一个字节
						if (colc != 4'd8) begin
							colc <= colc + 1'b1;
							tcl <= tcl_step;
							rop <= RP_BYTE0;
						end
						else if (!pg2) begin
							pg2 <= 1'b1;
							tpg <= tpg_step;
							colc <= 0;
							tcl <= tcl_step;
							rop <= RP_BYTE0;
						end
						else case (seq)
							SQ_OLD: begin
								if (new_lvl != 5'd31) begin
									seq   <= SQ_NEW;
									wend  <= rdisp(new_lvl);
									rop   <= RP_ADDR;
									state <= M_WC;
								end
								else
									state <= M_IDLE;
							end
							default:
								state <= M_IDLE;
						endcase
					end
				endcase
			end

			default: state <= M_IDLE;
		endcase

		// ---------- 收集事件（任何状态下都收，空闲时再处理）----------
		// 放在主流程之后：和 M_IDLE 里"清待办"撞在同一拍时以新事件为准，不会丢
		prev_phase <= phase;
		if (restart || phase != prev_phase) begin
			pend_clr <= 1'b1;
			pend_upd <= 1'b0;
		end
		else if (r_strobe && phase == P_SCAN)
			pend_upd <= 1'b1;
	end
end

endmodule
