# 基于 FPGA 异构加速的脑电信号处理与刺激控制系统

> 面向 SSVEP 脑机接口（BCI）的教学与研究原型。项目以 PYNQ-Z2 为平台，将 EEG 定点滤波和三目标空间投影部署到 FPGA 逻辑侧，并由 ARM 端完成采集调度、DMA 数据搬运和分类计算。
## 功能概览

- 通过串口接收 8 通道、500 Hz 脑电数据；其中 CH1 用于双眨眼触发，CH2–CH8 用于 SSVEP 分析。
- FPGA 端实现两级 Q24 定点 IIR 流式滤波和 7 通道到 3 个目标特征的空间投影。
- 通过 AXI DMA 在 PS DDR 与 PL 流处理链之间传输数据；AXI4-Lite 用于写入空间投影权重。
- 通过 HDMI 输出 7.5 Hz、10 Hz、12 Hz 的视觉刺激。
- PYNQ 端负责标定、特征相关性计算与结果输出；PC 端提供实时波形、SNR、通道状态和识别结果显示。

## 系统架构

```text
EEG 采集设备 ──串口──> PYNQ PS（ARM） ──AXI DMA──> PL（FPGA）
                         │                       │
                         │                 IIR → 空间投影
                         │                       │
                         └────<── AXI DMA ───────┘
                         │
                  相关性计算 / GPIO 控制 / UDP
                         │
PC 监控界面 <────────────┘              HDMI 刺激显示 <── PL
```

## 脑电采集设备要求

本仓库的实时运行流程**需要外接脑电采集设备**；PYNQ-Z2 本身不具备脑电模拟前端，不能直接采集人体脑电。仅运行 RTL testbench 或查看仿真波形时，不需要连接采集设备。

本项目代码对应的采集链路如下：

```text
电极 / 电极帽 → 8 通道脑电模拟前端（如 ADS1299 类采集板）
             → 采集控制器 / 串口桥接器（本项目为 ESP32 类串口链路）
             → USB 串口 → PYNQ-Z2 → FPGA 处理与 PC 显示
```

运行在线采集前，需要准备并正确连接以下设备：

- 8 通道脑电采集前端、配套电极与安全隔离的供电/连接方案；
- 能按项目协议输出数据的采集控制器或串口桥接器；
- PYNQ-Z2 开发板及其 USB 串口连接；
- 用于视觉刺激的 HDMI 显示器；
- 可选的 PC，用于运行实时监控界面。

当前 PYNQ 主控脚本的默认约定为：采样率 **500 Hz**、每个采样时刻 **8 个 `float32` 通道值**、串口设备名 `/dev/ttyACM0`、波特率 **1,000,000**。接收到的原始数据同时经 UDP 转发给 PC；CH1 用于双眨眼触发，CH2–CH8 作为 7 路 SSVEP 分析输入。实际采集板的帧头、校验、通道顺序、幅值单位和串口名必须与 `src/pynq/run_bci.py` 一致；更换采集设备时，应先修改并验证串口解析部分。

> 采集设备、电极连接和受试者实验不随本仓库提供。本项目仅用于教学和研究原型；真实人体采集前应完成电气隔离、安全检查、伦理审批与知情同意。

## 仓库内容

| 原始文件 | 建议仓库位置 | 用途 |
|---|---|---|
| `eeg_filter_top.txt` | `rtl/eeg_filter_top.v` | AXI-Stream 顶层，级联两级 IIR |
| `eeg_iir_biquad_tdm_7ch.txt` | `rtl/eeg_iir_biquad_tdm_7ch.v` | 7 通道时分复用二阶 IIR 滤波器 |
| `eeg_spatial_filter_3tgt.txt` | `rtl/eeg_spatial_filter_3tgt.v` | 7→3 目标空间投影及 AXI4-Lite 权重接口 |
| `SSVEP_Hardware_Generator.txt` | `rtl/SSVEP_Hardware_Generator.v` | HDMI SSVEP 刺激发生器 |
| `system_wrapper.txt` | `rtl/system_wrapper.v` | Block Design 生成的顶层封装 |
| `xdc.txt` | `constraints/top.xdc` | 管脚与时钟约束 |
| `tb/` | `sim/` | RTL 仿真测试平台 |
| `ps.txt` | `pynq/run_bci.py` | PYNQ 端主控：采集、DMA、标定和识别 |
| `pc.txt` | `pc_monitor/monitor.py` | PyQt5/pyqtgraph 上位机监控界面 |
| `project_1.xpr`、`project_1.srcs/` | `vivado/` | Vivado 工程与 Block Design/IP 配置 |
| `bci_stim.bit`、`bci_stim.hwh` | `overlay/` | PYNQ Overlay 配置与硬件描述文件 |

