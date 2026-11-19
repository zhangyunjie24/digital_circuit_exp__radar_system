// key_debounce —— 单个按键消抖，输出单周期脉冲
// 行为与 exp7 的 key_filter 相同（每 10ms 采样一次，连续两次采到按下才算，松开前只发一次），
// 只是做成 1 路：key_filter 是 8 路并行 + 自带 16 位分频计数器，这里只用到 1 路却占 40 LE；
// 改为复用 timebase 的 tick_1ms 计 10 下。加上 LCD 后器件放不下，从这里省出约 30 LE。
module key_debounce(
	input clk,
	input rst,
	input tick_1ms,
	input key,					// 按下为高
	
	output reg pulse			// 单周期脉冲
);

reg [3:0] ms_cnt;
reg [1:0] hist;					// 最近两次采样
reg held;						// 已经发过脉冲、等松开

always@(posedge clk or posedge rst) begin
	if (rst) begin
		ms_cnt <= 0;
		hist   <= 2'b00;
		held   <= 1'b0;
		pulse  <= 1'b0;
	end
	else begin
		pulse <= 1'b0;
		if (tick_1ms) begin
			if (ms_cnt == 4'd9) begin
				ms_cnt <= 0;
				hist   <= {hist[0], key};
				if (hist[0] && key && !held) begin
					pulse <= 1'b1;
					held  <= 1'b1;
				end
				else if (!hist[0] && !key)
					held <= 1'b0;
			end
			else
				ms_cnt <= ms_cnt + 1'b1;
		end
	end
end

endmodule
