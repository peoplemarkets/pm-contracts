#!/usr/bin/env python3
"""Compare compiler layouts with origin/main; never reads RPC or deployed state.

Run from the repository root. Set SOLC to a Solidity 0.8.24 compiler if needed.
Only the known trailing PauseGuardian array expansion is accepted.
"""
import json,os,pathlib,re,subprocess,posixpath
solc=os.environ.get('SOLC',str(pathlib.Path.home()/'.local/share/svm/0.8.24/solc-0.8.24'))
remaps={'@openzeppelin/contracts/':'lib/openzeppelin-contracts/contracts/','@openzeppelin/contracts-upgradeable/':'lib/openzeppelin-contracts-upgradeable/contracts/','solady/':'lib/solady/src/'}
def build(ref):
 sources={}
 def add(path):
  if path in sources:return
  if ref and path.startswith('src/'):
   content=subprocess.check_output(['git','show',ref+':'+path],text=True)
  else:content=pathlib.Path(path).read_text()
  sources[path]={'content':content}
  for imp in re.findall(r'import\s+(?:[^;]*?from\s+)?[\"\x27]([^\"\x27]+)',content):
   if imp.startswith('.'): p=posixpath.normpath(posixpath.join(posixpath.dirname(path),imp))
   else:
    p=imp
    for prefix,target in remaps.items():
     if p.startswith(prefix):p=target+p[len(prefix):];break
   add(p)
 layout_paths = [str(p) for p in pathlib.Path('src').rglob('*.sol') if 'struct Layout' in p.read_text() and p.name != 'StorageLib.sol' and subprocess.run(['git','cat-file','-e','origin/main:'+str(p)], capture_output=True).returncode == 0]
 for p in ['src/libraries/StorageLib.sol','src/events/EventMarket.sol'] + layout_paths: add(p)
 libs=re.findall(r'library\s+(\w+)\s*\{',sources['src/libraries/StorageLib.sol']['content'])
 harness='pragma solidity 0.8.24; import "src/libraries/StorageLib.sol";\n' + ''.join('import "'+p+'";\n' for p in layout_paths)
 for lib in libs+[pathlib.Path(p).stem for p in layout_paths]:
  harness+=f'contract {lib}Harness {{ {lib}.Layout internal state; }}\n'
 sources['LayoutHarness.sol']={'content':harness}
 args={'language':'Solidity','sources':sources,'settings':{'evmVersion':'cancun','remappings':[k+'='+v for k,v in remaps.items()],'outputSelection':{'*':{'*':['storageLayout']}}}}
 run=subprocess.run([solc,'--standard-json'],input=json.dumps(args),text=True,capture_output=True)
 out=json.loads(run.stdout)
 errors=[e['formattedMessage'] for e in out.get('errors',[]) if e['severity']=='error']
 if errors:raise Exception(errors)
 return out['contracts']
a,b=build('origin/main'),build(None)
checks=0;expansions=[]
def compare_types(old,new,ot,nt,path):
 global checks
 x,y=old[ot],new[nt]
 assert x['encoding']==y['encoding'],path
 if 'members' in x:
  assert len(y['members'])>=len(x['members']),path
  for m,n in zip(x['members'],y['members']):
   assert (m['label'],m['slot'],m['offset'])==(n['label'],n['slot'],n['offset']), (path,m,n)
   checks+=1;compare_types(old,new,m['type'],n['type'],path+'.'+m['label'])
 elif 'key' in x:
  compare_types(old,new,x['key'],y['key'],path+'.key');compare_types(old,new,x['value'],y['value'],path+'.value')
 elif 'base' in x:
  if x['numberOfBytes']!=y['numberOfBytes']:
   assert path.endswith('.rings.value.entries') and x['label'].endswith('[128]') and y['label'].endswith('[721]'),path
   expansions.append(path)
  compare_types(old,new,x['base'],y['base'],path+'[]')
 else:assert (x['label'],x['numberOfBytes'])==(y['label'],y['numberOfBytes']),path
for file,names in a.items():
 if file!='LayoutHarness.sol' and file!='src/events/EventMarket.sol':continue
 for name,artifact in names.items():
  old=artifact['storageLayout'];new=b[file][name]['storageLayout']
  assert len(new['storage'])>=len(old['storage'])
  for m,n in zip(old['storage'],new['storage']):
   assert (m['label'],m['slot'],m['offset'])==(n['label'],n['slot'],n['offset'])
   compare_types(old['types'],new['types'],m['type'],n['type'],name+'.'+m['label'])
print(json.dumps({'base':subprocess.check_output(['git','rev-parse','origin/main'],text=True).strip(),'compiler':'0.8.24','memberChecks':checks,'allowedTrailingArrayExpansions':expansions,'status':'PASS'},indent=2))
