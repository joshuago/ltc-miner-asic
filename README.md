# LTC Miner ASIC

This is a vibe-coded design for an scrypt miner ASIC. With an scrypt miner, one
can mine Litecoin and Dogecoin.

This was vibe-coded with a combination of various AI models, including:

  - DeepSeek V4 Pro
  - GLM 5.1
  - Qwen 3.6 Plus

DeepSeek V4 was used for the initial design. GLM and Qwen were applied to
perform design review. The pass to accept/reject the issues raised during
design review was performed by DeepSeek, and a final pass to clean up compiler
warnings was also done with DeepSeek.

I'm not a hardware engineer and barely remember much from my undergrad days.
But this compiles and simulates something.

This is a design to minimize power usage and maximize hashrate, built around
what is known of TSMC 3nm.

It's inspired by my past tinkering with Litecoin mining using my very loud and
power-hungry Antminer L3+.

Use at your own risk.

## Dependencies

This depends on [Verilator](https://www.veripool.org/verilator/).
