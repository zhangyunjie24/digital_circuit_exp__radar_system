// seg_scan —— 8 位数码管动态扫描
// 结构照搬 exp5/seg.v（母目录里唯一验证过的 8 位动态扫描；exp2~exp4 都是单位静态显示、cat 写死）：
// 1ms 换一位、data[select*4 +: 4] 取符号码、位选从 8'b1111_1110 起左移。
// 区别：段码表换成 exp2 的 7 位版本（见 seg_decoder.v 里的说明），
//       并且符号码 A/F 被重定义为"-"和空白，而不是 exp5 里的字母 A/F。
// cat[7:0] 低有效选位，seg[6:0] 高有效段码（不含小数点，DP 留给舵机）
module seg_scan(
	input clk,
	input rst,
	input tick_1ms,			// 来自 timebase：每 1ms 换一位（省掉本模块自己的 1ms 计数器）
	input [31:0] digits,	// 8 个符号码，DISP7 在 [31:28]，DISP0 在 [3:0]
	
	output reg [6:0] seg,
	output reg [7:0] cat
);

// cat 的哪一位对应 DISP 几：由 exp5 反推 —— exp5 里 data 的最高 4 位（select=7、cat[7]）
// 显示的是最左边那位，所以 cat[7] = 最左 = DISP7，和本模块 digits[31:28]=DISP7 的约定一致。
// 保留这个开关以防万一（比如板上 DISP 编号是反着印的），颠倒时改成 1'b1 即可。
localparam DISP_REVERSE = 1'b0;

// ---- 1ms 换位节拍 ----
reg [2:0] sel;
always@(posedge clk or posedge rst) begin
	if (rst)
		sel <= 0;
	else if (tick_1ms)
		sel <= sel + 1'b1;
end

// ---- 取出当前位的符号码并译码 ----
wire [2:0] disp_idx = DISP_REVERSE ? (3'd7 - sel) : sel;
wire [3:0] sym      = digits[disp_idx*4 +: 4];

wire [6:0] seg_w;
seg_decoder seg_decoder_1(
	.a(sym),
	.seg(seg_w)
);

always@(posedge clk or posedge rst) begin
	if (rst) begin
		seg <= 7'b000_0000;
		cat <= 8'hFF;			// 全部不选中 = 全灭
	end
	else begin
		seg <= seg_w;
		cat <= ~(8'b1 << sel);
	end
end

endmodule
