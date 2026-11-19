// dist_band —— 距离分级（纯组合）
// band：0=≥800mm或超量程，1=600~800，2=400~600，3=200~400，4=<200
// 边界都是整百，只看千位/百位 BCD 即可，不用比较器。
module dist_band(
	input [15:0] mm_bcd,		// 4 位 BCD（mm）
	input oor,					// 超量程 / 无回波

	output reg [2:0] band
);

wire [3:0] d3 = mm_bcd[15:12];	// 千位
wire [3:0] d2 = mm_bcd[11:8];	// 百位

always@(*) begin
	if (oor || d3 != 4'd0 || d2 >= 4'd8)
		band = 3'd0;
	else if (d2 >= 4'd6)
		band = 3'd1;
	else if (d2 >= 4'd4)
		band = 3'd2;
	else if (d2 >= 4'd2)
		band = 3'd3;
	else
		band = 3'd4;
end

endmodule
