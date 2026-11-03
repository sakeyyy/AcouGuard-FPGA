# PYNQ Stream Validation Skill

面向 **PYNQ Overlay 与 AXI DMA 简单模式** 的接口契约、主机调用、黄金参考和报告工具包。源自四麦采集、DMA 停流和模型移植的工程经验，不依赖听障题目、AX7021 管脚或固定地址，可用于 FIR、FFT、传感器和向量运算。

入口：[SKILL.md](pynq-stream-validation/SKILL.md)。整个子目录可独立复制。离线工具需 Python 3.10+ 与 NumPy；实机调用才需要 PYNQ。技能子目录自编内容采用 MIT，其余工程许可不变。

## 快速使用

**赛事四类示例对应表、跨题目场景和换板步骤**见 [competition_mapping.md](pynq-stream-validation/references/competition_mapping.md)。本包属于“接口契约驱动的 PYNQ 流式 IP 验证与工程报告工具包”，四类示例均有代码/模板对应；真实 PYNQ 操作的验证状态单独列明。

从工程包根目录运行：

~~~powershell
python skill/pynq-stream-validation/scripts/stream_skill.py contract skill/pynq-stream-validation/examples/loopback.json
python skill/pynq-stream-validation/tests/test_stream_skill.py
python skill/pynq-stream-validation/tests/test_measurement.py --output sim/results/skill_measurement_tests.json
python skill/pynq-stream-validation/scripts/stream_skill.py generate skill/pynq-stream-validation/examples/loopback.json --output build/output/pynq_host
python skill/pynq-stream-validation/scripts/stream_skill.py reports --utilization build/reports/design_1_wrapper_utilization_placed.rpt --timing build/reports/design_1_wrapper_timing_summary_routed.rpt --output sim/results/implementation_metrics.json
~~~

生成骨架需同次导出的 BIT/HWH，并在 PYNQ 板端运行，不是加载裸机 ELF。详见 [工具说明](pynq-stream-validation/README.md)。

## 1. 接口契约、Overlay 预检与骨架

- **适用范围**：固定包长 AXI Stream IP、简单模式 DMA；单接收或同尺寸回环。
- **使用方法**：填写 examples 的 JSON；contract 检查字宽/通道/包长/长度上限，preflight 检查 BIT/HWH 与 DMA 元数据，generate 生成调用和参考测试。路径相对契约解析，不写死地址。
- **失效条件**：SG、VDMA、变长包、压缩流、多 DMA、部分 TKEEP 须扩展；HWH 参数缺失明确拒绝。同名不保证同次导出。
- **已验证效果**：软件回归覆盖 int32 回环、int16 双通道采集、合成 HWH 层级实例及错误配置；本题布局为 195328 字节。真实下载及 register_map 留给实机验收。
- **失败或观察来源**：旧硬件/主机包长混用、三麦扩四麦，引出显式契约与元数据检查；错误注入来自本次测试，不冒充历史日志。

## 2. DMA、缓存与超时诊断

- **适用范围**：PYNQ allocate 连续缓冲、AXI DMA 简单模式、固定长度单包。
- **使用方法**：receive_once 先 RX 后 TX/采集 arm，发送前 flush、接收后 invalidate，核对错误、超时及实际字节数。
- **失效条件**：TLAST/复位/时钟/长度/对齐/缓存不符合契约；连续流另需双缓冲。出错先停 DMA 再释放内存；停止失败时保留缓冲要求重载，防止写已释放内存。
- **已验证效果**：软件替身测试顺序、缓存调用、短包、超时、错误和停止失败；实际组包器 RTL 仿真验通道/符号扩展/背压/TLAST/连续包/溢出复位。物理 DDR、缓存一致性和带宽需 PYNQ 实机。
- **失败或观察来源**：首包后停止、复位常有效、旧同名组包器绑定、采集溢出，促使分层定位而非无限等待。

## 3. 黄金参考与资源时序报告

- **适用范围**：NPY 数值比对；Vivado utilization/timing summary 提取，可选同条件基线。
- **使用方法**：compare expected.npy actual.npy --atol ... --rtol ...；reports --utilization ... --timing ... --output ...。结果含 SHA-256；基线须自行确认同器件同约束。
- **失效条件**：shape/dtype 不同或 NaN/Inf 拒绝；整数精确比对。格式变化/字段缺失/不同次报告不能当完整验收，不从 WNS 推断实测延迟功耗。
- **已验证效果**：回归覆盖整数、浮点容差和异常输入；原报告解析为 LUT 8419、FF 4301、BRAM 26.5、DSP 25、WNS 0.769 ns，保留输入/输出 delay 缺失警告。未编造基线。
- **失败或观察来源**：PC/PS 差异不能只比标签；满足已设时序不等于外部接口完整约束。因此保留数值、哈希及警告。

## 4. 提示词与踩坑清单

- **适用范围**：大模型辅助软硬件划分、DMA 定位、模型移植和实验计划。
- **使用方法**：填入 [prompts.md](pynq-stream-validation/references/prompts.md) 的真实输入逐项验证，按 [排错表](pynq-stream-validation/references/troubleshooting.md) 操作；保存原始交互和纠错。
- **失效条件**：缺源码/日志/寄存器时只能提出假设；模板不是原始聊天，不自动证明正确。
- **已验证效果**：工程引用、模型常量和协议已有脚本记录；提示词为经验提炼，未做跨模型成功率统计。
- **失败或观察来源**：右后物理语义互换、三麦升级、文档落后固件、把模型当 Overlay；摘录见 report/llm_collaboration.md。

## 验证边界

新增寄存器字段与性能统计模块有5组独立软件测试，结果在 sim/results/skill_measurement_tests.json；上板材料比对与串口解复用等9组增补回归在 sim/results/submission_additions.json。它们使用软件对象、合成输入和模拟时钟，不填写真实PYNQ吞吐值。

sim/results/skill_tests.json 为软件回归，rtl_summary.json 为 RTL 仿真，implementation_metrics.json 为原报告解析；上板视频另见 report/onboard_test_record.md。PYNQ 清单见 [validation.md](pynq-stream-validation/references/validation.md)，未执行项不填写通过。加分由评审依据技能包与证据判定。
