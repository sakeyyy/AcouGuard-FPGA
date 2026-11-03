"""Repository entrypoint; algorithms remain in scripts/train.py."""
from pathlib import Path
import runpy,sys
root=Path(__file__).resolve().parents[2]
script=Path(__file__).parent/'scripts/train.py'
args=sys.argv[1:]
if not any(a=='--features' or a.startswith('--features=') for a in args):args+=['--features',str(root/'data/training/features.joblib')]
if not any(a=='--initial-model' or a.startswith('--initial-model=') for a in args):args+=['--initial-model',str(root/'data/models/initial_model.joblib')]
if '--check-only' not in args and not any(a=='--output' or a.startswith('--output=') for a in args):
 import time
 args+=['--output',str(root/'build/output'/time.strftime('train_%Y%m%d_%H%M%S'))]
sys.path.insert(0,str(script.parent));sys.argv=[str(script)]+args
runpy.run_path(str(script),run_name='__main__')
