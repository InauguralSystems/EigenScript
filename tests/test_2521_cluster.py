#!/usr/bin/env python3
import os, struct, subprocess, tempfile, sys
E=sys.argv[1] if len(sys.argv)>1 else os.environ.get('EIGS','src/eigenscript')
with tempfile.TemporaryDirectory() as d:
 def run(name, source, want):
  p=os.path.join(d,name+'.eigs'); open(p,'w').write(source)
  for strict in (None,'0','1'):
   env=os.environ.copy()
   if strict is None: env.pop('EIGS_STRICT',None)
   else: env['EIGS_STRICT']=strict
   q=subprocess.run([E,p],text=True,capture_output=True,env=env)
   if q.returncode or want not in q.stdout:
    print('FAIL:',name,strict,q.stdout,q.stderr); return False
  print('PASS:',name); return True
 def caught(expr): return 'try:\n    '+expr+'\ncatch e:\n    print of [e.kind, e.message]\n'
 fixtures={
  'short_header':b'x', 'bad_ndim':struct.pack('IIII',3,1,1,0),
  'zero_rows':struct.pack('IIII',2,0,1,0), 'zero_cols':struct.pack('IIII',2,1,0,0),
  'short_payload':struct.pack('IIII',2,1,2,0)+struct.pack('d',1.0)}
 ok=True
 for n,b in fixtures.items():
  path=os.path.join(d,n); open(path,'wb').write(b)
  kind='io' if n in ('short_header','short_payload') else 'value'
  ok &= run(n,caught('tensor_load of '+repr(path).replace("'",'"')), '["'+kind+'"')
 ok &= run('directory',caught('tensor_load of '+repr(d).replace("'",'"')), '["io"')
 shapes=[('nested_flat','[[1.0,2.0]]','[1.0,2.0]','type_mismatch'),
         ('flat_nested','[1.0,2.0]','[[1.0,2.0]]','type_mismatch'),
         ('flat_lengths','[1.0,2.0]','[1.0]','value'),
         ('row_counts','[[1.0],[2.0]]','[[1.0]]','value'),
         ('row_lengths','[[1.0,2.0]]','[[1.0]]','value')]
 for n,p,g,k in shapes:
  src='p is '+p+'\n'+caught('sgd_update of [p, '+g+', 0.5]')+'print of p\n'
  ok &= run(n,src,'["'+k+'"')
 ok &= run('sandbox_value','r is sandbox_run of [1, "code", []]\nprint of r.error.kind\n','value')
 ok &= run('music_missing',caught('audio_music_play of ["'+os.path.join(d,'missing')+'", 0]'),'["io"')
 sys.exit(0 if ok else 1)
