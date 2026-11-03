# 上板运行

本目录的 artifacts 来自已运行工程。没有重新生成或修改 BIT、XSA、ELF。
视频位于 evidence/onboard_demo.mp4，时间点说明见 report/onboard_test_record.md。

## 赛题材料索引

- 上板工程与配套运行产物：artifacts/；完整 Vivado/Vitis 工程在 ../src/。
- 运行脚本：run_jtag.tcl；源码重建入口在 ../build/。
- 实测输出与参考行为对照：[validation/README.md](validation/README.md)、[比对表](validation/video_comparison.csv)、[比对报告](validation/comparison_report.md)。
- 新增原始串口采集入口：scripts/record_uart.py；按 validation/README.md 采集，保留原始字节与解析事件。

现有比对基于实物视频的人工观察，包含时间点与来源；完整UART/16kHz板端输入配对数据尚需新采集，不能用电脑侧仿真补成上板数值实测。

## 最短运行方式

1. 核对 hardware/wiring.md，使用可靠供电；麦克风和屏幕信号为 3.3 V。
2. 连接 AX7021 的 JTAG 和 USB-UART 两条数据线。串口驱动为 CP2102N；COM 号按本机设备管理器选择。
3. 在安装了 Vitis 2026.1 的命令环境中，从仓库根目录执行 `xsdb board/run_jtag.tcl`。
4. 脚本会复位、下载 FPGA、用匹配的 ps7_init.tcl 初始化 PS/DDR，并下载运行 hearing_mlp.elf。
5. UART1 使用 115200、8N1。出现 Ready 后运行网页；网页与其他串口助手不能同时占用同一 COM。

run_jtag.tcl 是本次新增的复现脚本，检查范围为 Tcl 结构与输入文件路径，未在整理电脑连接实体板执行。也可按下面的 Vitis GUI 流程使用同一套冻结文件。

## Vitis GUI 运行

在应用 Debug 的 Launch Configuration 中：Local、Baremetal Debug、Auto Detect；Bitstream 选 artifacts/design_1_wrapper.bit；初始化方式选 TCL，初始化文件选 artifacts/ps7_init.tcl；勾选 Run ps7_init、Run Ps7 Post Init、Reset Entire System、Program Device。应用选择 artifacts/hearing_mlp.elf，处理器为 ps7_cortexa9_0。启动后如停在 main，点击 Continue。

如果使用重新构建的 ELF，必须同时核对 XSA、BIT、初始化文件和 HW36/12208 帧契约。不要混用独立重建但未验收的新文件与原冻结文件。

## 操作功能

- 默认功能一二三：方向显示、环境声识别、网页监测。`VIEW:DIR` / `VIEW:ICON` 切换方向与类别图标，不改变模型。
- KEY1 为 PS MIO11，低有效。稳定短按后松开，在前三项功能与姓名模式间切换。
- 长按 KEY1 约 1.2 秒启动一轮姓名引导录入。进入录入后松开按键，按屏幕提示操作，无需每段重新长按。
- 安静校准后，SAY NAME 1/3～3/3：同一目标姓名各说一次；SAY OTHER 1/3～3/3：说其他姓名或不同短语。
- 每次说完保持安静，等待 SAVED 和下一步。完成校准进入 LISTEN，目标呼叫触发 CALL YOU 与振动提示。
- 正负样本过于接近、连续噪声、超长/超时等会停止或重试；SETUP STOPPED 时松开按键，换安静环境再长按。
- 姓名模板仅在 RAM，切换模式保留，掉电、复位或重新运行 ELF 后需重新录入。
- 姓名是声学模板匹配，不是语音转写或说话人认证。视频演示可运行，不代表任意说话人、任意距离均准确。

## 显示与振动的边界

命中姓名后的提示窗口约 2 秒，窗口内方向提示仍可能随声源变化；冷却约 3 秒。因此一次提示期间后续声音导致的振动变化，不必然是又识别出一次姓名。当前逻辑保持原工程。

fsbl.elf 为同平台备用启动组件；JTAG TCL 路径不依赖 FSBL。
