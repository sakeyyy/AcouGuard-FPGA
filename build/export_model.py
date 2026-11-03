"""Export same-architecture NPZ to C, keeping validated feature tables.
Outputs to a new directory. Never silently replaces the deployed model.
"""
from pathlib import Path
import argparse, json, re, hashlib
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'src/vitis/audio_ps_ws/hearing_mlp/src'

def arrays_from_c(text):
    result={}
    for name,size,body in re.findall(r'const float\s+(\w+)\[(\d+)\]\s*=\s*\{(.*?)\};',text,re.S):
        values=np.array([float(x.strip().removesuffix('f')) for x in body.split(',') if x.strip()],dtype=np.float32)
        if len(values)!=int(size):raise ValueError('C array size mismatch: '+name)
        result[name]=values
    return result

def model_arrays(npz):
    expected=['background','bicycle_bell','car_horn','construction_tool','dog_bark','human_shout','impact_emergency','road_vehicle','siren_alarm']
    if list(map(str,npz['classes']))!=expected:raise ValueError('Class order changed; update PL icons and PS label mapping before deployment')
    config=json.loads(str(npz['feature_config_json'].item()))
    reference={'sample_rate':16000,'frame_length':400,'hop_length':160,'fft_size':512,'mel_bins':40,'low_hz':50.0,'high_hz':7600.0,'clip_seconds':2.0,'pooling':'mean_std_max_delta'}
    if config!=reference:raise ValueError('Feature configuration changed; existing feature tables are incompatible')
    if int(npz['layer_count'])!=3:raise ValueError('Expected 3 network layers')
    values={}
    for key,shape in [('scaler_mean',(160,)),('scaler_scale',(160,)),('thresholds',(9,))]:
        a=np.asarray(npz[key],dtype=np.float32)
        if a.shape!=shape:raise ValueError('Invalid shape: '+key)
        values['model_'+key]=a
    for i,shape in enumerate([(160,128),(128,64),(64,9)]):
        w=np.asarray(npz[f'layer_{i}_weights'],dtype=np.float32)
        b=np.asarray(npz[f'layer_{i}_biases'],dtype=np.float32)
        if w.shape!=shape or b.shape!=(shape[1],):raise ValueError('Network dimensions changed')
        values[f'model_weights_{i}']=w.ravel(order='C');values[f'model_biases_{i}']=b
    if any(not np.isfinite(x).all() for x in values.values()):raise ValueError('Non-finite parameter')
    if np.any(values['model_scaler_scale']<=0):raise ValueError('Invalid scaler scale')
    return values,expected

def literal(value):
    token=format(float(value),'.9g')
    if not any(c in token.lower() for c in '.e'):token+='.0'
    return token+'f'

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,default=ROOT/'data/models/latest_model.npz')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--verify-only',action='store_true')
    args=p.parse_args()
    frozen=arrays_from_c((BASE/'model_data.c').read_text(encoding='utf8'))
    with np.load(args.model,allow_pickle=False) as data:values,classes=model_arrays(data)
    if args.verify_only:
        unequal=[name for name,a in values.items() if name not in frozen or not np.array_equal(a,frozen[name])]
        print(json.dumps({'compared_arrays':len(values),'equal_to_frozen_model':not unequal,'different_arrays':unequal}))
        if unequal:raise SystemExit(1)
        return
    if args.output.exists() and any(args.output.iterdir()):p.error('Output directory is not empty')
    args.output.mkdir(parents=True,exist_ok=True)
    values.update({name:frozen[name] for name in ['model_hann','model_mel_filters']})
    text=['/* Generated model parameters; row-major input x output weights. */','#include "model_data.h"']
    order=['model_scaler_mean','model_scaler_scale','model_thresholds','model_hann','model_mel_filters',
           'model_weights_0','model_biases_0','model_weights_1','model_biases_1','model_weights_2','model_biases_2']
    for name in order:
        a=values[name];text.append(f'const float {name}[{a.size}] = {{')
        for start in range(0,a.size,8):text.append('    '+', '.join(literal(x) for x in a[start:start+8])+(',' if start+8<a.size else ''))
        text.append('};')
    text.append('const char *const model_class_names[MLP_CLASSES] = {'+', '.join(json.dumps(s) for s in classes)+'};')
    output='\n'.join(text)+'\n'
    (args.output/'model_data.c').write_text(output,encoding='utf8')
    (args.output/'model_data.h').write_bytes((BASE/'model_data.h').read_bytes())
    reparsed=arrays_from_c(output)
    if not all(np.array_equal(reparsed[n],a) for n,a in values.items()):raise RuntimeError('Float32 round-trip failed')
    (args.output/'export_manifest.json').write_text(json.dumps({'npz_sha256':hashlib.sha256(args.model.read_bytes()).hexdigest(),'feature_tables':'copied from validated frozen C model; exact feature config required','float32_roundtrip':True},indent=2))
    print('EXPORTED',args.output)

if __name__=='__main__':main()
