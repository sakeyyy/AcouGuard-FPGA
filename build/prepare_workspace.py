"""Repair the copied Vitis platform's XSA pointer after moving the repository."""
from pathlib import Path
import json

root=Path(__file__).resolve().parents[1]
p=root/'src/vitis/audio_ps_ws/audio_platform/vitis-comp.json'
xsa=p.parent/'hw/audio_ps_4mic_NAME_GUIDED.xsa'
if not xsa.is_file():raise SystemExit('Platform-local XSA missing')
obj=json.loads(p.read_text(encoding='utf8'))
obj['configuration']['xsa']=xsa.resolve().as_posix()
p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
print('Open Vitis workspace:',p.parent.parent)
print('Then build audio_platform, then hearing_mlp. Generated BSP files may contain old absolute paths; rebuild the platform. For a fresh workspace use rebuild_vitis.py.')
