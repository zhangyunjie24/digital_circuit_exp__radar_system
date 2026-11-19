// sys_fsm —— 顶层状态机
// SELFTEST(2s) → STANDBY(2s) → SCAN(常驻)
// OFF 不是一个真实状态，而是 rst=1 的复位态
// SCAN 阶段内部再分 SCAN_STEP / SCAN_CONT，由 mode_cont 表示
module sys_fsm(
	input clk,
	input rst,
	input phase_tick,		// 来自 scan_engine：每 2 秒一个脉冲（只在 scan_en=0 时有）
	input btn_pulse,		// 模式切换键的单周期脉冲
	
	output reg [1:0] phase,	// 0=SELFTEST, 1=STANDBY, 2=SCAN
	output reg mode_cont,	// 0=SCAN_STEP, 1=SCAN_CONT；复位为 0
	output reg restart		// 单周期脉冲：模式切换时产生，用于打断并清空扫描状态
);

localparam P_SELFTEST = 2'd0,
           P_STANDBY  = 2'd1,
           P_SCAN     = 2'd2;

// 自检 / 待机各 2 秒的计时由 scan_engine 的 ms_cnt 提供（phase_tick），这里不再自带计数器

always@(posedge clk or posedge rst) begin
	if (rst)
		phase <= P_SELFTEST;
	else if (phase_tick && phase != P_SCAN)
		phase <= phase + 1'b1;
end

always@(posedge clk or posedge rst) begin
	if (rst) begin
		mode_cont <= 1'b0;
		restart   <= 1'b0;
	end
	else if (btn_pulse && phase == P_SCAN) begin
		mode_cont <= ~mode_cont;
		restart   <= 1'b1;
	end
	else
		restart <= 1'b0;
end

endmodule
