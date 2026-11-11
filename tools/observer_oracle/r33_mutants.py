#!/usr/bin/env python3
"""Single-fault F0 port plants and an auditable AST census (R33-1 addendum2).

No experimental policy or subject binary is run by this module. Comparisons
use saved, manifest-committed F0 binary readings. Surviving plants remain
UNRESOLVED until a witness or a stated equivalence/unreachability proof exists.
"""
import ast
import copy
import hashlib
import json
import math
from pathlib import Path
import sys
import types
from functools import lru_cache

HERE = Path(__file__).resolve().parent
SOURCE = HERE / 'r33_port.py'
CRITIC = [('converged_le_to_lt', 'return hi - lo <= self.zero * self.policy.magnitude(float(self.values[-1])', 'return hi - lo < self.zero * self.policy.magnitude(float(self.values[-1])'), ('converged_threshold_x1.01', 'return hi - lo <= self.zero * self.policy', 'return hi - lo <= 1.01 * self.zero * self.policy'), ('converged_threshold_x0.99', 'return hi - lo <= self.zero * self.policy', 'return hi - lo <= 0.99 * self.zero * self.policy'), ('window_len_11', 'def __init__(self, policy="F0", window=10,', 'def __init__(self, policy="F0", window=11,'), ('values_ring_W_not_W+1', 'self.values = self.values[-(self.window + 1):]', 'self.values = self.values[-(self.window + 2):]'), ('stable_le_to_lt', 'return half_diameter <= self.small', 'return half_diameter < self.small'), ('stable_midrange_to_mean', 'midrange = hi / 2.0 + lo / 2.0', 'midrange = sum(map(float, self.values)) / len(self.values)'), ('exact_conv_le_to_lt', 'return self.exact_diameter() <= self.zero * self.scale', 'return self.exact_diameter() < self.zero * self.scale'), ('exact_stable_le_to_lt', 'return self.exact_diameter() <= 2.0 * self.small * self.scale', 'return self.exact_diameter() < 2.0 * self.small * self.scale'), ('exact_diameter_via_float', 'return float(max(self.values) - min(self.values))', 'return max(map(float, self.values)) - min(map(float, self.values))'), ('exact_path_disabled', 'if self.all_exact():\n            return self.exact_diameter() <= self.zero * self.scale', 'if False:\n            return self.exact_diameter() <= self.zero * self.scale'), ('noise_floor_8eps', 'return 4.0 * sys.float_info.epsilon * magnitude', 'return 8.0 * sys.float_info.epsilon * magnitude'), ('noise_floor_no_exact_zero', 'if self.all_exact():\n            return 0.0', 'if False:\n            return 0.0'), ('nonvanishing_no_slack', 'return recent >= older * (1.0 - 1e-9)', 'return recent >= older'), ('nonvanishing_min4_to_5', 'if count < 4:', 'if count < 5:'), ('nonvanishing_le_to_lt', 'if older <= floor or recent <= floor:', 'if older < floor or recent < floor:'), ('refdiv_ge_to_gt', 'float(len(w) - 2))) >= 1.0 - 1e-9', 'float(len(w) - 2))) > 1.0 - 1e-9'), ('refdiv_no_slack', 'float(len(w) - 2))) >= 1.0 - 1e-9', 'float(len(w) - 2))) >= 1.0'), ('refdiv_tau_strict', 'if not d > tau:', 'if not d >= tau:'), ('D2_lt_to_le', 'elif self.best_used and math.isfinite(shadow) and value < threshold:', 'elif self.best_used and math.isfinite(shadow) and value <= threshold:'), ('D2_int_compare_via_float', 'elif self.best_used and math.isfinite(shadow) and value < threshold:', 'elif self.best_used and math.isfinite(shadow) and shadow < threshold:'), ('D2_no_saturation_wrap', 'elif self.since < 255:\n            self.since += 1', 'else:\n            self.since = (self.since + 1) % 256'), ('improving_since_ge_to_gt', 'or self.since >= self.window or', 'or self.since > self.window or'), ('rel_osc_min3_to_4', 'if len(self.raw) < 3:', 'if len(self.raw) < 4:'), ('flips_threshold_+1', 'return flips >= (self.window + 2) // 3\n\n    def bounded', 'return flips >= (self.window + 2) // 3 + 1\n\n    def bounded'), ('bounded_osc_0.3_to_0.35', 'abs(net) <= 0.3 * path', 'abs(net) <= 0.35 * path'), ('bounded_osc_rev2_to_3', 'return reversals >= 2 and abs(net)', 'return reversals >= 3 and abs(net)'), ('equilibrium_var_lt_to_le', 'return variance < self.zero * self.zero', 'return variance <= self.zero * self.zero'), ('equilibrium_mean_ge_to_gt', 'if abs(mean) >= self.zero:', 'if abs(mean) > self.zero:'), ('one_direction_2_to_3', 'return nonzero >= 2', 'return nonzero >= 3'), ('one_direction_signbit_to_lt0', 'sign = math.copysign(1.0, d) < 0.0', 'sign = d < 0.0'), ('flags_ge_to_gt', 'if magnitude >= self.zero:', 'if magnitude > self.zero:'), ('flags_small_ge_to_gt', 'if magnitude >= self.small:', 'if magnitude > self.small:'), ('quiet_lt_to_le', 'quiet = abs(relative) < self.zero', 'quiet = abs(relative) <= self.zero'), ('fmax_nan_order', 'if math.isnan(a):\n        return b\n    if math.isnan(b):\n        return a', 'if math.isnan(a) or math.isnan(b):\n        return math.nan'), ('fmax_signed_zero', 'return a if a > b else b', 'return a if a >= b else b'), ('S1_ref_current_only', 'reference = fmax(abs(current), abs(previous))', 'reference = abs(current)'), ('scale_1e-3_to_1.1e-3', 'scale=0.001, dh_zero', 'scale=0.0011, dh_zero'), ('subtraction_overflow_ignored', 'exact = is_int(value) and is_int(previous) and INT_MIN <= delta <= INT_MAX', 'exact = is_int(value) and is_int(previous)'), ('opposite_inf_any_to_last_only', 'for v in self.values[::-1])', 'for v in self.values[-2:])'), ('finite_window_last_only', 'return bool(self.values) and all(math.isfinite(float(v)) for v in self.values)', 'return bool(self.values) and math.isfinite(float(self.values[-1]))'), ('report_order_conv_equil_swap', 'for name in ("converged", "equilibrium", "stable"):', 'for name in ("equilibrium", "converged", "stable"):'), ('how_inf_raw_to_nan', '0.0 if math.isinf(self.raw[-1]) else', 'math.nan if math.isinf(self.raw[-1]) else'), ('refexp_newer_gt_to_ge', 'return crossings >= 2 and newer > older', 'return crossings >= 2 and newer >= older'), ('equilibrium_partial_ok', 'or len(self.raw) < self.window:\n            return False\n        if self.raw_one', 'or len(self.raw) < 1:\n            return False\n        if self.raw_one'), ('partial_raw_requires_full', 'if count < 4:', 'if count < self.window:'), ('quiet_always_true', 'quiet = abs(relative) < self.zero', 'quiet = True'), ('partial_report_always_moving', 'return "stable" if self.flags()[1] else "moving"', 'return "moving"'), ('refdiv_disabled', 'if len(self.values) < self.window + 1:\n            return False\n        w = [float(v) for v in self.values]\n        tau', 'if True:\n            return False\n        w = [float(v) for v in self.values]\n        tau'), ('refexp_disabled', 'return crossings >= 2 and newer > older', 'return False'), ('refdiv_slack_1e-6', 'float(len(w) - 2))) >= 1.0 - 1e-9', 'float(len(w) - 2))) >= 1.0 - 1e-6'), ('D2_threshold_zero_x2', 'threshold = self.best - self.zero * self.policy', 'threshold = self.best - 2 * self.zero * self.policy'), ('D2_threshold_floor_scale_x10', 'threshold = self.best - self.zero * self.policy.magnitude(self.best, peak, self.scale)', 'threshold = self.best - self.zero * self.policy.magnitude(self.best, peak, 10 * self.scale)'), ('S4_tau_floor_x10', 'tau = self.zero * self.policy.magnitude(w[-1], self.peak(), self.scale)', 'tau = self.zero * self.policy.magnitude(w[-1], self.peak(), 10 * self.scale)'), ('S4_tau_floor_0', 'tau = self.zero * self.policy.magnitude(w[-1], self.peak(), self.scale)', 'tau = self.zero * abs(w[-1])'), ('S6_floor_0', 'return hi - lo <= self.zero * self.policy.magnitude(float(self.values[-1]), self.peak(), self.scale)', 'return hi - lo <= self.zero * abs(float(self.values[-1]))'), ('S8_floor_0', 'return half_diameter <= self.small * self.policy.magnitude(midrange, self.peak(), self.scale)', 'return half_diameter <= self.small * abs(midrange)'), ('S2S3_floor_0', 'threshold = self.best - self.zero * self.policy.magnitude(self.best, peak, self.scale)', 'threshold = self.best - self.zero * abs(self.best)'), ('S1_floor_0', 'denominator = self.magnitude(reference, peak, scale)', "denominator = abs(reference) if self.name == 'F0' else self.magnitude(reference, peak, scale)"), ('N1_additive_dropped', 'magnitude = (1.0 + abs(last) if', 'magnitude = (abs(last) if'), ('N1_last_to_prev', 'last = float(self.values[-1]) if self.values else 0.0', 'last = float(self.values[-2]) if len(self.values) > 1 else 0.0'), ('equilibrium_uses_raw_not_rel', 'newest = self.steps()[::-1]\n        total = 0.0', 'newest = self.raw[::-1]\n        total = 0.0'), ('since_cap_10', 'elif self.since < 255:', 'elif self.since < 10:'), ('S4_ref_first_value', 'tau = self.zero * self.policy.magnitude(w[-1], self.peak(), self.scale)', 'tau = self.zero * self.policy.magnitude(w[0], self.peak(), self.scale)'), ('S4_tau_zero', 'tau = self.zero * self.policy.magnitude(w[-1], self.peak(), self.scale)', 'tau = 0.0'), ('S4_tau_x10', 'tau = self.zero * self.policy.magnitude(w[-1], self.peak(), self.scale)', 'tau = 10 * self.zero * self.policy.magnitude(w[-1], self.peak(), self.scale)'), ('from_traj_since_plus1', 'obj.since = 255 if age is None else int(age)', 'obj.since = 255 if age is None else min(255, int(age) + 1)'), ('from_traj_best_ignored', 'obj.best, obj.best_used = float(best), True', 'pass'), ('from_traj_best_store_scale', 'obj.best, obj.best_used = float(best), True', 'obj.scale, obj.best_used = float(best), True')]

