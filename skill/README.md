# Zynq AXI EEG

用于 Zynq 或 PYNQ 平台上 AXI4-Lite、AXI-Stream 与 AXI DMA 数据链的设计、集成和调试，重点面向定点 EEG 处理 IP。

## 适用场景

- 为自定义 RTL 添加 AXI4-Lite 配置寄存器或 AXI-Stream 输入输出
- 在 Vivado Block Design 中连接 PS、AXI DMA 和自定义 IP
- 约定 PS 缓冲区与 PL 流接口的数据宽度、格式、顺序和 `TLAST`
- 排查 DMA 卡死、数据错位、握手丢拍、寄存器读写异常、CDC 或时序问题
- 编写 PYNQ 的 `Overlay`、`MMIO` 与 DMA 收发程序

不用于不含 AXI 边界的普通 HDL 功能设计，也不替代器件或协议的官方手册。

## 调用方式

```text
使用 $zynq-axi-eeg 检查这个 AXI-Stream FIR 模块的 TVALID/TREADY/TLAST 是否正确。
使用 $zynq-axi-eeg 为 7 通道 EEG 空间滤波器设计 AXI-Lite 寄存器表和 PYNQ 控制代码。
使用 $zynq-axi-eeg 排查 DMA 发送完成但接收一直等待的问题。
```

## 使用时需要提供的信息

至少明确以下内容：

1. 每个接口的时钟、复位和所属时钟域。
2. AXI 类型、主从角色、数据位宽，以及 `TKEEP`、`TLAST`、`TUSER` 等边带信号的含义。
3. 数据类型、定点缩放、饱和或舍入规则、DMA 缓冲区形状与通道顺序。
4. AXI-Stream 数据包边界，以及 `TLAST` 表示单个样本组还是整次 DMA 传输结束。
5. AXI4-Lite 的寄存器地址、复位值、读写属性和软件换算规则。
6. 期望的验证方式：testbench、ILA、CDC 报告、时序报告或板端日志。

## 本项目默认约定

该 Skill 为当前 PYNQ-Z2 EEG 工程附带一份项目约定：

- AXI/EEG 处理时钟为 125 MHz，HDMI 像素时钟为 148.5 MHz。
- 输入流为 32 位有符号 Q24 数据，时间优先排列：`t0:[ch1..ch7]`。
- 空间投影输出为 `t0:[z1,z2,z3]`，同样为 32 位有符号 Q24 数据。
- 常用窗口为 2 s、500 Hz，即 DMA 输入 `1000×7`，输出 `1000×3`。
- 三组空间权重共 21 个 Q24 寄存器，基地址依次为 `0x00`、`0x1C`、`0x38`。

这些是该工程的现状约定，而不是 AXI 的通用限制。复用前应核对当前 RTL、Block Design 和 PS 程序。

## 关键协议约束

- AXI4-Lite 的写地址与写数据通道必须能独立握手；`BVALID`、`RVALID` 及其对应数据/响应必须保持到握手完成。
- AXI-Stream 仅在 `TVALID && TREADY` 时传输。背压期间，发送端必须保持数据、`TLAST` 和边带信号稳定。
- 状态机、通道指针和累加器只能在成功握手时推进。
- 连续数据跨 125 MHz 与 148.5 MHz 时钟域时需要异步 FIFO 或 AXI Clock Converter；双触发器只适合单比特控制信号。
- DMA 接收通道应先启动，再启动发送通道；读写 DMA 的长度必须与 RTL 包边界相符。
- 成功生成 bitstream 不代表设计已经定型，必须检查 CDC 与路由后 WNS/TNS。

## 验证最小闭环

1. 用已知输入在 testbench 中验证输出值、输出拍数和 `TLAST`。
2. 在 `TREADY` 间歇拉低时验证输入/输出数据不会错位或丢失。
3. 在 PYNQ 端检查 DMA 缓冲区长度、dtype 与 reshape 顺序。
4. 用 ILA 观察 `TVALID`、`TREADY`、`TLAST`、复位和关键状态计数器。
5. 运行 CDC 和实施后时序分析；只有相关路径无违例时才宣称时序收敛。

## 目录

```text
zynq-axi-eeg/
├── SKILL.md                              # Codex 的工作指引
├── README.md                             # 使用说明
```
