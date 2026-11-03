"""Repository entrypoint for rebuilding features from external FSD50K WAVs."""
from pathlib import Path
import runpy,sys
root=Path(__file__).resolve().parents[2]
script=Path(__file__).parent/'scripts/build_dataset.py'
args=sys.argv[1:]
for flag,name in [('--base-manifest','base_manifest.csv'),('--negative-manifest','negative_manifest.csv'),('--output','features_rebuilt.joblib')]:
 if not any(a==flag or a.startswith(flag+'=') for a in args):args += [flag,str(root/'data/training'/name)]
sys.path.insert(0,str(script.parent));sys.argv=[str(script)]+args
runpy.run_path(str(script),run_name='__main__')
