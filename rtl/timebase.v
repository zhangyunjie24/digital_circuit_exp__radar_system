// timebase —— 全局慢速节拍发生器
// 1MHz 主时钟 → 1ms 单周期脉冲 + 2Hz 方波电平
// 设计约定：不产生派生时钟，所有下游模块仍挂在 clk 上，用这些脉冲/电平做节拍
module timebase(
	input clk,				// 1MHz
	input rst,				// 高有效异步复位（rst = ~sw7）
	
	output reg tick_1ms,	// 每 1000 个 clk 一个单周期高脉冲
	output tone_2k,			// 约 2kHz 方波（us_cnt 第 8 位：每 256µs 翻转，到 999 回 0 时有一次不规则，蜂鸣器听不出来）
	                        // 给 buzzer_ctrl 用，省掉它自己的音调分频计数器（加 LCD 后资源紧张）
	output reg blink_2hz,	// 每 250ms 翻转一次 → 周期 500ms = 2Hz；复位后为高（"进入自检先亮"）
	output reg blink_1hz,	// blink_2hz 每次由低变高时翻转 → 周期 1000ms；复位后为高
	output beat_100ms		// 每个 250ms 段的前 100ms 为高（给 buzzer_ctrl 做"响 100ms"的节奏）
);

// ---- 1ms 分频 ----
reg [9:0] us_cnt;
assign tone_2k = us_cnt[8];
always@(posedge clk or posedge rst) begin
	if (rst) begin
		us_cnt   <= 0;
		tick_1ms <= 0;
	end
	else if (us_cnt == 999) begin
		us_cnt   <= 0;
		tick_1ms <= 1;
	end
	else begin
		us_cnt   <= us_cnt + 1'b1;
		tick_1ms <= 0;
	end
end

// ---- 250ms 翻转 ----
// 【资源】buzzer_ctrl 原来自带 10 位 ms 计数器 + 周期比较（25 LE）；它的 250/500/1000ms 节奏
//   正好是这里 ms_cnt 的一圈、blink_2hz 的一个周期、blink_1hz 的一个周期，直接给它用
reg [7:0] ms_cnt;
assign beat_100ms = (ms_cnt < 8'd100);
always@(posedge clk or posedge rst) begin
	if (rst) begin
		ms_cnt    <= 0;
		blink_2hz <= 1'b1;
		blink_1hz <= 1'b1;
	end
	else if (tick_1ms) begin
		if (ms_cnt == 249) begin
			ms_cnt    <= 0;
			blink_2hz <= ~blink_2hz;
			if (!blink_2hz)
				blink_1hz <= ~blink_1hz;
		end
		else
			ms_cnt <= ms_cnt + 1'b1;
	end
end

endmodule
