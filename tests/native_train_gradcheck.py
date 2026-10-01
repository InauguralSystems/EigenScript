#!/usr/bin/env python3
"""Finite-difference oracle for every native-training parameter group."""

import copy
import json
import math
import os
import subprocess
import sys


EIGS, BASE_PATH, WORK = sys.argv[1:]
H = 1.0e-2
REL_TOL = 1.0e-2
MIN_GRAD = 1.0e-4
# A 32-token window gives the 31 prefix/next-token losses accumulated by the
# backward pass.  Repeated, asymmetric IDs keep the tiny model deterministic.
TOKENS = [1, 4, 2, 7, 3, 6, 5, 2, 1, 7, 4, 6, 3, 5, 1, 2,
          6, 4, 7, 3, 2, 5, 6, 1, 4, 3, 7, 5, 2, 6, 4, 1]


def eigs_string(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def run_script(source, name):
    path = os.path.join(WORK, name + ".eigs")
    with open(path, "w", encoding="utf-8") as out:
        out.write(source)
    result = subprocess.run(
        [EIGS, path], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            "%s exited %d: %s" % (name, result.returncode, result.stderr[-500:]))
    return result.stdout


def write_model(model, name):
    path = os.path.join(WORK, name + ".json")
    with open(path, "w", encoding="utf-8") as out:
        json.dump(model, out, separators=(",", ":"))
    return path


def objective(model, name):
    path = write_model(model, name)
    lines = ['r is eigen_model_load of "%s"' % eigs_string(path), "loss is 0"]
    for pos in range(len(TOKENS) - 1):
        prompt = json.dumps(TOKENS[:pos + 1], separators=(",", ":"))
        lines.append("loss is loss + (eigen_eval_loss of [%s, %d])" %
                     (prompt, TOKENS[pos + 1]))
    lines.append('print of ("LOSS " + (json_encode of loss))')
    stdout = run_script("\n".join(lines) + "\n", name + "_eval")
    values = [line[5:] for line in stdout.splitlines() if line.startswith("LOSS ")]
    if len(values) != 1:
        raise RuntimeError("%s produced no unique LOSS line: %r" % (name, stdout))
    return float(values[0])


def get_at(model, path):
    value = model
    for key in path:
        value = value[key]
    return value


def set_at(model, path, value):
    target = model
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value


with open(BASE_PATH, encoding="utf-8") as source:
    base = json.load(source)

# Two deterministic samples per group make an accidental near-zero derivative
# unlikely while retaining the issue recipe's short runtime.
groups = [("token_embeddings", ["token_embeddings"]),
          ("output_proj", ["output_proj"])]
for layer in range(2):
    for key in ("w_q", "w_k", "w_v", "w_o", "w_ff1", "w_ff2",
                "ln1_gamma", "ln1_beta", "ln2_gamma", "ln2_beta"):
        groups.append(("layer%d.%s" % (layer, key), ["layers", layer, key]))

samples = []
for group_index, (name, root) in enumerate(groups):
    values = get_at(base, root)
    if isinstance(values[0], list):
        rows, cols = len(values), len(values[0])
        flat_indices = [(group_index * 7 + 1) % (rows * cols),
                        (group_index * 13 + 5) % (rows * cols)]
        if name == "layer1.w_k":
            flat_indices = [0, 5]
        paths = [root + [index // cols, index % cols] for index in flat_indices]
    else:
        paths = [root + [(group_index + 1) % len(values)],
                 root + [(group_index + 3) % len(values)]]
    samples.extend((name, path) for path in paths)

# At age zero effective_lr = 1.  Observer scaling is disabled by the caller;
# head delta is the gradient and body delta is 0.1 times the gradient.
trained_path = os.path.join(WORK, "trained.json")
train_source = """r is eigen_model_load of \"%s\"
res is native_train_step_builtin of [%s, [%d], 1]
s is model_save_weights of \"%s\"
print of res
""" % (eigs_string(BASE_PATH),
       json.dumps(TOKENS[:-1], separators=(",", ":")), TOKENS[-1],
       eigs_string(trained_path))

try:
    env = os.environ.copy()
    env["EIGS_OBS_SCALE_OFF"] = "1"
    script_path = os.path.join(WORK, "train.eigs")
    with open(script_path, "w", encoding="utf-8") as out:
        out.write(train_source)
    result = subprocess.run([EIGS, script_path], text=True, capture_output=True,
                            check=False, env=env)
    if result.returncode != 0 or not os.path.exists(trained_path):
        raise RuntimeError("training failed rc=%d: %s" %
                           (result.returncode, result.stderr[-500:]))
    with open(trained_path, encoding="utf-8") as source:
        trained = json.load(source)

    checked = 0
    skipped = 0
    failures = []
    checked_groups = set()
    for sample_index, (group, path) in enumerate(samples):
        scale = 1.0 if len(path) == 3 and path[0] != "layers" else 0.1
        analytic = (get_at(base, path) - get_at(trained, path)) / scale
        plus = copy.deepcopy(base)
        minus = copy.deepcopy(base)
        set_at(plus, path, get_at(base, path) + H)
        set_at(minus, path, get_at(base, path) - H)
        numeric = (objective(plus, "p%02d" % sample_index) -
                   objective(minus, "m%02d" % sample_index)) / (2.0 * H)
        if abs(numeric) < MIN_GRAD:
            skipped += 1
            continue
        rel = abs(analytic - numeric) / max(abs(analytic), abs(numeric))
        checked += 1
        if not math.isfinite(rel) or rel > REL_TOL:
            failures.append("%s path=%s analytic=%.8g numeric=%.8g rel=%.3g" %
                            (group, path, analytic, numeric, rel))
        else:
            checked_groups.add(group)

    missing = sorted(set(name for name, unused in groups) - checked_groups)
    if failures or missing:
        for detail in failures:
            print("  FAIL: NG01 " + detail)
        if missing:
            print("  FAIL: NG02 no nontrivial sampled gradient for groups: " +
                  ", ".join(missing))
        count = len(failures) + (1 if missing else 0)
        print("NATIVE_GRADCHECK: 0 passed, %d failed" % count)
        sys.exit(1)
    print("  PASS: NG01 %d finite-difference gradients across all 22 groups "
          "agree within 1%% (%d near-zero samples skipped)" % (checked, skipped))
    print("NATIVE_GRADCHECK: 1 passed, 0 failed")
except Exception as error:  # A child/tool failure is always a visible red.
    print("  FAIL: NG00 finite-difference harness (%s)" % error)
    print("NATIVE_GRADCHECK: 0 passed, 1 failed")
    sys.exit(1)
