#!/usr/bin/env python3
"""One-time #2502 fault plants; build one mutated unit in its own directory.

All other objects come from the candidate release build; the candidate source
and binary stay byte-identical. The Makefile supplies compile and link flags.
"""
import hashlib,re,shlex,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def run(args,**kw):
    return subprocess.run(args,cwd=ROOT,text=True,capture_output=True,timeout=600,**kw)

def main():
    build=run(['make','--no-print-directory','-n','-B','build/release/eigenscript'])
    if build.returncode: print(build.stdout,build.stderr);return 1
    commands=[shlex.split(s) for s in build.stdout.splitlines() if s.strip()]
    compiles={next(x for x in a if x.endswith('.c')):a for a in commands if '-c' in a}
    links=[a for a in commands if '-o' in a and 'build/release/eigenscript' in a and '-c' not in a]
    assert len(links)==1
    host=(ROOT/'src/builtins_host.c').read_text()
    common=(ROOT/'src/eigenscript.c').read_text()
    # Reintroduce precisely the former implementation for the depth plant.
    old=run(['git','show','cc3aa279:src/eigenscript.c'])
    assert old.returncode==0
    a=old.stdout.index('int eigs_arg_has_bool('); b=old.stdout.index('\n/* ---- NaN-boxing',a)
    old_bool=old.stdout[a:b]
    a=common.index('int eigs_arg_has_bool('); b=common.index('\n/* Structural equality',a)
    depth=common[:a]+old_bool+'\n'+common[b:]
    anchor='''        } else {
            eigs_module_ns_sync(v);
            DICT_FOR_EACH(v, i) {'''
    assert common.count(anchor)==1
    no_dict=common.replace(anchor,anchor.replace('} else {','} else if (0) {'))
    anchor='''    ARG_GUARD(!path_val || path_val->type != VAL_STR ||
              !text_val || text_val->type != VAL_STR,'''
    assert host.count(anchor)==1
    quiet=host.replace(anchor,'''    if (getenv("EIGS_STRICT") && !strcmp(getenv("EIGS_STRICT"), "0") &&
        (!text_val || text_val->type != VAL_STR)) return make_bool(0);
'''+anchor)
    early=host.replace(anchor,'''    if (path_val && path_val->type == VAL_STR) {
        FILE *plant = xfopen_write(path_val->data.str, "w");
        if (plant) { fputs("PLANTED", plant); fclose(plant); }
    }
'''+anchor)
    plants=[('depth-2','src/eigenscript.c',depth,'depth'),
            ('skip-dicts','src/eigenscript.c',no_dict,'depth'),
            ('quiet-0','src/builtins_host.c',quiet,'write_text'),
            ('write-before-guard','src/builtins_host.c',early,'write_text')]
    assert len(plants) == 4 > 0
    passed=0
    original_hash=hashlib.sha256((ROOT/'build/release/eigenscript').read_bytes()).hexdigest()
    for name,source,mutant,test in plants:
        with tempfile.TemporaryDirectory(prefix='eigs2502-plant-') as td:
            work=Path(td);c=work/Path(source).name;o=work/'mutant.o'
            (work/'src').mkdir()
            (work/'lib').symlink_to(ROOT/'lib', target_is_directory=True)
            binary=work/'src/eigenscript'
            c.write_text(mutant)
            argv=compiles[source][:]
            argv[argv.index(source)]=str(c)
            argv[argv.index('-o')+1]=str(o)
            argv+=['-I'+str(ROOT/'src')]
            built=run(argv)
            if built.returncode: print('FAIL: plant build',name,built.stderr);return 1
            argv=links[0][:];argv[argv.index('-o')+1]=str(binary)
            old_obj='build/release/'+Path(source).stem+'.o'
            assert argv.count(old_obj)==1
            argv[argv.index(old_obj)]=str(o)
            linked=run(argv)
            if linked.returncode:print('FAIL: plant link',name,linked.stderr);return 1
            if test=='depth':
                result=run([str(binary),str(ROOT/'tests/type_errors_2502_depth.eigs')])
                caught=result.returncode==1 and 'FAIL:' in result.stdout and 'DEPTH2502: complete' in result.stdout
                if name == 'depth-2':
                    caught = caught and 'FAIL: 10000-deep list reaches its bool without C recursion' in result.stdout
                else:
                    caught = caught and 'FAIL: direct dictionary value' in result.stdout and 'FAIL: dictionary inside a list' in result.stdout
            else:
                result=run(['python3',str(ROOT/'tests/type_errors_2502.py'),'--binary',str(binary),'--writer',test])
                caught=result.returncode==1 and re.search(r'failed=[1-9][0-9]*$', result.stdout.rstrip()) is not None
                if name == 'write-before-guard':
                    caught = caught and '\tyes\tno\tno record' in result.stdout
            if caught:passed+=1;print('PASS: plant',name,'RED in',test,flush=True)
            else: print('FAIL: plant',name,'rc',result.returncode,result.stdout,result.stderr,flush=True)
    assert hashlib.sha256((ROOT/'build/release/eigenscript').read_bytes()).hexdigest()==original_hash
    print(f'PLANTS2502: examined={len(plants)} red={passed}')
    return int(passed!=len(plants))

if __name__=='__main__':raise SystemExit(main())
