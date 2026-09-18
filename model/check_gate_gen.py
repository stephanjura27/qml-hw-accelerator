#!/usr/bin/env python3
"""Compare gate_gen RTL matrices against ideal numpy matrices."""
import sys
QF=14
exp = [l.split() for l in open('vectors/gate_expected.txt')]
rtl = [l.split() for l in open('vectors/gate_rtl.txt')]
assert len(exp)==len(rtl), f"count mismatch {len(exp)} vs {len(rtl)}"
TOL=2.0e-3
worst=0.0; worst_name=''
fails=0
for gi,(e,r) in enumerate(zip(exp,rtl)):
    kind=e[0]
    r=[int(x)/(1<<QF) for x in r]           # 8 m1q + 32 m2q
    m1=r[0:8]; m2=r[8:40]
    ev=[float(x) for x in e[1:]]
    if kind=='1q':
        # ev has 4 complex = 8 floats; m1 has 8
        for a,b in zip(ev,m1):
            d=abs(a-b)
            if d>worst: worst=d; worst_name=f"gate#{gi} 1q"
            if d>TOL: fails+=1
    else:
        for a,b in zip(ev,m2):
            d=abs(a-b)
            if d>worst: worst=d; worst_name=f"gate#{gi} 2q"
            if d>TOL: fails+=1
print(f"gate_gen gates={len(exp)}  worst_err={worst:.2e} ({worst_name})  tol={TOL:.1e}  fails={fails}")
print("gate_gen: PASS" if fails==0 else "gate_gen: FAIL"); sys.exit(0 if fails==0 else 1)
