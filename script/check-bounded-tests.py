#!/usr/bin/env python3
"""Run every test in <=3-file partitions, one worker, 3 GiB process address cap.

Coordinate the shared heavy-gate slot first. This never stops services and is
not the infra Docker wrapper. RPC is blanked so the fork is explicitly skipped.
"""
import pathlib,subprocess,json,time,re,os,tempfile,sys
config=json.loads(subprocess.check_output(['forge','config','--json'],text=True))
assert all(config[k]==v for k,v in {'solc':'0.8.24','optimizer':True,'optimizer_runs':200,'via_ir':True}.items())
assert config['fuzz']['runs']==10000 and config['invariant']['runs']==1000 and config['invariant']['depth']==100
logs=pathlib.Path(tempfile.mkdtemp(prefix='pm-contracts-gate-'))
print('Evidence:',logs,flush=True)
files=sorted(str(p) for p in pathlib.Path('test').rglob('*.t.sol'))
assert files, "No tests discovered"
results=[]
for i in range(0,len(files),3):
 selected=files[i:i+3]
 args=['prlimit','--as=3221225472','--','forge','test','--threads','1','--offline','--skip','script/**']
 for p in files:
  if p not in selected:args+=['--skip',p]
 log=str(logs/f'partition-{i//3:02}.log')
 env=dict(os.environ);env['BASE_SEPOLIA_RPC_URL']=''
 start=time.monotonic()
 with open(log,'w') as out:run=subprocess.run(args,stdout=out,stderr=subprocess.STDOUT,env=env)
 text=pathlib.Path(log).read_text()
 counts=re.findall(r'(\d+) tests passed, (\d+) failed, (\d+) skipped',text)
 result={'selected':selected,'exit':run.returncode,'seconds':round(time.monotonic()-start,2),'counts':list(map(int,counts[-1])) if counts else None,'log':log}
 results.append(result)
 (logs/'results.json').write_text(json.dumps(results,indent=2)+'\n')
 print(json.dumps(result),flush=True)
 if run.returncode:sys.exit(run.returncode)
 if not counts:raise SystemExit("Missing test summary; cannot claim partition pass")
 covered=set(re.findall(r"Ran \d+ tests? for ([^:]+):",text))
 if not set(selected)<=covered:raise SystemExit("Selected test file absent from execution output")
print("PASS: all",len(files),"test files covered; external fork skipped",flush=True)
