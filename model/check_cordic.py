#!/usr/bin/env python3
"""Compare RTL CORDIC output against numpy cos/sin."""
import numpy as np, sys
QF=14
exp = [l.split() for l in open('vectors/cordic_expected.txt')]
rtl = [l.split() for l in open('vectors/cordic_rtl.txt')]
assert len(exp)==len(rtl), f"count mismatch {len(exp)} vs {len(rtl)}"
maxc=maxs=0.0
for (a,ec,es),(rc,rs) in zip(exp,rtl):
    rc=int(rc)/(1<<QF); rs=int(rs)/(1<<QF)
    ec=float(ec); es=float(es)
    maxc=max(maxc,abs(rc-ec)); maxs=max(maxs,abs(rs-es))
TOL=1.5e-3
print(f"CORDIC vectors={len(exp)}  max_cos_err={maxc:.2e}  max_sin_err={maxs:.2e}  tol={TOL:.1e}")
if maxc<TOL and maxs<TOL:
    print("CORDIC: PASS"); sys.exit(0)
print("CORDIC: FAIL"); sys.exit(1)
