# 上板工程与实测对照

## 材料完整性

| 赛题材料 | 本包位置 | 当前覆盖 |
|---|---|---|
| 上板工程 | board/artifacts 的 BIT、XSA、PS 初始化、应用 ELF；完整工程在 src/vivado 与 src/vitis | 提供配套运行产物与源码，不只有单个 .v |
| 运行脚本 | board/run_jtag.tcl | 复位、下载 PL、初始化 PS/DDR、运行应用；需安装 XSDB 和连接实体板 |
| 实测输出 | board/evidence/onboard_demo.mp4 与 frames | 团队原始实物视频/截图；不是本次电脑上重做的实验 |
| 实测与参考比对 | video_comparison.csv、comparison_summary.json、comparison_report.md | 10 条按视频人工整理的预期行为与观察对照，含证据、时间、来源与限制 |
| 新实测数据采集 | board/scripts/record_uart.py | 保存串口原始字节、文字事件、PCM包元数据及固件哈希；待连接实体板执行 |
| 数值黄金参考 | sim/results/ps_regression.json、current_software_checks.json、rtl_summary.json | 主机C数值、模型参数和RTL验证；不冒充板端原始数值输出 |

## 重新生成现有视频对照报告

从工程根目录运行：

~~~powershell
python board/scripts/compare_observations.py
~~~

该命令检查表格、证据文件和源文件，比较 reference/observed 字段，输出本目录的 JSON 与 Markdown。现有10条记录来自 report/onboard_test_record.md 的视频摘录，测试输入依据视频字幕/演示说明。它们是人工观察记录，不是自动从像素或声音识别得到的真值。字段一致只表示这些片段中的行为一致，不能解释成10次独立分类测试全对、准确率100%、误报率0或延迟达标。方向/马达的动作依据视频与圈注，无电流或角度传感器数据。

原始测试声源 WAV、每次独立试验的板端全速 PCM、完整串口日志、逐样本 PC/板端配对输出未随视频提供，不能从图标反推出这些数据。这里已补齐可追踪的定性比对；若评审要求数值实测比对，仍须按下节补测。

## 采集下一轮原始串口记录

1. 连接板卡，关闭网页和串口助手，避免占用同一端口。确认使用本包配套固件，按 board/README.md 下载运行。
2. 安装 src/web/requirements.txt 的依赖。在工程根目录执行，例如：

~~~powershell
python board/scripts/record_uart.py --port COM3 --seconds 120 --output board/measurements/run_001
~~~

3. 依次播放独立测试声源，记录名称/标签、文件SHA-256、播放起止时刻、距离、音量和噪声条件，使用 data/onboard_test_template.csv。同一标签若不重复输出，不应只靠“有无新文字”判断漏检。
4. 脚本只读取串口，不发送控制指令。它保存原始 uart.bin、文本 events.jsonl、PCM包信息 packets.jsonl、采集 summary.json；板端4kHz CH0显示流不等于16kHz模型输入，也不等于四路原始采集。
5. 比较时优先使用明确的实验编号关联预期和输出，不能按电脑接收时间冒充精确的板端推理时间。采集文件的主机时间含串口/系统缓冲延迟。
6. 要做逐样本 C/PC 黄金参考，需额外导出同一16kHz分类输入或中间特征，再用技能的 compare 工具比对；本记录器不会自动生成这些板端数据。

录制目录默认不覆盖已有文件，Ctrl+C 会正常关闭并保存摘要。summary 中固件哈希只说明本地文件版本，不能证明实际板上运行的固件身份；需同时保留下载日志与启动HW签名。未执行采集前，不在 measurements 目录放虚构日志。
