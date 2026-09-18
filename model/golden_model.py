#!/usr/bin/env python3
"""
Golden reference model for the QML hardware accelerator.
================================================================
This is a state-vector simulator written in numpy that implements EXACTLY the
same operation set as the Verilog RTL.  It is the "source of truth":

  * it defines the opcode encoding, the fixed-point formats and the
    instruction word layout that the RTL must agree with,
  * it can EXECUTE a program (list of instructions) the same way the hardware
    sequencer does,
  * it emits the memory-init files (.hex) that the Verilog testbench loads,
  * it writes the expected numerical results that check.py compares the RTL
    output against.

Everything the hardware does can be reproduced here in floating point, so any
discrepancy larger than the fixed-point tolerance is a real bug.
"""

import numpy as np
import os

# ----------------------------------------------------------------------------
# Fixed-point formats  (must match rtl/qml_defs.vh)
# ----------------------------------------------------------------------------
DW  = 16          # amplitude / matrix-coefficient word width (signed)
QF  = 14          # fractional bits for amplitudes & coefficients -> Q1.14
AW  = 16          # angle word width (signed)
AF  = 12          # fractional bits for angles -> Q4.12 (range +/-8 rad)

ONE_Q14 = 1 << QF          # 1.0 in Q1.14
AMAX    = (1 << (DW-1)) - 1
AMIN    = -(1 << (DW-1))


def to_q(x, frac=QF, width=DW):
    """float -> signed fixed-point integer with rounding + saturation."""
    v = int(np.round(x * (1 << frac)))
    hi = (1 << (width-1)) - 1
    lo = -(1 << (width-1))
    return max(lo, min(hi, v))


def from_q(v, frac=QF):
    return v / (1 << frac)


def hex_word(v, width):
    """two's-complement hex string of given bit width."""
    if v < 0:
        v += (1 << width)
    return format(v & ((1 << width)-1), 'x')


# ----------------------------------------------------------------------------
# Opcode map (must match rtl/qml_defs.vh)
# ----------------------------------------------------------------------------
OPC = {
    'NOP'   : 0x00,
    'I'     : 0x01, 'X': 0x02, 'Y': 0x03, 'Z': 0x04, 'H': 0x05,
    'S'     : 0x06, 'SDG': 0x07, 'T': 0x08, 'TDG': 0x09,
    'SX'    : 0x0A, 'SXDG': 0x0B,
    'RX'    : 0x10, 'RY': 0x11, 'RZ': 0x12, 'P': 0x13, 'U2': 0x14, 'U3': 0x15,
    'SWAP'  : 0x20, 'ISWAP': 0x21, 'SQSWAP': 0x22,
    'RXX'   : 0x23, 'RYY': 0x24, 'RZZ': 0x25, 'RZX': 0x26,
    'MEAS_Z': 0x30,
    'RESET' : 0xF0,
    'HALT'  : 0xFF,
}

ONEQ = set(['I','X','Y','Z','H','S','SDG','T','TDG','SX','SXDG',
            'RX','RY','RZ','P','U2','U3'])
TWOQ = set(['SWAP','ISWAP','SQSWAP','RXX','RYY','RZZ','RZX'])
PARAM1 = set(['RX','RY','RZ','P','RXX','RYY','RZZ','RZX'])   # 1 angle
PARAM2 = set(['U2'])                                         # phi, lambda
PARAM3 = set(['U3'])                                         # theta, phi, lambda

# ----------------------------------------------------------------------------
# 2x2 single-qubit unitaries
# ----------------------------------------------------------------------------
INV_SQRT2 = 1/np.sqrt(2)

def u_1q(name, params):
    c = np.cos; s = np.sin; e = np.exp
    if name == 'I': return np.eye(2, dtype=complex)
    if name == 'X': return np.array([[0,1],[1,0]], dtype=complex)
    if name == 'Y': return np.array([[0,-1j],[1j,0]], dtype=complex)
    if name == 'Z': return np.array([[1,0],[0,-1]], dtype=complex)
    if name == 'H': return INV_SQRT2*np.array([[1,1],[1,-1]], dtype=complex)
    if name == 'S': return np.array([[1,0],[0,1j]], dtype=complex)
    if name == 'SDG': return np.array([[1,0],[0,-1j]], dtype=complex)
    if name == 'T': return np.array([[1,0],[0,e(1j*np.pi/4)]], dtype=complex)
    if name == 'TDG': return np.array([[1,0],[0,e(-1j*np.pi/4)]], dtype=complex)
    if name == 'SX':  return 0.5*np.array([[1+1j,1-1j],[1-1j,1+1j]], dtype=complex)
    if name == 'SXDG':return 0.5*np.array([[1-1j,1+1j],[1+1j,1-1j]], dtype=complex)
    th = params[0] if len(params)>0 else 0.0
    ph = params[1] if len(params)>1 else 0.0
    la = params[2] if len(params)>2 else 0.0
    if name == 'RX':
        return np.array([[c(th/2), -1j*s(th/2)],[-1j*s(th/2), c(th/2)]], dtype=complex)
    if name == 'RY':
        return np.array([[c(th/2), -s(th/2)],[s(th/2), c(th/2)]], dtype=complex)
    if name == 'RZ':
        return np.array([[e(-1j*th/2),0],[0,e(1j*th/2)]], dtype=complex)
    if name == 'P':   # phase / U1, angle = th (lambda)
        return np.array([[1,0],[0,e(1j*th)]], dtype=complex)
    if name == 'U2':  # params = (phi, lambda) at indices 0,1
        ph2 = params[0] if len(params)>0 else 0.0
        la2 = params[1] if len(params)>1 else 0.0
        return INV_SQRT2*np.array([[1, -e(1j*la2)],
                                   [e(1j*ph2), e(1j*(ph2+la2))]], dtype=complex)
    if name == 'U3':  # params = theta, phi, lambda
        return np.array([[c(th/2), -e(1j*la)*s(th/2)],
                         [e(1j*ph)*s(th/2), e(1j*(ph+la))*c(th/2)]], dtype=complex)
    raise ValueError(name)


