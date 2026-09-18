#!/usr/bin/env python3
"""
Variational Quantum Classifier trained ON THE VERILOG ACCELERATOR.

Circuit (2 qubits), observable <Z0>:
    RESET
    RY(x1) q0 ; RY(x2) q1            # angle encoding of the 2 features
    RY(t0) q0 ; RY(t1) q1 ; CX(0->1) # variational layer 1
    RY(t2) q0 ; RY(t3) q1 ; CX(0->1) # variational layer 2
    MEAS <Z0>

Both the forward value E=<Z0> and every gradient dE/dt_p are produced by the
RTL (gate_gen CORDIC + qpu_core + parameter-shift controller), executed through
the fast batch testbench.  Training = plain gradient descent on MSE loss.

Parameter RAM layout (addresses):
    0: x1   1: x2   2: t0   3: t1   4: t2   5: t3
"""
import numpy as np, os, subprocess, sys
from golden_model import to_q, from_q, AF, AW, QF, hex_word, Instr, run_program
from system_tests import pack

PD = 64
THETA_ADDR = [2,3,4,5]          # trainable parameter addresses
HALFPI_Q = 6434
SHIFT = HALFPI_Q/(1<<AF)
os.makedirs('vectors/batch', exist_ok=True)

# ---- fixed circuit -------------------------------------------------------
CIRCUIT = [
    dict(op='RESET'),
    dict(op='RY',qa=0,pidx=0), dict(op='RY',qa=1,pidx=1),          # encoding
    dict(op='RY',qa=0,pidx=2), dict(op='RY',qa=1,pidx=3),          # var layer 1
    dict(op='X', qa=1,mask=0b01),                                  # CX 0->1
    dict(op='RY',qa=0,pidx=4), dict(op='RY',qa=1,pidx=5),          # var layer 2
    dict(op='X', qa=1,mask=0b01),                                  # CX 0->1
    dict(op='MEAS_Z',mask=0b01),                                   # <Z0>
    dict(op='HALT')]

def write_prog():
    with open('vectors/batch/prog.hex','w') as f:
        for ins in CIRCUIT:
            f.write(pack(**{k:ins[k] for k in ins}) + "\n")
    with open('vectors/batch/zero.hex','w') as f:
        for _ in range(PD): f.write("0000\n")

def param_slice(x1,x2,theta):
    v = [0.0]*PD
    v[0]=x1; v[1]=x2
    for a,t in zip(THETA_ADDR, theta): v[a]=t
    return v

# ---- batch runner --------------------------------------------------------
def run_batch(slices, jobs, nq=2):
    """slices: list of PD-length param vectors (one per job).
       jobs:   list of (mode, grad_addr). Returns list of floats (E or grad)."""
    with open('vectors/batch/params.hex','w') as f:
        for s in slices:
            for v in s: f.write(hex_word(to_q(v,AF,AW),AW)+"\n")
    with open('vectors/batch/jobs.txt','w') as f:
        f.write("%d %d\n"%(len(jobs), nq))
        for (m,ga) in jobs: f.write("%d %d\n"%(m,ga))
    r = subprocess.run(['vvp','../sim/tb_batch.vvp'], capture_output=True, text=True)
    if 'TIMEOUT' in r.stdout: raise RuntimeError("batch timeout\n"+r.stdout)
    res = [int(l)/(1<<28) for l in open('vectors/batch/results.txt') if l.strip()]
    if len(res)!=len(jobs):
        raise RuntimeError(f"got {len(res)} results, expected {len(jobs)}\n{r.stdout}\n{r.stderr}")
    return res

# ---- golden equivalents (for cross-checking the hardware) ----------------
def golden_forward(x1,x2,theta):
    prog=[]
    vals={0:x1,1:x2,2:theta[0],3:theta[1],4:theta[2],5:theta[3]}
    for ins in CIRCUIT:
        op=ins['op']
        if op in ('RESET','HALT'): prog.append(Instr(op))
        elif op=='MEAS_Z': prog.append(Instr('MEAS_Z',zmask=ins['mask']))
        elif op=='X': prog.append(Instr('X',qa=ins['qa'],ctrl=ins.get('mask',0)))
        elif op=='RY': prog.append(Instr('RY',qa=ins['qa'],params=[vals[ins['pidx']]]))
    _,m=run_program(prog,2); return m[-1]

def golden_grad(x1,x2,theta,p):
    tp=list(theta); tp[p]+=SHIFT
    tm=list(theta); tm[p]-=SHIFT
    return 0.5*(golden_forward(x1,x2,tp)-golden_forward(x1,x2,tm))