_SCOPES = {
 'converged': 'Slot.converged', 'stable': 'Slot.stable', 'exact_conv':'Slot.converged',
 'exact_stable':'Slot.stable', 'exact_diameter':'Slot.exact_diameter', 'exact_path':'Slot.converged',
 'noise_floor':'Slot.noise_floor', 'nonvanishing':'Slot.raw_nonvanishing',
 'refdiv':'Slot.reference_diverging', 'D2':'Slot.record', 'improving':'Slot.improving',
 'rel_osc':'Slot.rel_oscillating', 'flips':'Slot.rel_oscillating', 'bounded_osc':'Slot.bounded_oscillating',
 'equilibrium':'Slot.equilibrium', 'one_direction':'Slot.raw_one_direction', 'flags':'Slot.flags',
 'quiet':'Slot.value_reading', 'fmax':'fmax', 'S1_ref':'Policy.step', 'scale':'Slot.__init__',
 'subtraction':'Slot.record', 'opposite_inf':'Slot.opposite_inf', 'finite_window':'Slot.finite_window',
 'report_order':'Slot.report', 'how_inf':'Slot.value_reading', 'refexp':'Slot.reference_expanding',
 'partial_raw':'Slot.raw_nonvanishing', 'partial_report':'Slot.report', 'since_cap':'Slot.record',
 'N1':'Slot.noise_floor', 'S4':'Slot.reference_diverging', 'S6':'Slot.converged',
 'S8':'Slot.stable', 'S2S3':'Slot.record', 'S1_floor':'Policy.step',
 'window_len':'Slot.__init__', 'values_ring':'Slot.record', 'from_traj':'Slot.from_trajectory'}
