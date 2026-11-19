// servo_pwm —— SG90 舵机 PWM 发生器
// 50Hz（周期 20ms），高电平宽度决定角度：
//   0.5ms→0°  1.0ms→45°  1.5ms→90°  2.0ms→135°  2.5ms→180°
// en=0 时输出恒低（不发 PWM，舵机不动），用于自检阶段和复位态。
//
// 【资源】原来是 15 位 µs 计数器（0~19999）+ 12 位比较器 cnt < pulse_us，34 LE。
//   现在周期按 tick_1ms 数 20 个（5 位计数器），每个周期开头把 pulse_us 装进 12 位倒计数器，
//   倒计数非零期间输出高。顺带的好处：脉宽在周期开头锁定，周期中途 pulse_us 变化不会产生畸形脉冲。
module servo_pwm(
	input clk,					// 1MHz，1 个周期 = 1µs
	input rst,
	input tick_1ms,				// 来自 timebase
	input en,					// phase != SELFTEST
	input [11:0] pulse_us,		// 高电平持续时间，500~2500
	
	output reg servo
);

reg [4:0]  ms;					// 周期内第几 ms，0~19
reg [11:0] left;				// 本周期高电平还剩几 µs

always@(posedge clk or posedge rst) begin
	if (rst) begin
		ms    <= 0;
		left  <= 0;
		servo <= 1'b0;
	end
	else if (!en) begin
		ms    <= 0;
		left  <= 0;
		servo <= 1'b0;
	end
	else begin
		if (tick_1ms)
			ms <= (ms == 5'd19) ? 5'd0 : ms + 1'b1;
		
		// 周期开头（ms=0 的那个 tick）装入脉宽，之后每 µs 减 1；
		// servo 是寄存输出，left 非零的 pulse_us 个时钟里输出高，宽度正好 pulse_us µs
		if (tick_1ms && ms == 5'd0)
			left <= pulse_us;
		else if (left != 0)
			left <= left - 1'b1;
		
		servo <= (left != 0);
	end
end

endmodule
