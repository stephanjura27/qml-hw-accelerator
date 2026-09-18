#!/usr/bin/env python3
"""Randomized differential testing: many random circuits, RTL vs golden."""
import numpy as np, sys, random
import system_tests as S
from golden_model import OPC

FIXED1 = ['I','X','Y','Z','H','S','SDG','T','TDG','SX','SXDG']
PARAM1 = ['RX','RY','RZ','P']
U23    = ['U2','U3']
FIX2   = ['SWAP','ISWAP','SQSWAP']
PAR2   = ['RXX','RYY','RZZ','RZX']

def rand_circuit(nq, depth, rng):
    instrs=[dict(op='RESET')]
    params={}
    pidx=0
    for _ in range(depth):
        kind = rng.random()
        if kind < 0.45:                       # single-qubit (maybe controlled)
            g = rng.choice(FIXED1+PARAM1+U23)
            qa = rng.randrange(nq)
            # optional controls (exclude target)
            mask=0
            if nq>1 and rng.random()<0.4:
                others=[q for q in range(nq) if q!=qa]
                nc=rng.randint(1,len(others))
                for q in rng.sample(others,nc): mask|=(1<<q)
            ins=dict(op=g,qa=qa,mask=mask)
            npar = S.nparams(g)
            if npar>0:
                ins['pidx']=pidx
                for k in range(npar):
                    params[pidx+k]=rng.uniform(-np.pi,np.pi);
                pidx+=npar
            instrs.append(ins)
        else:                                  # two-qubit
            if nq<2: continue
            g = rng.choice(FIX2+PAR2)
            qa,qb = rng.sample(range(nq),2)
            ins=dict(op=g,qa=qa,qb=qb)
            if S.nparams(g)>0:
                ins['pidx']=pidx; params[pidx]=rng.uniform(-np.pi,np.pi); pidx+=1
            instrs.append(ins)
    # final measurement over a random Z-string
    zmask = rng.randrange(1, 1<<nq)
    instrs.append(dict(op='MEAS_Z',mask=zmask))
    instrs.append(dict(op='HALT'))
    return instrs, params

def main():
    rng = random.Random(1234)
    NRUN = 40
    TOL_STATE=1.5e-2; TOL_EXP=1.0e-2
    npass=nfail=0; worst_s=0; worst_e=0
    for i in range(NRUN):
        nq = rng.choice([2,3,4])
        depth = rng.randint(4,10)
        instrs,params = rand_circuit(nq,depth,rng)
        S.write_prog(instrs); S.write_param(params); S.write_cfg(nq,0,0)
        res,amps = S.run_rtl()
        st,meas = S.golden_run(instrs,params,nq)
        de = abs(res-meas[-1]) if meas else 0
        ds = float(np.max(np.abs(amps-st)))
        worst_s=max(worst_s,ds); worst_e=max(worst_e,de)
        ok = (ds<=TOL_STATE and de<=TOL_EXP)
        if ok: npass+=1
        else:
            nfail+=1
            print(f"  FAIL #{i} nq={nq} depth={depth} dE={de:.2e} dS={ds:.2e}")
            for ins in instrs: print("     ",ins)
    print(f"FUZZ: {npass}/{NRUN} passed  worst_state_err={worst_s:.2e}  worst_exp_err={worst_e:.2e}")
    sys.exit(0 if nfail==0 else 1)

if __name__=='__main__':
    main()
