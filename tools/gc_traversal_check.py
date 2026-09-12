#!/usr/bin/env python3
"""Exercise the actual collector with temporary, test-only reach hooks.
Requires an already built, fresh Makefile object variant. Never rebuilds the CLI.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import tempfile
from bounded_process import run_owned

ROOT=Path(__file__).resolve().parent.parent
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def verify_inputs(frozen):
    for name,digest in frozen.items():
        assert sha(Path(name))==digest,f"input changed during collector test: {name}"

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--variant',choices=['release','asan'],required=True)
    ap.add_argument('--out',type=Path)
    ap.add_argument('--faults',action='store_true',help='also require two deliberate runtime faults to fail')
    a=ap.parse_args()
    out=a.out or Path(tempfile.mkdtemp(prefix='gc-traversal-'))
    if a.out: out.mkdir(parents=True,exist_ok=False)
    env=dict(os.environ)
    for k in ['EIGS_GC_DEBUG','EIGS_TRACE','EIGS_REPLAY']: env.pop(k,None)
    env['ASAN_OPTIONS']='detect_leaks=1:halt_on_error=1'
    env['UBSAN_OPTIONS']='halt_on_error=1'
    records=[]; manifest={'variant':a.variant,'processes':records,'outputs':{}}
    def save(): (out/'result.json').write_text(json.dumps(manifest,indent=2)+'\n')
    def run(label,cmd,seconds=30,expected=0):
        directory=out/label
        try:
            record=run_owned(cmd,directory,seconds,env,ROOT)
        finally:
            if (directory/'process.json').exists():
                records.append(json.loads((directory/'process.json').read_text())); save()
        if record['returncode']!=expected:
            raise AssertionError(f"{label}: expected rc {expected}, got {record['returncode']}; {directory}")
        return directory
    def variable(name):
        d=run('make-'+name,['make','--no-print-directory','-s','print-'+name])
        return shlex.split((d/'stdout').read_text())
    configuration={str(ROOT/n):sha(ROOT/n) for n in ['Makefile','VERSION']}
    cc=variable('CC'); flags=variable('FLAGS_'+a.variant); libs=variable('LIBS_'+a.variant)
    all_objects=variable('OBJ_'+a.variant)
    sources=variable('SRC_V_'+a.variant)
    verify_inputs(configuration)
    assert all_objects==[str(Path('build')/a.variant/(Path(s).stem+'.o')) for s in sources]
    objects=[ROOT/p for p in all_objects if Path(p).name not in ['main.o','eigenscript.o']]
    assert objects and all(p.is_file() for p in objects),'build selected runtime variant first'
    flags=[f for f in flags if not f.startswith('-DEIGENSCRIPT_VERSION=')]
    flags+=['-DEIGENSCRIPT_VERSION="'+(ROOT/'VERSION').read_text().strip()+'"','-I'+str(ROOT/'src')]
    inputs=[ROOT/'src/eigenscript.c',ROOT/'tests/test_gc_traversal.c',ROOT/'tests/lsan_classify.sh',Path(__file__),ROOT/'Makefile',ROOT/'VERSION',ROOT/'tools/bounded_process.py',*[ROOT/p for p in sources],*objects,*sorted((ROOT/'src').rglob('*.h'))]
    frozen={str(p):sha(p) for p in inputs}
    manifest['inputs']=frozen
    def verify():
        verify_inputs(frozen)
    verify_inputs(configuration)
    verify()
    run('object-freshness',['make','--no-print-directory','-q',*[str(p.relative_to(ROOT)) for p in objects]])
    verify()
    source=(ROOT/'src/eigenscript.c').read_text()
    def once(s,old,new):
        assert s.count(old)==1,f'expected one hook/fault site: {old}'
        return s.replace(old,new,1)
    # Mutations affect only temporary copies. Positive/negative builds use the
    # same runtime edge table, test harness, compiler flags and other objects.
    variants=['positive']+(['duplicate-count','skip-disabled'] if a.faults else [])
    for label in variants:
        verify(); directory=out/('source-'+label); directory.mkdir()
        generated=source
        if label=='duplicate-count':
            generated=once(generated,'            u.internal[ci]++;','            if (u.internal[ci] == 0) u.internal[ci]++;')
        skip='        if (!u.has_node_children[n]) continue;'
        guard='0 && !u.has_node_children[n]' if label=='skip-disabled' else '!u.has_node_children[n]'
        generated=once(generated,skip,'        if ('+guard+') { traversal_skips++; continue; }')
        generated=once(generated,'    /* 3. Roots: refcount > internal + collector pins.',
                       '    traversal_discovered(&u);\n    /* 3. Roots: refcount > internal + collector pins.')
        marker='    if (eigs_env_flag("EIGS_GC_DEBUG"))\n        fprintf(stderr, "[gc] universe'
        generated=once(generated,marker,'    traversal_collected(u.count, garbage);\n'+marker)
        (directory/'gc_traversal_runtime.c').write_text(generated)
        harness=directory/'test_gc_traversal.c'
        harness.write_bytes((ROOT/'tests/test_gc_traversal.c').read_bytes())
        binary=directory/'test'
        local_inputs={str(harness.resolve()):sha(harness),
                      str((directory/'gc_traversal_runtime.c').resolve()):sha(directory/'gc_traversal_runtime.c')}
        dependencies=directory/'dependencies.d'
        run('build-'+label,cc+flags+['-MMD','-MF',dependencies,harness,*objects,*libs,'-o',binary],240)
        binary_digest=sha(binary)
        manifest['outputs'][label]={'binary':str(binary),'binary_sha256':binary_digest,'status':'built'}
        save()
        verify()
        # Compiler-enumerated local dependencies must all belong to the frozen
        # inventory; recursive src/*.h collection includes nested headers.
        dep_text=dependencies.read_text().replace('\\\n',' ')
        dep_paths=shlex.split(dep_text.split(':',1)[1])
        dependency_hashes={}
        for name in dep_paths:
            path=Path(name)
            if not path.is_absolute(): path=ROOT/path
            path=path.resolve()
            expected_hash=local_inputs.get(str(path),frozen.get(str(path)))
            assert expected_hash is not None,f'unfrozen compiler dependency: {path}'
            assert sha(path)==expected_hash,f'compiler dependency changed: {path}'
            dependency_hashes[str(path)]=expected_hash
        assert sha(binary)==binary_digest,'test executable changed before execution'
        d=run('run-'+label,[binary],60,0 if label=='positive' else 1)
        assert sha(binary)==binary_digest,'test executable changed during execution'
        verify()
        assert all(sha(Path(p))==h for p,h in dependency_hashes.items()),'compiled dependency changed during run'
        stdout=(d/'stdout').read_text(); stderr=(d/'stderr').read_text()
        combined=d/'combined'; combined.write_text(stdout+stderr)
        # Use the suite's classifier even at rc=0. Only the deliberate
        # undercount fault may tolerate LEAK; HARD is never an expected red.
        classify='source "$1"; c=0; lsan_classify "$(cat "$2")" || c=$?; '
        classify+='case "$c" in 0|2) exit 0;; *) exit 1;; esac' if label=='duplicate-count' else 'test "$c" -eq 2'
        run('sanitizer-'+label,['bash','-c',classify,'gc-traversal',ROOT/'tests/lsan_classify.sh',combined])
        rows=re.findall(r'^gc-traversal: cases=3 checks=(\d+) failures=(\d+)$',stdout,re.M)
        assert len(rows)==1 and int(rows[0][0])==2455,'changed total check population'
        case_rows=re.findall(r'^gc-case: name=(\w+) checks=(\d+) collections=(\d+) skips=(\d+) failures=(\d+)$',stdout,re.M)
        expected_failures={'positive':[0,0,0],'duplicate-count':[2,0,3],'skip-disabled':[1,0,0]}[label]
        # Undercounting makes the module cycle look externally owned after
        # cache removal, so its leaf nested chunk is marked/skipped a second
        # time. That extra visit is part of this fault's retention witness.
        expected_skips={'positive':[1,0,1],'duplicate-count':[1,0,2],'skip-disabled':[0,0,0]}[label]
        expected_cases=[(name,str(checks),str(collections),str(skips),str(failures))
                        for name,checks,collections,skips,failures in zip(
                            ['duplicates','growth','namespace'],[13,2418,20],[1,2,2],expected_skips,expected_failures)]
        assert case_rows==expected_cases,f'changed per-case population: {case_rows} != {expected_cases}'
        assert int(rows[0][1])==sum(expected_failures),'changed failure population'
        if label=='positive':
            assert int(rows[0][1])==0 and not stderr,'unexpected positive stderr or failure'
        else:
            witness='duplicate edges counted separately' if label=='duplicate-count' else 'numeric-leaf mark traversal skipped'
            assert 'gc-traversal: FAIL '+witness in stderr,'wrong fault rejection'
            # A leak-only diagnostic in the deliberate ownership fault is
            # expected; an unrelated crash cannot satisfy its textual witness.
        assert sha(binary)==binary_digest,'test executable changed during validation'
        manifest['outputs'][label]={'binary':str(binary),'binary_sha256':binary_digest,'status':'checked','generated_sha256':sha(directory/'gc_traversal_runtime.c'),'checks':int(rows[0][0]),'failures':int(rows[0][1]),'cases':case_rows,'compiler_dependencies':dependency_hashes}
    verify()
    assert all(sha(Path(record['binary']))==record['binary_sha256'] for record in manifest['outputs'].values()),'test executable changed before finalization'
    manifest['verdict']='complete'; save()
    print(f'gc-traversal: {len(variants)} variants checked; evidence {out}')

if __name__=='__main__': main()
