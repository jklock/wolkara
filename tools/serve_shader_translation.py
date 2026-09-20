#!/usr/bin/env python3
"""Serve shader compilation requests over the connected iPad's app container.

No network listener: devicectl transfers only generated shader requests/results.
Keep this running while launching the native guest with --translate-shaders.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
from translate_metallib import compiler_path,translate
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import localenv
BUNDLE_ID=localenv.bundle_id()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--device',required=True);p.add_argument('--seconds',type=int,default=1800);a=p.parse_args()
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    root=Path('build/shader-translation/service');root.mkdir(parents=True,exist_ok=True)
    compiler=compiler_path(); completed=set(); deadline=time.monotonic()+a.seconds
    def copy(direction,source,destination):
        return subprocess.run(['xcrun','devicectl','device','copy',direction,'--device',a.device,
            '--domain-type','appDataContainer','--domain-identifier',BUNDLE_ID,
            '--source',str(source),'--destination',str(destination)],capture_output=True,text=True,timeout=30)
    print('Shader compiler ready over USB/app-container transfer',flush=True)
    while time.monotonic()<deadline:
        try:
            request=root/'request.json'
            request.unlink(missing_ok=True)  # force a fresh read even for equal-size jobs
            if copy('from','Documents/shader-request.json',request).returncode:
                time.sleep(.5);continue
            job=json.loads(request.read_text());key=job.get('sha256','')
            if not re.fullmatch('[a-f0-9]{64}',key): raise ValueError('invalid shader request hash')
            if key in completed: time.sleep(.25);continue
            start=time.monotonic();source=root/(key+'.input.metallib');output=root/(key+'.metallib')
            got=copy('from','Documents/ShaderRequests/'+key+'.metallib',source)
            if got.returncode: raise RuntimeError(got.stderr)
            import hashlib
            if hashlib.sha256(source.read_bytes()).hexdigest()!=key: raise ValueError('request content hash mismatch')
            try:
                if not output.exists(): report=translate(source,output,compiler)
                else: report={'original_sha256':key,'cached':True}
                sent=copy('to',output,'Documents/TranslatedShaders/'+key+'.metallib')
                if sent.returncode: raise RuntimeError(sent.stderr)
                # Publish completion only after the library transfer succeeds.
                # The device verifies length and digest before opening the cache.
                metadata=root/(key+'.metallib.json')
                compiled=output.read_bytes()
                metadata.write_text(json.dumps({'length':len(compiled),'sha256':hashlib.sha256(compiled).hexdigest()}))
                ready=copy('to',metadata,'Documents/TranslatedShaders/'+metadata.name)
                if ready.returncode: raise RuntimeError(ready.stderr)
                print(json.dumps({**report,'elapsed_seconds':round(time.monotonic()-start,2)}),flush=True)
            except Exception as error:
                detail=str(error)
                if isinstance(error,subprocess.CalledProcessError): detail+='\n'+error.stderr.decode(errors='replace')
                failure=root/(key+'.error');failure.write_text(detail)
                copy('to',failure,'Documents/TranslatedShaders/'+key+'.error')
                print('Translation failed: '+key+' '+detail,flush=True)
            completed.add(key)
        except (ValueError,OSError,subprocess.SubprocessError,RuntimeError) as error:
            print('Transfer pending: '+str(error),flush=True);time.sleep(1)
    return 0
if __name__=='__main__':raise SystemExit(main())
