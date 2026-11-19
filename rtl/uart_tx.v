// uart_tx —— 9600bps 8N1 单字节发送器（只发不收）
// 1MHz / 9600 ≈ 104.17 → 每位 104 个 clk，累计误差约 0.16%，一帧 10 位完全在容差内
//
// 【资源】不用状态机和位计数器：send 时把 {停止位, 数据, 起始位} 装进 10 位移位寄存器，
//   每 104 个 clk 右移一位、高位补 0；tx 取最低位。寄存器剩下的就是"还没发完的位"，
//   全 0 即发完（停止位是最后一个 1，移出后寄存器全 0）。
module uart_tx(
	input clk,
	input rst,
	input [7:0] data,		// 待发字节
	input send,				// 单周期脉冲，仅在 busy=0 时被接受
	
	output busy,			// 起始位到停止位结束期间为高
	output tx				// 空闲/复位为高
);

localparam CLKS_PER_BIT = 104;

reg [9:0] frame;		// [0] 是正在发的位
reg [6:0] clk_cnt;

assign busy = (frame != 10'd0);
assign tx   = busy ? frame[0] : 1'b1;

always@(posedge clk or posedge rst) begin
	if (rst) begin
		frame   <= 0;
		clk_cnt <= 0;
	end
	else if (!busy) begin
		clk_cnt <= 0;
		if (send)
			frame <= {1'b1, data, 1'b0};
	end
	else if (clk_cnt == CLKS_PER_BIT - 1) begin
		clk_cnt <= 0;
		frame   <= frame >> 1;
	end
	else
		clk_cnt <= clk_cnt + 1'b1;
end

endmodule
