#!/usr/bin/env python3
"""
End-to-end verification: assemble circuits into prog.hex/param.hex, run the
Verilog accelerator, and compare final state / expectation / parameter-shift
gradient against the numpy golden model.
"""
import numpy as np, os, subprocess, sys
from golden_model import (OPC, ONEQ, TWOQ, Instr, run_program, u_1q, u_2q,
                          apply_1q, apply_2q, expectation_z, to_q, from_q,
                          AF, AW, QF, hex_word)

os.makedirs('vectors', exist_ok=True)
PDEPTH = 64
HALFPI_Q = 6434                     # pi/2 in Q4.12 (matches RTL HALFPI_Q412)
SHIFT    = HALFPI_Q / (1 << AF)     # exact shift used by hardware

# ---- how many angle slots each op consumes --------------------------------
def nparams(op):
    if op in ('RX','RY','RZ','P','RXX','RYY','RZZ','RZX'): return 1
    if op == 'U2': return 2
    if op == 'U3': return 3
    return 0

# ---- assembler ------------------------------------------------------------
def pack(op, qa=0, qb=0, mask=0, pidx=0):
    w = (OPC[op] << 56) | ((qa & 0xF) << 52) | ((qb & 0xF) << 48) \
        | ((mask & 0xFFFF) << 32) | ((pidx & 0xFFFF) << 16)
    return "%016x" % w

def write_prog(instrs):
    with open('vectors/prog.hex','w') as f:
        for ins in instrs:
            f.write(pack(**ins) + "\n")

def write_param(params):
    arr = [0.0]*PDEPTH
    for a,v in params.items(): arr[a] = v
    with open('vectors/param.hex','w') as f:
        for v in arr:
            f.write(hex_word(to_q(v, AF, AW), AW) + "\n")

def write_cfg(nq, mode, grad_addr):
    with open('vectors/cfg.txt','w') as f:
        f.write("%d %d %d\n" % (nq, mode, grad_addr))

# ---- golden execution of an assembled circuit -----------------------------
def golden_run(instrs, params, nq):
    prog = []
    for ins in instrs:
        op = ins['op']
        if op in ('RESET','HALT','NOP'):
            prog.append(Instr(op)); continue
        if op == 'MEAS_Z':
            prog.append(Instr('MEAS_Z', zmask=ins.get('mask',0))); continue
        p=[]
        for k in range(nparams(op)):
            p.append(params.get(ins['pidx']+k, 0.0))
        prog.append(Instr(op, qa=ins.get('qa',0), qb=ins.get('qb',0),
                          ctrl=ins.get('mask',0), params=p))
    st, meas = run_program(prog, nq)
    return st, meas

def golden_grad(instrs, params, nq, addr):
    pp = dict(params); pp[addr] = params.get(addr,0.0) + SHIFT
    _, mp = golden_run(instrs, pp, nq)
    pm = dict(params); pm[addr] = params.get(addr,0.0) - SHIFT
    _, mm = golden_run(instrs, pm, nq)
    return 0.5*(mp[-1] - mm[-1])

# ---- run RTL --------------------------------------------------------------
def run_rtl():
    r = subprocess.run(['vvp','../sim/tb_system.vvp'], capture_output=True, text=True)
    if 'TIMEOUT' in r.stdout: raise RuntimeError("RTL timeout\n"+r.stdout)
    lines = open('vectors/sys_rtl.txt').read().split('\n')
    result_q28 = int(lines[0].split()[1])
    amps=[]
    for l in lines[1:]:
        if l.strip():
            re_,im_ = l.split(); amps.append(int(re_)/(1<<QF)+1j*int(im_)/(1<<QF))
    return result_q28/(1<<28), np.array(amps)

# ===========================================================================
# Test circuits
# ===========================================================================
TESTS = []

def add(name, nq, params, instrs, mode=0, grad_addr=0, check_state=True):
    TESTS.append(dict(name=name,nq=nq,params=params,instrs=instrs,
                      mode=mode,grad_addr=grad_addr,check_state=check_state))

# 1) Bell state + <Z0 Z1>
add("bell", 2, {}, [
    dict(op='RESET'), dict(op='H',qa=0),
    dict(op='X',qa=1,mask=0b0001),          # CX control q0 -> target q1
    dict(op='MEAS_Z',mask=0b0011),          # <Z0 Z1>
    dict(op='HALT')])

# 2) RY rotation, <Z> = cos(theta)
add("ry_expect", 1, {0:0.7}, [
    dict(op='RESET'), dict(op='RY',qa=0,pidx=0),
    dict(op='MEAS_Z',mask=0b1), dict(op='HALT')])

