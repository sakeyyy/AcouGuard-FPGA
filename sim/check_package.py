"""Standard-library-only source, artifact and release-integrity checks."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,zipfile,xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[1]
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--skip-manifest',action='store_true')
    p.add_argument('--output',type=Path);args=p.parse_args()
    project=root/'src/vivado/test'
    refs=[]
    for e in ET.parse(project/'test.xpr').iter('File'):
        path=e.attrib['Path'].replace('$PSRCDIR',str(project/'test.srcs')).replace('$PGENDIR',str(project/'test.gen'))
        target=Path(path)
        if not target.exists():raise RuntimeError('Missing Vivado reference: '+path)
        if not target.resolve().is_relative_to(root.resolve()):raise RuntimeError('External Vivado reference: '+path)
        refs.append(path)
    art=root/'board/artifacts'
    bit=sha(art/'design_1_wrapper.bit')
    with zipfile.ZipFile(art/'audio_platform.xsa') as z:
        names=[n for n in z.namelist() if n.endswith('.bit')]
        if len(names)!=1 or hashlib.sha256(z.read(names[0])).hexdigest()!=bit:raise RuntimeError('XSA and BIT mismatch')
        if z.read('ps7_init.tcl')!=(art/'ps7_init.tcl').read_bytes():raise RuntimeError('PS initialization mismatch')
    local=root/'src/vitis/audio_ps_ws/audio_platform/hw/audio_ps_4mic_NAME_GUIDED.xsa'
    if sha(local)!=sha(art/'audio_platform.xsa'):raise RuntimeError('Platform XSA mismatch')
    expected='b93ede31a2b4832b9cda402780bc2685a5dff993b2aed2db5d6ed8f9d5f52dce'
    if sha(root/'src/vitis/audio_ps_ws/hearing_mlp/src/model_data.c')!=expected:raise RuntimeError('Frozen model changed; update release evidence before publication')
    checked=0
    manifest=root/'release_manifest.json'
    if manifest.exists() and not args.skip_manifest:
        listed=set()
        for record in json.loads(manifest.read_text(encoding='utf8'))['files']:
            f=root/record['path']
            if not f.resolve().is_relative_to(root.resolve()):raise RuntimeError('Unsafe manifest path')
            if record['path'] in listed:raise RuntimeError('Duplicate manifest path')
            listed.add(record['path'])
            if not f.is_file() or f.stat().st_size!=record['bytes'] or sha(f)!=record['sha256']:raise RuntimeError('Manifest mismatch: '+record['path'])
            checked+=1
        spec=importlib.util.spec_from_file_location('release_manifest_rules',root/'build/update_manifest.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        actual={f.relative_to(root).as_posix() for f in root.rglob('*')
                if f.is_file() and not module.excluded(f.relative_to(root))}
        if actual!=listed:raise RuntimeError('Manifest coverage mismatch: '+repr(sorted(actual^listed)))
    result={'vivado_references':len(refs),'external_references':0,'xsa_bit_init_match':True,'frozen_model_match':True,'manifest_files_checked':checked}
    if args.output:
        if args.output.resolve()!=(root/'sim/results/release_check.json').resolve():raise ValueError('Use sim/results/release_check.json to avoid self-hash cycles')
        args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
    print(json.dumps(result))

if __name__=='__main__':main()
