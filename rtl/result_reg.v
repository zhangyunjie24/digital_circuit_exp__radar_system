// result_reg —— 测距完成时锁存本次结果
// 角度和距离在 done 的同一拍一起锁存，保证数码管上两者始终配套
// （不会出现"角度已经转到下一档、距离还是上一个方向"）。
// clear（restart 或 phase!=SCAN）时回到"尚无数据"：角度 000、距离 "----"、band=7。
module result_reg(
	input clk,
	input rst,
	input clear,
	input done,					// ultrasonic 测量完成脉冲

	input [11:0] angle_bcd,		// 当前角度（BCD）
	input [15:0] mm_bcd,
	input oor,
	input [2:0] band,

	output reg [11:0] r_angle_bcd,
	output reg [15:0] r_dist_bcd,
	output reg r_valid,			// 0=尚无数据
	output reg r_oor,
	output reg [2:0] r_band,	// 无数据时 = 7
	output reg r_strobe			// done 之后一拍：上面的 r_* 已更新
);

always@(posedge clk or posedge rst) begin
	if (rst) begin
		r_angle_bcd <= 12'h000;
		r_dist_bcd  <= 16'h0000;
		r_valid     <= 1'b0;
		r_oor       <= 1'b0;
		r_band      <= 3'd7;
		r_strobe    <= 1'b0;
	end
	else if (clear) begin
		r_angle_bcd <= 12'h000;
		r_dist_bcd  <= 16'h0000;
		r_valid     <= 1'b0;
		r_oor       <= 1'b0;
		r_band      <= 3'd7;
		r_strobe    <= 1'b0;
	end
	else begin
		r_strobe <= done;
		if (done) begin
			r_angle_bcd <= angle_bcd;
			r_dist_bcd  <= mm_bcd;
			r_valid     <= 1'b1;
			r_oor       <= oor;
			r_band      <= band;
		end
	end
end

endmodule
