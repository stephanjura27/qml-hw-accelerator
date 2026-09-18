#!/usr/bin/env python3
"""Generate CORDIC test vectors and expected cos/sin."""
import numpy as np, os
from golden_model import to_q, AF, AW, hex_word

os.makedirs('vectors', exist_ok=True)
angles = np.linspace(-1.5*np.pi, 1.5*np.pi, 241)
# add exact special points
specials = [0, np.pi/6, np.pi/4, np.pi/3, np.pi/2, np.pi, -np.pi/2,
            np.pi/2+np.pi/2, np.pi-np.pi/2, 2.0, -2.0, 3.0, -3.0]
angles = np.concatenate([angles, specials])

with open('vectors/cordic_angles.hex','w') as fh, \
     open('vectors/cordic_expected.txt','w') as fe:
    for a in angles:
        q = to_q(a, AF, AW)                 # Q4.12
        fh.write(hex_word(q, AW) + "\n")
        fe.write("%.10f %.10f %.10f\n" % (q/(1<<AF), np.cos(q/(1<<AF)), np.sin(q/(1<<AF))))
print("wrote", len(angles), "cordic vectors")
