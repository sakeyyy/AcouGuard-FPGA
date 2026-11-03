"""Vitis 2026.1 Python API: create an isolated workspace, then build platform/app.
Run with the installed Vitis launcher: vitis -s build/rebuild_vitis.py
This builds against frozen release XSA unless --xsa selects a newly rebuilt one.
"""
from pathlib import Path
import argparse, json, shutil, time

def main():
    root=Path(__file__).resolve().parents[1]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xsa',type=Path,default=root/'board/artifacts/audio_platform.xsa')
    parser.add_argument('--workspace',type=Path)
    parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args()
    source=root/'src/vitis/audio_ps_ws/hearing_mlp/src'
    if not args.xsa.is_file():parser.error('XSA missing')
    files=[p for p in source.iterdir() if p.suffix in {'.c','.h','.ld'} or p.name=='UserConfig.cmake']
    if not (source/'main.c').exists():parser.error('Application source missing')
    if args.check_only:
        print(json.dumps({'xsa':str(args.xsa),'source_files':len(files),'operation':'check only; no Vitis invoked'}));return
    ws=args.workspace or root/'build/output'/time.strftime('vitis_%Y%m%d_%H%M%S')
    if ws.exists() and any(ws.iterdir()):parser.error('Build workspace must be new or empty')
    ws.mkdir(parents=True,exist_ok=True)
    import vitis
    client=vitis.create_client()
    try:
        client.set_workspace(path=str(ws.resolve()))
        platform=client.create_platform_component(name='audio_platform',hw_design=str(args.xsa.resolve()),
            os='standalone',cpu='ps7_cortexa9_0',domain_name='standalone_ps7_cortexa9_0')
        platform.build()
        xpfm=ws/'audio_platform/export/audio_platform/audio_platform.xpfm'
        if not xpfm.exists():raise RuntimeError('Platform export missing; inspect Vitis build output')
        app=client.create_app_component(name='hearing_mlp',platform=str(xpfm.resolve()),
            domain='standalone_ps7_cortexa9_0',template='empty_application')
        dest=ws/'hearing_mlp/src'
        for p in files:shutil.copy2(p,dest/p.name)
        app.build()
        elf=ws/'hearing_mlp/build/hearing_mlp.elf'
        if not elf.exists():raise RuntimeError('Application ELF missing; inspect Vitis output')
        (ws/'build_inputs.json').write_text(json.dumps({'xsa':str(args.xsa.resolve()),'application':str(source),'elf':str(elf)},indent=2))
        print('ELF:',elf)
    finally:
        vitis.dispose()

if __name__=='__main__':main()
