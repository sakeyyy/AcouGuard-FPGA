# 实测输出与参考行为对照

依据团队原始实物视频人工整理，不是统计准确率或逐样本板端黄金参考。

| 编号 | 功能 | 时间（秒） | 参考行为 | 观察输出 | 对照 |
|---|---|---|---|---|---|
| V01 | startup | 24-38 | lcd_running | lcd_running | observed_match |
| V02 | direction_haptics | 40-56 | direction_changes_with_source | direction_changes_with_source | observed_match |
| V03 | web_waveform | 60-86 | received_and_filtered_waveforms | received_and_filtered_waveforms | observed_match |
| V04 | classification_dog | 98-98 | dog_bark | dog_bark | observed_match |
| V05 | classification_vehicle | 106-106 | road_vehicle | road_vehicle | observed_match |
| V06 | classification_bell | 112-112 | bicycle_bell | bicycle_bell | observed_match |
| V07 | classification_horn | 118-118 | car_horn | car_horn | observed_match |
| V08 | name_enrollment | 125-151 | guided_positive_negative_enrollment | guided_positive_negative_enrollment | observed_match |
| V09 | target_name | 154-160 | call_you_alert | call_you_alert | observed_match |
| V10 | other_name | 167-172 | listen_without_new_alert | listen_without_new_alert | observed_match |

证据文件、观察方法、逐项限制与SHA-256见 comparison_summary.json；解释边界见 README.md。
未提供完整UART、16kHz模型输入配对数据；不得据此填报100%准确率、零误报或实测延迟。
