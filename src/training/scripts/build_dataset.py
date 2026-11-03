from __future__ import annotations
import os
os.environ['OPENBLAS_NUM_THREADS']='1'
os.environ['OMP_NUM_THREADS']='1'
import argparse,csv,hashlib,json,random,time
from pathlib import Path
from typing import Any
from types import SimpleNamespace
from concurrent.futures import ThreadPoolExecutor
import joblib,numpy as np
from scipy.signal import butter,sosfilt
from fsd50k_audio_features import FeatureConfig,read_wav,extract_samples,split_windows
from fsd50k_sensitive_utils import extract_augmented_file,extract_sliding_file
PACKAGE=Path(__file__).resolve().parents[1]
CFG=FeatureConfig()
ROOT=None
def extract_record(
    row: dict[str, str],
    index: int,
    args: argparse.Namespace,
    config: FeatureConfig,
) -> dict[str, Any]:
    if row["split"] == "train":
        augmentation_count = (
            args.minority_augmentations
            if row["project_label"] in set(args.minority_label)
            else args.augmentations
        )
        features = extract_augmented_file(
            Path(row["path"]),
            config,
            args.train_windows,
            augmentation_count,
            args.seed + index * 7919,
        )
    else:
        features = extract_sliding_file(
            Path(row["path"]),
            config,
            args.evaluation_hop,
            args.evaluation_windows,
        )
    return {
        "features": features,
        "label": row["project_label"],
        "split": row["split"],
        "source_file": row["source_file"],
        "path": row["path"],
    }

def hard_record(row,index):
    part=ROOT/'data/extra_parts'/f'hard_{row["source_file"]}.joblib'
    if part.exists():return joblib.load(part)
    if row['split']=='train':
        values=extract_augmented_file(Path(row['path']),CFG,3,1,1701+index)
        _,audio=read_wav(Path(row['path']),16000)
        quiet=[extract_samples(w*.25,CFG) for w in split_windows(audio,CFG,2)]
        values=np.vstack([values,*quiet])
    else:values=extract_sliding_file(Path(row['path']),CFG,.5,12)
    r={'features':values,'label':'background','split':row['split'],
       'source_file':row['source_file'],'path':row['path'],'role':'ordinary_impact',
       'original_labels':row['original_labels']}
    tmp=part.with_suffix('.part');joblib.dump(r,tmp);tmp.replace(part)
    return r

def augmentation(row,index):
    part=ROOT/'data/extra_parts'/f'aug_{row["source_file"]}.joblib'
    if part.exists():return joblib.load(part)
    _,samples=read_wav(Path(row['path']),16000)
    rng=np.random.default_rng(93001+index)
    values=[]
    for window in split_windows(samples,CFG,2):
        low=float(rng.uniform(70,180));high=float(rng.uniform(4800,7400))
        filtered=sosfilt(butter(2,[low,high],btype='bandpass',fs=16000,output='sos'),window).astype(np.float32)
        delay=int(rng.uniform(.012,.055)*16000)
        filtered[delay:]+=float(rng.uniform(.10,.25))*filtered[:-delay].copy()
        filtered*=float(10**(rng.uniform(-15,2)/20))
        noise=np.sqrt(np.mean(filtered**2))*10**(-rng.uniform(18,35)/20)
        filtered+=rng.normal(0,noise,len(filtered)).astype(np.float32)
        peak=np.max(np.abs(filtered))
        if peak>.98:filtered*=.98/peak
        values.append(extract_samples(filtered,CFG))
    r={'features':np.vstack(values),'label':row['project_label'],'split':'train',
       'source_file':row['source_file'],'path':row['path'],'role':'device_augmentation',
       'original_labels':row['original_labels']}
    tmp=part.with_suffix('.part');joblib.dump(r,tmp);tmp.replace(part)
    return r

def main():
    global ROOT
    parser=argparse.ArgumentParser(description='Rebuild the latest training features from project FSD50K WAVs')
    parser.add_argument('--audio-root',type=Path,required=True,help='Directory containing FSD50K.dev_audio and FSD50K.eval_audio')
    parser.add_argument('--base-manifest',type=Path,default=PACKAGE/'data/base_manifest.csv')
    parser.add_argument('--negative-manifest',type=Path,default=PACKAGE/'data/negative_manifest.csv')
    parser.add_argument('--output',type=Path,default=PACKAGE/'data/features_rebuilt.joblib')
    parser.add_argument('--workers',type=int,default=3)
    parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args()
    if args.workers<1:parser.error('--workers must be positive')
    if args.output.exists() and not args.check_only:parser.error('Output exists; select a new --output')
    rows=[]
    for manifest in [args.base_manifest,args.negative_manifest]:
        with manifest.open(encoding='utf-8-sig',newline='') as f:group=list(csv.DictReader(f))
        for r in group:
            rel=Path(r['path'])
            if rel.is_absolute() or '..' in rel.parts:parser.error('Manifest path must be relative to --audio-root')
            r['path']=str(args.audio_root/rel)
        rows.append(group)
    original,hard=rows
    missing=[r['path'] for r in original+hard if not Path(r['path']).is_file()]
    if missing:parser.error('WAV files missing: '+str(missing[:5]))
    print('AUDIO CHECK',json.dumps({'base_files':len(original),'negative_files':len(hard),'missing':0}),flush=True)
    if args.check_only:return
    args.output.parent.mkdir(parents=True,exist_ok=True)
    digest=hashlib.sha256(args.base_manifest.read_bytes()+args.negative_manifest.read_bytes())
    for r in original+hard:
        st=Path(r['path']).stat();digest.update((r['path']+str(st.st_size)+str(st.st_mtime_ns)).encode())
    ROOT=args.output.parent/'build_cache'/digest.hexdigest()[:16]
    (ROOT/'data/extra_parts').mkdir(parents=True,exist_ok=True)
    settings=SimpleNamespace(minority_augmentations=4,minority_label=['bicycle_bell','car_horn'],augmentations=1,
        train_windows=3,evaluation_hop=.5,evaluation_windows=12,seed=42)
    def base_one(pair):
        i,row=pair;file=ROOT/('base_'+str(i)+'_'+row['source_file']+'.joblib')
        if file.exists():r=joblib.load(file)
        else:
            r=extract_record(row,i,settings,CFG);r['role']='base';r['original_labels']=row['original_labels']
            tmp=file.with_suffix('.part');joblib.dump(r,tmp,compress=3);tmp.replace(file)
        return r
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        base=list(pool.map(base_one,enumerate(original)))
        extra=list(pool.map(lambda p:hard_record(p[1],p[0]),enumerate(hard)))
    chosen=[];rng=random.Random(5021)
    for label in sorted({r['label'] for r in base}):
        candidates=[r for r in original if r['split']=='train' and r['project_label']==label]
        rng.shuffle(candidates);chosen.extend(candidates[:120 if label in ['dog_bark','human_shout'] else 50])
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        aug=list(pool.map(lambda p:augmentation(p[1],p[0]),enumerate(chosen)))
    records=base+extra+aug
    from validate_data import validate
    model=joblib.load(PACKAGE/'models/initial_model.joblib');checked=validate(records,model)
    for r in records:r['path']=Path(r['path']).parent.name+'/'+Path(r['path']).name
    tmp=args.output.with_suffix('.part');joblib.dump({'records':records},tmp,compress=3);tmp.replace(args.output)
    print('FEATURES READY',str(args.output),json.dumps(checked),flush=True)
if __name__=='__main__':main()
