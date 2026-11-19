// dir_mem —— 5 个方向的持久颜色寄存器
// 每个方向保存"该方向最近一次测得的距离分级颜色"，只有该方向被再次扫到时才更新，
// 其余时间保持不变（对应题目"角度线颜色保持到下次扫描该角度"）。
module dir_mem(
	input clk,
	input rst,
	input clear,				// restart 或 phase!=SCAN：全部清成"灭"
	input wr_en,				// 测量完成脉冲
	input [2:0] wr_idx,			// 方向 0=0°,1=45°,2=90°,3=135°,4=180°
	input [2:0] wr_color,		// 颜色码 = band + 1
	
	output reg [14:0] colors	// 方向 i 在 [3i+2:3i]
);

// 【资源】写成 colors[wr_idx*3 +: 3] <= wr_color 时 Quartus 综合出移位器，46 LE；
// 改成每个方向各自比较 wr_idx，约 20 LE（加 LCD 后器件只剩二十几个 LE，从这里省）
integer i;
always@(posedge clk or posedge rst) begin
	if (rst)
		colors <= 15'h0000;
	else if (clear)
		colors <= 15'h0000;
	else if (wr_en)
		for (i = 0; i < 5; i = i + 1)
			if (wr_idx == i)
				colors[i*3 +: 3] <= wr_color;
end

endmodule