NUMERIC_SCOPES = ('fmax','divide','logarithm','exponential','is_int','kind',
    'Policy.mode','Policy.fraction','Policy.magnitude','Policy.step','Slot.__init__','Slot.reset','Slot.values','Slot.raw','Slot.exact','Slot.rel',
    'Slot.policy_for','Slot.magnitude','Slot._step','Slot.peak','Slot.set_window',
    'Slot.record','Slot.steps','Slot.all_exact','Slot.noise_floor','Slot.raw_nonvanishing',
    'Slot.raw_diverging','Slot.raw_oscillating','Slot.flags','Slot.rel_oscillating',
    'Slot.bounded_oscillating','Slot.finite_window','Slot.opposite_inf','Slot.oscillating',
    'Slot.diverging','Slot.reference_diverging','Slot.reference_expanding','Slot.improving',
    'Slot.exact_diameter','Slot.converged','Slot.raw_one_direction','Slot.equilibrium',
    'Slot.stable','Slot.report','Slot.reading','Slot.value_reading','Slot.from_trajectory')


def scope(tree, name):
    if name=='<module>':return tree
    parts = name.split('.')
    body = tree.body
    for i, part in enumerate(parts):
        matches = [n for n in body if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name == part]
        if len(matches) != 1:
            # Property setters share their getter's name; numerical census
            # and mutations deliberately select the getter, never the setter.
            matches = [n for n in matches if not any(isinstance(d,ast.Attribute) and d.attr=='setter' for d in getattr(n,'decorator_list',[]))]
        if len(matches) != 1:
            raise ValueError(f'source anchor {name}: {len(matches)} definitions')
        node = matches[0]
        body = node.body
    return node


