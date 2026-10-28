PREDS = ("converged", "stable", "improving", "oscillating", "diverging", "equilibrium")
CERTIFICATE_KINDS = ("symbolic", "exact", "fixed-point", "ieee", "manual")
RULES = frozenset({("converged", "MATH"), ("converged", "CONVENTION"), ("stable", "CONVENTION"), ("improving", "CONVENTION"),
                   ("oscillating", "MATH"), ("diverging", "MATH"),
                   ("equilibrium", "MATH")})
