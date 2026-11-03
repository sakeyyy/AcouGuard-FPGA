from collections import Counter
import numpy as np
EXPECTED=['background','bicycle_bell','car_horn','construction_tool','dog_bark','human_shout','impact_emergency','road_vehicle','siren_alarm']
def validate(records,artifact):
    if list(map(str,artifact['pipeline']['classifier'].classes_))!=EXPECTED:raise ValueError('Unexpected class order')
    if not records:raise ValueError('Empty features')
    ids={s:set() for s in ['train','val','eval']};counts=Counter();groups=Counter()
    for r in records:
        f=r['features'];split=r['split'];role=r['role']
        if split not in ids or r['label'] not in EXPECTED:raise ValueError('Bad split/label')
        if role not in ['base','ordinary_impact','device_augmentation']:raise ValueError('Bad feature role')
        if f.ndim!=2 or f.shape[1]!=160 or not len(f) or not np.isfinite(f).all():raise ValueError('Bad features')
        if role=='device_augmentation' and split!='train':raise ValueError('Augmentation outside train')
        ids[split].add(r['source_file']);counts[split]+=len(f);groups[(split,role)]+=1
    if ids['train']&ids['val'] or ids['train']&ids['eval'] or ids['val']&ids['eval']:raise ValueError('Source split leakage')
    for split in ['val','eval']:
        if not groups[(split,'base')] or not groups[(split,'ordinary_impact')]:raise ValueError('Missing validation/eval group')
    labels={r['label'] for r in records if r['split']=='train'}
    if labels!=set(EXPECTED):raise ValueError('Training classes missing')
    return {'records':len(records),'feature_size':160,'windows':dict(counts),'source_split_disjoint':True}