def site_for(function, fragment=''):
    if function == 'Policy.step': return 'S1'
    if function == 'Slot.record': return 'S2' if 'is_int' in fragment or 'value < threshold' in fragment else 'D2'
    if function == 'Slot.reference_diverging': return 'S4'
    if function == 'Slot.converged': return 'S5' if 'exact' in fragment or 'self.scale' in fragment else 'S6'
    if function == 'Slot.stable': return 'S7' if 'exact' in fragment or 'self.scale' in fragment else 'S8'
    if function == 'Slot.noise_floor': return 'N1'
    return function.rsplit('.',1)[-1]


@lru_cache(maxsize=4)
def source_offsets(source):
    offsets=[0]
    for line in source.splitlines(keepends=True): offsets.append(offsets[-1]+len(line))
    return offsets


def bounds(source,node):
    offsets=source_offsets(source)
    return offsets[node.lineno-1]+node.col_offset, offsets[node.end_lineno-1]+node.end_col_offset


def segment(source,node):
    start,end=bounds(source,node)
    return source[start:end]


def critic_definitions():
    result = []
    for name, old, new in CRITIC:
        matches = [(prefix, f) for prefix,f in _SCOPES.items() if name.startswith(prefix)]
        function = max(matches,key=lambda x:len(x[0]))[1]
        # Preserve each critic's one-fault meaning through the per-site seam.
        mapping = {
            'self.policy.magnitude(self.best, peak, self.scale)': 'self.magnitude("S2" if is_int(value) else "S3", self.best, peak)',
            'self.policy.magnitude(w[-1], self.peak(), self.scale)': 'self.magnitude("S4", w[-1])',
            'self.policy.magnitude(w[0], self.peak(), self.scale)': 'self.magnitude("S4", w[0])',
            'self.policy.magnitude(float(self.values[-1]), self.peak(), self.scale)': 'self.magnitude("S6", float(self.values[-1]))',
            'self.policy.magnitude(midrange, self.peak(), self.scale)': 'self.magnitude("S8", midrange)',
            'self.policy.name in ("F0", "PRE1045")': 'policy.name in ("F0", "PRE1045")',
            'self.values = self.values[-(self.window + 1):]': 'self._values_buffer = self._values_buffer[-(self.capacity + 1):]',
            'self.values = self.values[-(self.window + 2):]': 'self._values_buffer = self._values_buffer[-(self.capacity + 2):]'}
        for before, after in mapping.items():
            old,new = old.replace(before,after),new.replace(before,after)
        new = new.replace('self.policy.magnitude(self.best, peak, 10 * self.scale)', 'fmax(abs(self.best), 10 * self.scale)')
        new = new.replace('self.policy.magnitude(w[-1], self.peak(), 10 * self.scale)', 'fmax(abs(w[-1]), 10 * self.scale)')
        if name == 'D2_threshold_zero_x2':
            old = 'threshold = self.best - self.zero * self.magnitude'
            new = 'threshold = self.best - 2 * self.zero * self.magnitude'
        if name in ('converged_le_to_lt','converged_threshold_x1.01','converged_threshold_x0.99'):
            old='return hi - lo <= self.zero *'
            new=('return hi - lo < self.zero *' if name=='converged_le_to_lt' else
                 'return hi - lo <= '+('1.01' if name.endswith('x1.01') else '0.99')+' * self.zero *')
        if name=='flips_threshold_+1':
            old='return flips >= (self.window + 2) // 3'
            new=old+' + 1'
        result.append({'id':name,'origin':'critic','scope':function,'kind':'text','old':old,'new':new,
                       'site':'D2' if name.startswith('D2') else site_for(function,old),'critic_old':next(x[1] for x in CRITIC if x[0]==name),
                       'critic_new':next(x[2] for x in CRITIC if x[0]==name)})
    return result


