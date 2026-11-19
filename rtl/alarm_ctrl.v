// alarm_ctrl —— 16 个 LED（纯组合）
//   复位（SW7=0）：全灭。必须显式判断 rst：复位期间 phase 停在 SELFTEST、blink_2hz 复位值为 1，
//                  不判断的话会落进"自检全亮"分支（数码管/点阵是寄存器输出、复位清零，不存在这个问题）
//   SELFTEST：16 灯随 2Hz 闪
//   STANDBY ：全灭
//   SCAN    ：按已锁存的距离分级
//     band 0（≥800mm/超量程）→ 4 个蓝灯常亮
//     band 1（600~800）      → 4 个绿灯 2Hz 闪
//     band 2（400~600）      → 4 个黄灯 2Hz 闪
//     band 3（200~400）      → 4 个红灯 2Hz 闪
//     band 4（<200）         → 16 灯 2Hz 闪
//     band 7（尚无数据）      → 全灭
module alarm_ctrl(
	input rst,
	input [1:0] phase,
	input blink_2hz,
	input [2:0] r_band,

	output reg [15:0] ld
);

localparam P_SELFTEST = 2'd0,
           P_STANDBY  = 2'd1,
           P_SCAN     = 2'd2;

// LED 颜色分组（已上板确认）：LD3~0 蓝、LD7~4 绿、LD11~8 黄、LD15~12 红
localparam [15:0] MASK_BLUE   = 16'h000F,
                  MASK_GREEN  = 16'h00F0,
                  MASK_YELLOW = 16'h0F00,
                  MASK_RED    = 16'hF000;

wire [15:0] blink = {16{blink_2hz}};

always@(*) begin
	if (rst)
		ld = 16'h0000;
	else case (phase)
		P_SELFTEST: ld = blink;
		P_SCAN: begin
			case (r_band)
				3'd0:    ld = MASK_BLUE;
				3'd1:    ld = MASK_GREEN  & blink;
				3'd2:    ld = MASK_YELLOW & blink;
				3'd3:    ld = MASK_RED    & blink;
				3'd4:    ld = blink;
				default: ld = 16'h0000;
			endcase
		end
		default: ld = 16'h0000;
	endcase
end

endmodule
