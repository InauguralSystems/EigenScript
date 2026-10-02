import contextlib
import copy
import io
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile

candidate = Path(sys.argv[1]).resolve()
mode = sys.argv[2] if len(sys.argv) > 2 else 'stderr'
fixture = {'config': {'vocab_size': 8, 'd_model': 4, 'n_layers': 2,
                      'd_ff': 8, 'max_seq_len': 32},
           'format_version': 2, 'weight_format': 'fp32_dense',
           'token_embeddings': [[.125]*4 for _ in range(8)],
           'output_proj': [[.125]*8 for _ in range(4)], 'layers': []}
for unused in range(2):
    layer = {k:[[.125]*c for _ in range(r)] for k,r,c in
             [('w_q',4,4),('w_k',4,4),('w_v',4,4),('w_o',4,4),
              ('w_ff1',4,8),('w_ff2',8,4)]}
    layer.update({k:[.125]*4 for k in
                  ['ln1_gamma','ln1_beta','ln2_gamma','ln2_beta']})
    fixture['layers'].append(layer)

def leaves(obj):
    if isinstance(obj,list):
        return sum(leaves(v) for v in obj)
    if isinstance(obj,dict):
        return sum(leaves(v) for v in obj.values())
    return obj

def update(obj, scale):
    if isinstance(obj,list):
        return [update(v,scale) for v in obj]
    if isinstance(obj,dict):
        return {k:update(v,scale) for k,v in obj.items()}
    return obj-scale

calls = 0
def fake_run(argv, **kwargs):
    global calls
    calls += 1
    source = Path(argv[1]).read_text()
    model_path = re.search(r'eigen_model_load of "([^"]+)"',source).group(1)
    model = json.loads(Path(model_path).read_text())
    stderr = ''
    training = 'native_train_step_builtin' in source
    if mode == 'stderr' or (mode == 'eval_stderr' and not training):
        stderr = 'model_infer.c:123:4: runtime error: signed integer overflow\n'
    if mode == 'asan' and not training:
        stderr = '==17==ERROR: AddressSanitizer: heap-buffer-overflow\n'
    if mode == 'fatal' and not training:
        stderr = 'FATAL: ThreadSanitizer: unexpected memory mapping\n'
    if mode == 'leak':
        stderr = '==17==ERROR: LeakSanitizer: detected memory leaks\nSUMMARY: AddressSanitizer: 16 byte(s) leaked in 1 allocation(s).\n'
    if 'native_train_step_builtin' in source:
        trained = copy.deepcopy(model)
        trained['token_embeddings'] = update(model['token_embeddings'],1.)
        trained['output_proj'] = update(model['output_proj'],1.)
        trained['layers'] = update(model['layers'],.1)
        saved = re.search(r'model_save_weights of "([^"]+)"',source).group(1)
        Path(saved).write_text(json.dumps(trained))
        out = 'ok\n'
    else:
        loss = sum(leaves(model[k]) for k in ['token_embeddings','output_proj','layers'])
        # Native eigen_eval_loss returns -1 when no model is loaded; the script
        # sums 31 such sentinels. Sample 08 belongs to layer0.w_v (nonduplicate).
        if mode == 'invalid_loss' and Path(argv[1]).name[:3] in ('f08','c08'):
            loss = -31
        items = [loss / 31] * 31
        if mode == 'fine_overflow' and Path(argv[1]).name[:3] in ('f08','c08'):
            loss = 1e308 if Path(argv[1]).name.startswith('f08p') else 0.
            items = [loss / 31] * 31
        if mode in ('invalid_item', 'nan_item', 'inf_item') and Path(argv[1]).name[:3] in ('f08','c08'):
            items[5] = {'invalid_item': -1., 'nan_item': float('nan'), 'inf_item': float('inf')}[mode]
        if mode == 'nan_total' and Path(argv[1]).name[:3] in ('f08','c08'):
            loss = float('nan')
        out = ''.join('LOSS_ITEM '+repr(item)+'\n' for item in items) + 'LOSS '+repr(loss)+'\n'
    return subprocess.CompletedProcess(argv,0,out,stderr)

with tempfile.TemporaryDirectory(prefix='1537-critic-') as work:
    base = Path(work)/'base.json'
    base.write_text(json.dumps(fixture))
    sys.argv = [str(candidate),'MOCK_NATIVE',str(base),work]
    saved_run = subprocess.run
    subprocess.run = fake_run
    capture = io.StringIO()
    try:
        with contextlib.redirect_stdout(capture):
            try:
                ns = runpy.run_path(str(candidate),run_name='__main__')
                status = 0
            except SystemExit as result:
                status = result.code
    finally:
        subprocess.run = saved_run
    print('mode=%s native_mock_calls=%d rc=%s'%(mode,calls,status))
    if status == 0:
        def count_scalars(x):
            return sum(count_scalars(y) for y in x) if isinstance(x,list) else 1
        print('inventory groups=%d scalars=%d nominal=%d unique=%d'%(
            len(ns['groups']),sum(count_scalars(ns['get_at'](fixture,path)) for _,path in ns['groups']),
            len(ns['samples']),len(set(tuple(path) for _,path in ns['samples']))))
    print(capture.getvalue(),end='')