_CMP = {ast.Lt:ast.LtE,ast.LtE:ast.Lt,ast.Gt:ast.GtE,ast.GtE:ast.Gt,
        ast.Eq:ast.NotEq,ast.NotEq:ast.Eq,ast.Is:ast.IsNot,ast.IsNot:ast.Is,
        ast.In:ast.NotIn,ast.NotIn:ast.In}
_OPPOSITE = {ast.Lt:ast.GtE,ast.LtE:ast.Gt,ast.Gt:ast.LtE,ast.GtE:ast.Lt}


@lru_cache(maxsize=4)
def census(source=None):
    source = SOURCE.read_text() if source is None else source
    tree = ast.parse(source)
    rows = []
    for name in NUMERIC_SCOPES:
        fn = scope(tree,name)
        parents={id(child):parent for parent in ast.walk(fn) for child in ast.iter_child_nodes(parent)}
        doc=(fn.body[0].value if fn.body and isinstance(fn.body[0],ast.Expr)
             and isinstance(fn.body[0].value,ast.Constant) and isinstance(fn.body[0].value.value,str) else None)
        for index,node in enumerate(ast.walk(fn)):
            if not isinstance(node,(ast.Compare,ast.Constant,ast.Subscript,ast.Attribute,ast.Name,ast.Call)):
                continue
            fragment = segment(source,node)
            base = {'scope':name,'node_index':index,'line':node.lineno if hasattr(node,'lineno') else None,
                    'fragment':fragment,'site':site_for(name,fragment)}
            if isinstance(node,ast.Compare):
                for op_index, op in enumerate(node.ops):
                    rows.append({**base,'kind':'comparison','operator_index':op_index,
                                 'operator':type(op).__name__,'classification':'MUTATED'})
            elif isinstance(node,ast.Constant):
                if node is not doc:
                    rows.append({**base,'kind':'constant','value':node.value,'classification':'MUTATED'})
                else:
                    rows.append({**base,'kind':'constant','classification':'METADATA',
                                 'reason':f'{name} function docstring (__doc__); no classifier expression reads it.'})
            elif isinstance(node,ast.Subscript):
                rows.append({**base,'kind':'reference','classification':'MUTATED'})
            elif isinstance(node,ast.Call):
                rows.append({**base,'kind':'call-reference','classification':'MUTATED',
                             'callee':ast.unparse(node.func)})
            elif isinstance(node,ast.Attribute):
                rows.append({**base,'kind':'reference','classification':'MUTATED','attribute':node.attr})
            elif isinstance(node,ast.Name) and isinstance(node.ctx,ast.Load):
                parent=parents.get(id(node))
                if isinstance(parent,ast.Call) and parent.func is node:
                    rows.append({**base,'kind':'reference','classification':'COVERED_REFERENCE',
                                 'reason':f'Callee {node.id} is mutated at its enclosing call-reference node.',
                                 'covered_fragment':segment(source,parent)})
                elif isinstance(parent,ast.Attribute) and parent.value is node:
                    rows.append({**base,'kind':'reference','classification':'COVERED_REFERENCE',
                                 'reason':f'Receiver/module alias {node.id}: its complete attribute reference is separately mutated.',
                                 'covered_fragment':segment(source,parent)})
                elif node in fn.decorator_list:
                    rows.append({**base,'kind':'reference','classification':'METADATA',
                                 'reason':f'{name} Python property descriptor binding; the complete getter body is in the numeric census.'})
                else:
                    rows.append({**base,'kind':'reference','classification':'MUTATED','name':node.id})
    return rows


