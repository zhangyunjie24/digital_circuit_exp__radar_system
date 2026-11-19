// disp_ctrl —— 按阶段拼出 8 位数码管的显示内容（纯组合）
// 输出 digits[31:0]：8 个符号码，DISP7 在 [31:28]，DISP0 在 [3:0]
// 符号码：0~9=数字，A=横线"-"，F=空白
module disp_ctrl(
	input [1:0] phase,			// 0=SELFTEST, 1=STANDBY, 2=SCAN
	input blink_2hz,
	
	input [11:0] r_angle_bcd,	// 已锁存的角度 3位BCD
	input [15:0] r_dist_bcd,	// 已锁存的距离 4位BCD (mm)
	input r_valid,				// 0=尚无测量数据
	input r_oor,				// 1=本次超量程
	
	output reg [31:0] digits
);

localparam P_SELFTEST = 2'd0,
           P_STANDBY  = 2'd1,
           P_SCAN     = 2'd2;

localparam [3:0] SYM_DASH  = 4'hA,
                 SYM_BLANK = 4'hF;

wire dist_dash = (!r_valid) || r_oor;	// 距离显示 "----" 的条件

always@(*) begin
	case(phase)
		// 自检：8 位全 "8"，随 2Hz 闪烁
		P_SELFTEST:
			digits = blink_2hz ? 32'h8888_8888 : {8{SYM_BLANK}};
		
		// 待机：DISP7~5 = "000"，DISP4 空白，DISP3~0 = "----"
		P_STANDBY:
			digits = {4'h0, 4'h0, 4'h0, SYM_BLANK,
			          SYM_DASH, SYM_DASH, SYM_DASH, SYM_DASH};
		
		// 扫描：DISP7~5 = 角度，DISP4 空白，DISP3~0 = 距离(mm) 或 "----"
		P_SCAN:
			digits = {r_angle_bcd[11:8], r_angle_bcd[7:4], r_angle_bcd[3:0], SYM_BLANK,
			          dist_dash ? SYM_DASH : r_dist_bcd[15:12],
			          dist_dash ? SYM_DASH : r_dist_bcd[11:8],
			          dist_dash ? SYM_DASH : r_dist_bcd[7:4],
			          dist_dash ? SYM_DASH : r_dist_bcd[3:0]};
		
		default:
			digits = {8{SYM_BLANK}};
	endcase
end

endmodule
