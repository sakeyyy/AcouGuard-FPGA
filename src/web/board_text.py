"""Recognize only exact, unframed board text, never a valid PCM payload."""
LABELS = {
    'background': '背景声', 'bicycle_bell': '自行车铃',
    'car_horn': '汽车鸣笛', 'construction_tool': '施工工具',
    'dog_bark': '犬吠', 'human_shout': '呼喊或尖叫',
    'impact_emergency': '爆炸、枪声或碎裂冲击',
    'road_vehicle': '道路车辆声', 'siren_alarm': '警笛或警报',
}


class BoardTextReader:
    def __init__(self, publish):
        self.publish = publish
        self.line = bytearray()

    def feed(self, data):
        for value in data:
            if value == 10:
                line = bytes(self.line).decode('ascii').strip()
                self.line.clear()
                if line.startswith('Sound: '):
                    label = line[7:]
                    if label in LABELS:
                        self.publish({'type': 'recognition', 'label': label, 'name': LABELS[label]})
                elif line.startswith(('CAPTURE FAILED', 'DMA ERROR', 'TIMEOUT ',
                                      'WRONG HARDWARE', 'Init failed', 'Inference failed',
                                      'DMA rearm failed', 'WAVE UART', 'WAVE filter')):
                    self.publish({'type': 'board_error', 'message': line})
            elif value == 13 or value == 9 or 32 <= value <= 126:
                if len(self.line) >= 256:
                    self.line.clear()
                self.line.append(value)
            else:
                self.line.clear()