@lru_cache(maxsize=4)
def semantic_nodes(source):
    """Location-independent point identities, including STORE/LOAD roles.

    A node's closest statement and its field path identify its semantic
    context. Reordering independent statements or wrapping them in a new
    routing branch preserves their identities; a changed guard/assignment
    gets a fresh identity instead of inheriting a proof by AST index.
    """
    tree=ast.parse(source)
    result={}
    for name in NUMERIC_SCOPES:
        fn=scope(tree,name)
        parents={id(child):parent for parent in ast.walk(fn) for child in ast.iter_child_nodes(parent)}
        for index,node in enumerate(ast.walk(fn)):
            current=node
            path=[]
            while id(current) in parents and not isinstance(current,ast.stmt):
                parent=parents[id(current)]
                edge=None
                for field,value in ast.iter_fields(parent):
                    if value is current:
                        edge=field
                        break
                    if isinstance(value,list):
                        positions=[i for i,item in enumerate(value) if item is current]
                        if positions:
                            edge=field+'['+str(positions[0])+']'
                            break
                if edge is None:
                    raise ValueError('cannot locate semantic AST edge')
                path.append(edge)
                current=parent
            point={'scope':name,'statement':ast.dump(current,include_attributes=False),
                   'path':path[::-1],'node':ast.dump(node,include_attributes=False)}
            result[(name,index)]=hashlib.sha256(json.dumps(point,sort_keys=True).encode()).hexdigest()
    return result


def semantic_anchor(spec, source=None):
    source=SOURCE.read_text() if source is None else source
    if spec['kind']=='text':
        point={key:spec.get(key) for key in ('scope','kind','old','new')}
    else:
        point={key:spec.get(key) for key in ('scope','kind','operator_index','operator','variant')}
        point['node']=semantic_nodes(source)[(spec['scope'],spec['node_index'])]
    return hashlib.sha256(json.dumps(point,sort_keys=True).encode()).hexdigest()


@lru_cache(maxsize=1)
def prior_point_aliases():
    path=HERE/'r33_data'/'site-coverage'/'census-before-routing.json'
    if not path.exists():
        return {}
    registry=json.loads(path.read_text())
    result={}
    for row in registry['points']:
        result.setdefault(row['semantic_anchor'],[]).append(row['id'])
    return result


def definitions(source=None):
    source = SOURCE.read_text() if source is None else source
    result = critic_definitions()
    for name,condition,site in (('S2-int-significance-disabled','is_int(value)','S2'),
                                ('S3-float-significance-disabled','not is_int(value)','S3')):
        result.append({'id':name,'origin':'purpose','scope':'Slot.record','kind':'text','site':site,
                       'old':'value < threshold',
                       'new':f'value < (self.best if {condition} else threshold)'})
    result.extend([
        {'id':'global-INT_MIN-plus1','origin':'purpose','scope':'<module>','kind':'text','site':'D2',
         'old':'INT_MIN, INT_MAX = -(2**63), 2**63 - 1','new':'INT_MIN, INT_MAX = -(2**63)+1, 2**63 - 1'},
        {'id':'global-INT_MAX-minus1','origin':'purpose','scope':'<module>','kind':'text','site':'D2',
         'old':'INT_MIN, INT_MAX = -(2**63), 2**63 - 1','new':'INT_MIN, INT_MAX = -(2**63), 2**63 - 2'},
        {'id':'N1-epsilon-reference-minnormal','origin':'purpose','scope':'Slot.noise_floor','kind':'text','site':'N1',
         'old':'sys.float_info.epsilon','new':'sys.float_info.min'}])
    for row in census(source):
        if row['classification'] != 'MUTATED': continue
        variants = ['strictness','complement'] if row['kind']=='comparison' and row['operator'] in ('Lt','LtE','Gt','GtE') else ['fault']
        for variant in variants:
            result.append({**row,'id':f'ast-{row["scope"]}-{row["kind"]}-{row["node_index"]}-{row.get("operator_index",0)}-{variant}',
                           'origin':'AST','variant':variant})
    aliases=prior_point_aliases()
    for row in result:
        row['semantic_anchor']=semantic_anchor(row,source)
        row['prior_ids']=aliases.get(row['semantic_anchor'],[])
    return result