def u_2q(name, params):
    c = np.cos; s = np.sin
    th = params[0] if params else 0.0
    if name == 'SWAP':
        return np.array([[1,0,0,0],[0,0,1,0],[0,1,0,0],[0,0,0,1]], dtype=complex)
    if name == 'ISWAP':
        return np.array([[1,0,0,0],[0,0,1j,0],[0,1j,0,0],[0,0,0,1]], dtype=complex)
    if name == 'SQSWAP':
        return np.array([[1,0,0,0],
                         [0,0.5*(1+1j),0.5*(1-1j),0],
                         [0,0.5*(1-1j),0.5*(1+1j),0],
                         [0,0,0,1]], dtype=complex)
    if name == 'RXX':
        cc=c(th/2); ss=-1j*s(th/2)
        return np.array([[cc,0,0,ss],[0,cc,ss,0],[0,ss,cc,0],[ss,0,0,cc]], dtype=complex)
    if name == 'RYY':
        cc=c(th/2); ss=1j*s(th/2)
        return np.array([[cc,0,0,ss],[0,cc,-ss,0],[0,-ss,cc,0],[ss,0,0,cc]], dtype=complex)
    if name == 'RZZ':
        em=np.exp(-1j*th/2); ep=np.exp(1j*th/2)
        return np.diag([em,ep,ep,em]).astype(complex)
    if name == 'RZX':
        cc=c(th/2); ss=-1j*s(th/2)
        # RZX = exp(-i th/2 Z⊗X), basis |q_a q_b>
        return np.array([[cc,ss,0,0],[ss,cc,0,0],[0,0,cc,-ss],[0,0,-ss,cc]], dtype=complex)
    raise ValueError(name)


# ----------------------------------------------------------------------------
# Application kernels (mirror the RTL engines)
# ----------------------------------------------------------------------------
def apply_1q(state, U, target, n, ctrl_mask=0):
    """Apply 2x2 U to `target` for all basis states where (i & ctrl_mask)==ctrl_mask."""
    st = state.copy()
    tbit = 1 << target
    for i in range(1 << n):
        if (i & tbit): continue                 # only iterate over target=0 index
        if (i & ctrl_mask) != ctrl_mask: continue
        j = i | tbit
        a0, a1 = state[i], state[j]
        st[i] = U[0,0]*a0 + U[0,1]*a1
        st[j] = U[1,0]*a0 + U[1,1]*a1
    return st


def apply_2q(state, U, qa, qb, n, ctrl_mask=0):
    """Apply 4x4 U to (qa=MSB, qb=LSB of the 2-bit subspace)."""
    st = state.copy()
    ba, bb = 1 << qa, 1 << qb
    for i in range(1 << n):
        if (i & ba) or (i & bb): continue
        if (i & ctrl_mask) != ctrl_mask: continue
        idx = [i, i|bb, i|ba, i|ba|bb]           # 00,01,10,11
        amp = np.array([state[k] for k in idx])
        new = U @ amp
        for t,k in enumerate(idx):
            st[k] = new[t]
    return st


def expectation_z(state, zmask, n):
    """<product of Z over qubits in zmask> = sum_i (-1)^popcount(i&zmask) |amp_i|^2."""
    val = 0.0
    for i in range(1 << n):
        p = bin(i & zmask).count('1') & 1
        val += (-1 if p else 1) * (abs(state[i])**2)
    return val.real


# ----------------------------------------------------------------------------
# High-level program execution (mirrors the sequencer + PSR controller)
# ----------------------------------------------------------------------------
class Instr:
    def __init__(self, op, qa=0, qb=0, ctrl=0, params=None, zmask=0):
        self.op = op; self.qa=qa; self.qb=qb; self.ctrl=ctrl
        self.params = params or []
        self.zmask = zmask


def run_program(prog, n, init=None):
    """Execute a list of Instr; return (final_state, list_of_measurements)."""
    st = init.copy() if init is not None else None
    if st is None:
        st = np.zeros(1 << n, dtype=complex); st[0] = 1.0
    meas = []
    for ins in prog:
        if ins.op in ('NOP',): continue
        if ins.op == 'RESET':
            st = np.zeros(1 << n, dtype=complex); st[0] = 1.0
        elif ins.op == 'HALT':
            break
        elif ins.op == 'MEAS_Z':
            meas.append(expectation_z(st, ins.zmask, n))
        elif ins.op in ONEQ:
            st = apply_1q(st, u_1q(ins.op, ins.params), ins.qa, n, ins.ctrl)
        elif ins.op in TWOQ:
            st = apply_2q(st, u_2q(ins.op, ins.params), ins.qa, ins.qb, n, ins.ctrl)
        else:
            raise ValueError(ins.op)
    return st, meas


if __name__ == '__main__':
    # quick self-test of the model
    n = 2
    st,_ = run_program([Instr('H',0), Instr('X',1,ctrl=1)], n)  # not a real bell, just smoke
    print("state ok, norm =", np.round(np.vdot(st,st).real,6))
    print("constants: 1/sqrt2 Q1.14 =", to_q(INV_SQRT2), " (=%.6f)"%from_q(to_q(INV_SQRT2)))
    print("pi/2 Q4.12 =", to_q(np.pi/2, AF, AW))