# 3) all fixed single-qubit gates on |0> then |+>
add("fixed_gates", 1, {}, [
    dict(op='RESET'), dict(op='H',qa=0), dict(op='S',qa=0), dict(op='T',qa=0),
    dict(op='SX',qa=0), dict(op='Z',qa=0), dict(op='SDG',qa=0),
    dict(op='MEAS_Z',mask=0b1), dict(op='HALT')])

# 4) two-qubit gates: prepare |01>, SWAP -> |10>
add("swap", 2, {}, [
    dict(op='RESET'), dict(op='X',qa=0),
    dict(op='SWAP',qa=0,qb=1),
    dict(op='MEAS_Z',mask=0b0010), dict(op='HALT')])

# 5) iSWAP on |01>
add("iswap", 2, {}, [
    dict(op='RESET'), dict(op='X',qa=0),
    dict(op='ISWAP',qa=0,qb=1),
    dict(op='MEAS_Z',mask=0b0011), dict(op='HALT')])

# 6) Ising RXX on |00>
add("rxx", 2, {0:0.9}, [
    dict(op='RESET'), dict(op='RXX',qa=0,qb=1,pidx=0),
    dict(op='MEAS_Z',mask=0b0011), dict(op='HALT')])

# 7) Toffoli: |110> -> flip q2 -> |111>
add("toffoli", 3, {}, [
    dict(op='RESET'), dict(op='X',qa=0), dict(op='X',qa=1),
    dict(op='X',qa=2,mask=0b0011),          # CCX controls q0,q1
    dict(op='MEAS_Z',mask=0b0100), dict(op='HALT')])

# 8) U3 arbitrary single-qubit
add("u3", 1, {0:0.6,1:1.1,2:-0.7}, [
    dict(op='RESET'), dict(op='U3',qa=0,pidx=0),
    dict(op='MEAS_Z',mask=0b1), dict(op='HALT')])

# 9) 3-qubit angle-encoding + entangling feature map
add("feature_map", 3, {0:0.5,1:-0.8,2:1.2,3:0.3}, [
    dict(op='RESET'),
    dict(op='RY',qa=0,pidx=0), dict(op='RY',qa=1,pidx=1), dict(op='RY',qa=2,pidx=2),
    dict(op='Z',qa=1,mask=0b0001),          # CZ(0,1)
    dict(op='Z',qa=2,mask=0b0010),          # CZ(1,2)
    dict(op='RX',qa=2,pidx=3),
    dict(op='MEAS_Z',mask=0b0100), dict(op='HALT')])

# 10) parameter-shift gradient of a variational circuit wrt param[0]
grad_circ = [
    dict(op='RESET'),
    dict(op='RY',qa=0,pidx=0), dict(op='RY',qa=1,pidx=1),
    dict(op='X',qa=1,mask=0b0001),          # CX(0,1)
    dict(op='RY',qa=1,pidx=2),
    dict(op='MEAS_Z',mask=0b0011), dict(op='HALT')]
add("grad_wrt_p0", 2, {0:0.4,1:-0.9,2:1.3}, grad_circ, mode=1, grad_addr=0, check_state=False)
add("grad_wrt_p2", 2, {0:0.4,1:-0.9,2:1.3}, grad_circ, mode=1, grad_addr=2, check_state=False)

# ===========================================================================
def main():
    TOL_STATE = 6e-3
    TOL_EXP   = 6e-3
    TOL_GRAD  = 1.5e-2
    npass=0; nfail=0
    print("="*74)
    for t in TESTS:
        write_prog(t['instrs']); write_param(t['params'])
        write_cfg(t['nq'], t['mode'], t['grad_addr'])
        res, amps = run_rtl()
        st, meas = golden_run(t['instrs'], t['params'], t['nq'])
        ok=True; detail=""
        if t['mode']==0:
            # expectation
            if meas:
                ge = meas[-1]
                de = abs(res-ge)
                if de>TOL_EXP: ok=False
                detail += f"E_rtl={res:+.4f} E_gold={ge:+.4f} dE={de:.1e}  "
            if t['check_state']:
                dmax=float(np.max(np.abs(amps-st)))
                if dmax>TOL_STATE: ok=False
                detail += f"state_err={dmax:.1e}"
        else:
            gg = golden_grad(t['instrs'], t['params'], t['nq'], t['grad_addr'])
            dg = abs(res-gg)
            if dg>TOL_GRAD: ok=False
            detail += f"grad_rtl={res:+.4f} grad_gold={gg:+.4f} dG={dg:.1e}"
        tag = "PASS" if ok else "FAIL"
        if ok: npass+=1
        else:  nfail+=1
        print(f"[{tag}] {t['name']:<16} {detail}")
    print("="*74)
    print(f"SYSTEM TESTS: {npass} passed, {nfail} failed")
    sys.exit(0 if nfail==0 else 1)

if __name__=='__main__':
    main()