def mutate_source(spec, source=None):
    source = SOURCE.read_text() if source is None else source
    tree = ast.parse(source)
    fn = scope(tree,spec['scope'])
    if spec['kind']=='text':
        lines=source.splitlines(keepends=True)
        first,last=(0,len(lines)) if spec['scope']=='<module>' else (fn.lineno-1,fn.end_lineno)
        body=''.join(lines[first:last])
        if body.count(spec['old']) != 1:
            raise ValueError(f'{spec["id"]}: expected one source anchor, got {body.count(spec["old"])}')
        lines[first:last]=[body.replace(spec['old'],spec['new'],1)]
        changed=''.join(lines)
    else:
        target=list(ast.walk(fn))[spec['node_index']]
        start,end=bounds(source,target)
        if spec['kind']=='comparison':
            pos=spec['operator_index'];old=target.ops[pos]
            cls=(_OPPOSITE.get(type(old)) if spec['variant']=='complement' else _CMP.get(type(old)))
            if cls is None: raise ValueError(f'unsupported operator {type(old).__name__}')
            target.ops[pos]=cls()
        elif spec['kind']=='constant':
            v=target.value
            target.value=(0.0 if v is None else '<mutated>' if type(v) is str else
                          not v if type(v) is bool else 1 if v==0 else 0 if v==1 else v*2)
        elif spec['kind']=='call-reference':
            if spec['callee']=='fmax':
                target=target.args[0]
            else:
                target.func=ast.parse('(lambda *args, **kwargs: 0.0)',mode='eval').body
        elif isinstance(target,ast.Subscript):
            text=ast.unparse(target.slice)
            target.slice=ast.Constant(0) if text!='0' else ast.UnaryOp(op=ast.USub(),operand=ast.Constant(1))
        elif isinstance(target,ast.Attribute):
            replacements={'zero':'small','small':'zero','scale':'zero','best':'scale','since':'window','window':'since',
                          'raw':'rel','rel':'raw','exact':'raw','values':'raw','count':'since',
                          'best_used':'observed','numeric':'best_used','observed':'numeric',
                          'capacity':'window','peak_abs':'best',
                          '_values_buffer':'_raw_buffer','_raw_buffer':'_rel_buffer',
                          '_exact_buffer':'_raw_buffer','_rel_buffer':'_raw_buffer',
                          'inf':'nan','nan':'inf','epsilon':'min','min':'epsilon','float_info':'int_info',
                          'isnan':'isinf','isinf':'isnan','isfinite':'isinf','copysign':'atan2','exp':'expm1','log':'log2'}
            target.attr=replacements.get(target.attr,'zero' if isinstance(target.value,ast.Name) and target.value.id=='self' else 'inf')
        else:
            target=ast.copy_location(ast.Constant(0.0),target)
        changed=source[:start]+'('+ast.unparse(ast.fix_missing_locations(target))+')'+source[end:]
    if source==changed:
        raise ValueError(f'{spec["id"]}: stillborn fault leaves source unchanged')
    compile(changed,'<r33-f0-mutant>','exec')
    return changed


def mutated_slot(identifier, source=None):
    source=SOURCE.read_text() if source is None else source
    if isinstance(identifier,dict):
        spec=identifier
    else:
        spec=next((x for x in critic_definitions() if x['id']==identifier),None)
        if spec is None: spec=next(x for x in definitions(source) if x['id']==identifier)
    module=types.ModuleType('_r33_fault_'+hashlib.sha256(spec['id'].encode()).hexdigest()[:16])
    sys.modules[module.__name__]=module
    exec(compile(mutate_source(spec,source),'<r33-f0-mutant>','exec'),module.__dict__)
    return module.Slot