## 快速开始

### 1. 代码目录

```text
fpga-eeg-ssvep/
├─ board/
├─ build/
├─ data/
├─ report/
├─ sim/
├─ skill
    ├─README.md 
├─ src/
└─ README.md
```

### 2. 在 Vivado 中构建硬件

1. 使用与工程 IP 兼容的 Vivado 版本打开 `vivado/project_1.xpr`。
2. 检查 PYNQ-Z2 板卡、时钟、HDMI 引脚和 Block Design 的 IP 配置。
3. 依次执行 **Generate Bitstream**，随后从实现结果导出硬件描述文件。
4. 将同一次构建得到的 `.bit` 和 `.hwh` 一起放入 `overlay/`。

请勿混用不同构建目录或不同版本生成的 `.bit` 与 `.hwh`。

### 3. 部署到 PYNQ-Z2

将 `bci_stim.bit`、`bci_stim.hwh` 与重命名后的 `run_bci.py` 上传到 PYNQ。PYNQ 端脚本依赖如下：

```bash
pip install numpy scipy pyserial
```

在 PYNQ 镜像中还需要可用的 `pynq` Python 包。启动前，请先根据实际硬件修改脚本中的 Overlay 路径、串口名、PC IP 地址和端口号。

DMA 数据格式为：输入 `int32`、Q24、有符号、时间优先排列 `t0:[ch1..ch7], t1:[ch1..ch7], ...`；输出为 `t0:[z1,z2,z3], ...`。常用分析窗口为 1000 点，即 500 Hz 下的 2 秒。

### 4. 启动 PC 监控端

PC 端依赖：

```bash
pip install numpy PyQt5 pyqtgraph pyserial
python pc_monitor/monitor.py
```

确保 PC 与 PYNQ 的网络地址、UDP 端口与两端脚本配置一致。

## AXI 接口约定

- **AXI4-Stream：** `TDATA[31:0]` 为有符号 Q24 数据；只有 `TVALID && TREADY` 时才传输和推进状态；数据在反压期间必须保持稳定。
- **DMA：** 先调用 `recvchannel.transfer()`，再调用 `sendchannel.transfer()`；传输完成后再读取输出缓冲区。
- **TLAST：** 表示一个 DMA 包的结束。其具体位置必须与 DMA 缓冲区长度一致。
- **AXI4-Lite：** 三组、每组 7 个空间投影权重的字节偏移基址为 `0x00`、`0x1C`、`0x38`，每项间隔 4 字节；负数以 32 位补码写入。

## 验证与已知限制

- 本仓库用于原型复现、课程设计与研究交流，不可用于临床诊断、治疗或安全关键刺激控制。
- 在使用真实被试数据前，应取得相应的伦理审批、知情同意并执行电气安全与隔离措施。
- 当前归档的实现报告曾出现负裕量（WNS −6.529 ns、TNS −2883.098 ns）。因此，**已生成 `.bit` 文件不等于已完成时序收敛**；修改或复现工程时必须重新检查实现报告、CDC 和板级实测结果。

## 复现检查清单

- [ ] `.bit` 与 `.hwh` 来自同一次 Vivado 构建。
- [ ] Vivado Block Design 中 DMA、GPIO、IIR、空间投影与 HDMI IP 连接正确。
- [ ] AXI 时钟域与 HDMI 像素时钟域之间使用了正确的 CDC 结构。
- [ ] DMA 输入输出缓冲区的长度、符号位、Q24 缩放和通道顺序与 RTL 一致。
- [ ] 修改 RTL、约束或 Block Design 后，重新进行仿真、时序分析和板级验证。

## 许可证与贡献

当前代码包未附带许可证。公开仓库前，请由项目所有者补充适用的开源许可证，并确认第三方 IP、板卡文件和实验数据的再分发权限。

欢迎通过 Issue 反馈复现问题；提交 PR 时请同时说明 Vivado/PYNQ 版本、板卡型号、改动的接口约定以及时序报告结果。
