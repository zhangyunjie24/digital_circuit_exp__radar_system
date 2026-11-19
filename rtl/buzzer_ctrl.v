// buzzer_ctrl —— 蜂鸣器：约 2kHz 方波 × 节奏门控，距离越近越急促
//   band 0/7（≥800mm、超量程、尚无数据）→ 不响
//   band 1（600~800）→ 响 100ms / 周期 1000ms
//   band 2（400~600）→ 响 100ms / 周期 500ms
//   band 3（200~400）→ 响 100ms / 周期 250ms
//   band 4（<200）   → 常响
// 只在 SCAN 阶段发声。不响时输出恒低。
// 【待确认】蜂鸣器是无源的（要靠方波才响）还是有源的（给电平就响）、高电平还是低电平响。
//   现在按"无源、方波驱动"写：有源蜂鸣器被方波驱动通常也能响，只是音色会变。
//
// 【资源】节奏不再自带 10 位 ms 计数器（原来 25 LE）：timebase 的 250ms 计数器一圈就是 250ms 周期，
//   beat_100ms = 每圈前 100ms；再与上 blink_2hz（周期 500ms）、blink_1hz（周期 1000ms）
//   就得到 500ms / 1000ms 周期里的前 100ms。三者都从复位起同步走，不会错相。
module buzzer_ctrl(
	input clk,
	input rst,
	input tone_2k,				// 来自 timebase，约 2kHz 方波（省掉本模块的音调分频计数器）
	input beat_100ms,			// 来自 timebase：每个 250ms 段的前 100ms
	input blink_2hz,			// 来自 timebase：周期 500ms，每周期前 250ms 为高
	input blink_1hz,			// 来自 timebase：周期 1000ms，每周期前 500ms 为高
	input [1:0] phase,
	input [2:0] r_band,

	output reg buzzer
);

localparam P_SCAN = 2'd2;

reg sound;
always@(*) begin
	if (phase != P_SCAN)
		sound = 1'b0;
	else case (r_band)
		3'd1:    sound = beat_100ms && blink_2hz && blink_1hz;	// 1000ms 周期
		3'd2:    sound = beat_100ms && blink_2hz;				// 500ms 周期
		3'd3:    sound = beat_100ms;							// 250ms 周期
		3'd4:    sound = 1'b1;
		default: sound = 1'b0;
	endcase
end

always@(posedge clk or posedge rst) begin
	if (rst)
		buzzer <= 1'b0;
	else
		buzzer <= sound & tone_2k;
end

endmodule