def model_case(row, cls=None):
    if cls is None:
        import r33_port
        cls=r33_port.Slot
    slot=cls(policy='F0',window=row.get('window',10))
    result={}
    fields=('converged','stable','improving','oscillating','diverging','equilibrium','report','where','where_kind','why','why_kind','how','count')
    for at,value in enumerate(row['values']):
        slot.record(int(value['value']) if value['kind']=='int' else float.fromhex(value['value']))
        if at in row['checkpoints']:
            r=slot.reading()
            for field in fields: result[(row['id'],at,field)]=r[field]
    return result


def decode(value):
    if isinstance(value,dict) and set(value)=={'float'}: return float.fromhex(value['float'])
    return value


def same(a,b):
    if type(a) is float and type(b) is float:
        if math.isnan(a) and math.isnan(b): return True
        if a==b==0.0: return math.copysign(1,a)==math.copysign(1,b)
    return type(a)==type(b) and a==b


def verify_site_plants(casepath,binarypath, identifiers=None):
    cases=[json.loads(line) for line in Path(casepath).read_text().splitlines() if line]
    saved=json.loads(Path(binarypath).read_text())
    if saved.get('format')!='r33-site-binary/1': raise ValueError('unknown saved binary reading schema')
    actual={tuple(r['key']):decode(r['value']) for r in saved['readings']}
    baseline={k:v for row in cases for k,v in model_case(row).items()}
    if set(actual)!=set(baseline) or any(not same(v,actual[k]) for k,v in baseline.items()):
        raise ValueError('baseline F0 differs from saved real binary fixture readings')
    selected=definitions() if identifiers is None else [d for d in definitions() if d['id'] in identifiers]
    if identifiers is not None and {d['id'] for d in selected} != set(identifiers):
        raise ValueError('unknown requested site mutant ID')
    result=[]
    for spec in selected:
        witness=None
        try:
            cls=mutated_slot(spec)
            for row in cases:
                got=model_case(row,cls)
                key=next((k for k,v in got.items() if not same(v,actual[k])),None)
                if key is not None:
                    witness={'key':list(key),'mutant':repr(got[key]),'binary':repr(actual[key])};break
        except Exception as error:
            witness={'error':f'{type(error).__name__}: {error}'}
        result.append({'id':spec['id'],'site':spec['site'],'caught':witness is not None,
                       'reading':witness,'origin':spec['origin']})
    return result


def inventory(source=None):
    source=SOURCE.read_text() if source is None else source
    specs=definitions(source)
    rows=[]
    for spec in specs:
        try: mutate_source(spec,source);anchor='LIVE'
        except Exception as e: anchor=f'ERROR {e}'
        rows.append({**spec,'anchor':anchor,'status':'UNRESOLVED','reason':None,'witness':None})
    return {'format':'r33-mutation-inventory/2','source_sha256':hashlib.sha256(source.encode()).hexdigest(),
            'critic_definition_count':len(CRITIC),'census':census(source),'mutants':rows,
            'outside_numeric_census':[
                {'function':'Policy.__post_init__','reason':'Rejects unknown experimental-arm identifiers; F0 identity fixes the arm name. This configuration validator is not a numerical verdict condition.'},
                {'function':'Slot.copy','reason':'Deep-copy transport; copied classifier state is tested by structured binary surfaces, while numeric fold/query decisions are inventoried here.'},
                {'function':'Slot.dh','reason':'Nonnumeric entropy-history accessor, outside the value-route numerical predicates.'},
                {'function':'Slot.detour','reason':'String-entropy route. Structured binary cases test preservation of numeric state across detours; this census does not claim entropy-classifier fault coverage.'},
                {'function':'Slot.snapshot','reason':'Snapshot transport of reading(); every numeric query expression in value_reading is in this census. Temporal binary outputs independently check snapshot preservation.'},
                {'function':'Slot.trajectory','reason':'Serialization of state and stored numeric channels; structured binary outputs check each exported channel. Numeric record/read comparisons are censused separately.'},
],
            'unqueried':[{'field':'quiet','status':'UNREACHABLE','reason':'Commit54008422 has no language query for quiet; explicitly not compared under addendum2 item1.'}]}


if __name__=='__main__':
    if len(sys.argv)!=2: raise SystemExit('usage: r33_mutants.py OUTPUT-INVENTORY.json')
    output=Path(sys.argv[1]);output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(inventory(),indent=2,sort_keys=True)+'\n')
