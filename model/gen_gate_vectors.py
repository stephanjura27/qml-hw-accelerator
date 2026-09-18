#!/usr/bin/env python3
"""Generate gate_gen test vectors + expected matrices."""
import numpy as np, os
from golden_model import (OPC, u_1q, u_2q, ONEQ, TWOQ, to_q, from_q, AF, AW,
                          hex_word)
os.makedirs('vectors', exist_ok=True)

# (name, p0, p1, p2)   angles in radians
tests = [
    ('I',0,0,0),('X',0,0,0),('Y',0,0,0),('Z',0,0,0),('H',0,0,0),
    ('S',0,0,0),('SDG',0,0,0),('T',0,0,0),('TDG',0,0,0),('SX',0,0,0),('SXDG',0,0,0),
    ('RX',0.3,0,0),('RX',-1.1,0,0),('RY',0.7,0,0),('RY',2.0,0,0),
    ('RZ',0.9,0,0),('RZ',-2.5,0,0),('P',1.2,0,0),('P',-0.4,0,0),
    ('U2',0.5,0.9,0),('U3',0.6,1.1,-0.7),('U3',2.2,-1.5,0.3),
    ('SWAP',0,0,0),('ISWAP',0,0,0),('SQSWAP',0,0,0),
    ('RXX',0.8,0,0),('RYY',-1.3,0,0),('RZZ',1.7,0,0),('RZX',0.55,0,0),
]

def paramlist(name,p0,p1,p2):
    if name in ('U2',): return [p1,p2]          # (phi,lambda) -> golden expects params (phi,lambda)
    if name in ('U3',): return [p0,p1,p2]
    if name in ('RX','RY','RZ','P','RXX','RYY','RZZ','RZX'): return [p0]
    return []

with open('vectors/gate_tests.hex','w') as fh, open('vectors/gate_expected.txt','w') as fe:
    for (name,p0,p1,p2) in tests:
        op = OPC[name]
        # RTL p0/p1/p2 semantics: single-angle uses p0; U2 uses p0=phi? -> we set
        # RTL U2 schedule: ang0=p0(phi), ang1=p2(lambda). So pass phi in p0, lambda in p2.
        # U3 schedule: ang0=p0/2(theta/2),ang1=p2(lambda),ang2=p1(phi). pass theta=p0,phi=p1,lambda=p2.
        if name=='U2':
            rp0,rp1,rp2 = p0,p1,0.0     # p0=phi, p1=lambda
        elif name=='U3':
            rp0,rp1,rp2 = p0,p1,p2      # theta,phi,lambda
        else:
            rp0,rp1,rp2 = p0,0.0,0.0
        fh.write("%02x %s %s %s\n" % (op, hex_word(to_q(rp0,AF,AW),AW),
                  hex_word(to_q(rp1,AF,AW),AW), hex_word(to_q(rp2,AF,AW),AW)))
        # expected matrix (ideal, float)
        if name in ONEQ:
            if name=='U2':   U = u_1q('U2',[p0,p1])       # phi,lambda
            elif name=='U3': U = u_1q('U3',[p0,p1,p2])
            else:            U = u_1q(name, paramlist(name,p0,p1,p2))
            vals=[U[0,0],U[0,1],U[1,0],U[1,1]]
            fe.write("1q "+" ".join("%.8f %.8f"%(z.real,z.imag) for z in vals)+"\n")
        else:
            U = u_2q(name, paramlist(name,p0,p1,p2))
            flat=[U[r,c] for r in range(4) for c in range(4)]
            fe.write("2q "+" ".join("%.8f %.8f"%(z.real,z.imag) for z in flat)+"\n")
print("wrote", len(tests), "gate vectors")
