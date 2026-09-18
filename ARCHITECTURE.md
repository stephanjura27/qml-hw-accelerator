# Quantum Machine Learning Hardware Accelerator

A general-purpose, synthesizable RTL architecture that performs **all core
quantum-machine-learning operations directly in hardware**: state
initialization, the full set of quantum gates (fixed and parameterized
rotations), controlled/multi-controlled gates, two-qubit entangling and Ising
gates, expectation-value measurement of arbitrary Pauli observables, and
**analytic gradients through the parameter-shift rule**.

The accelerator is a **state-vector processor**: it stores the `2^n` complex
amplitudes of an `n`-qubit register and applies each gate as a linear
transformation on that vector. This is the standard model behind variational
quantum circuits (VQC), quantum neural networks, and quantum kernel methods, so
a single engine covers essentially any QML workload. Every gate reduces to one
of two generic hardware primitives — a **1-qubit 2×2 kernel with an N-qubit
control mask** and a **2-qubit 4×4 kernel** — which is what makes the design
general rather than tied to one ansatz.

Everything here is written in portable Verilog-2001/2012, and the whole thing
is verified against an independent numpy reference model: **CORDIC, the gate
matrix generator, eleven hand-built system circuits, and forty randomized
circuits all pass** with fixed-point error below `6e-4`.

![RTL block diagram](docs/architecture.png)

All diagrams are generated with **Graphviz** (`dot`) from the `.dot` sources in
`docs/diagrams/`, so they are reproducible and editable — not hand-drawn. The
set covers the whole design at increasing detail:

| File | Diagram |
|---|---|
| `docs/diagrams/01_system`  | top-level module connectivity, signal names, bus widths |
| `docs/diagrams/02_cordic`  | CORDIC pipeline datapath (arg-reduction, 16 stages, rounding) |
| `docs/diagrams/03_qpu_core`| state-vector datapath: 1Q butterfly, 2Q 4×4 kernel, ⟨Z⟩ unit |
| `docs/diagrams/04_cmac`    | complex multiply-accumulate cell (the arithmetic core) |
| `docs/diagrams/05_fsm`     | the four control FSMs (PSR, sequencer, gate_gen, qpu_core) |

Each is provided as `.png`, `.pdf` (vector, for LaTeX/print) and `.svg`, plus a
combined `docs/qml_diagrams.pdf`. Regenerate them with:

```bash
cd docs/diagrams && for f in *.dot; do dot -Tpdf "$f" -o "${f%.dot}.pdf"; done
```

---

## 1. What it computes

For a program (a list of gate instructions) the accelerator evaluates

```
|ψ_out⟩ = U_L … U_2 U_1 |0…0⟩          (forward pass)
E       = ⟨ψ_out| O |ψ_out⟩            (observable / cost)
∂E/∂θk  = ½ ( E(θk + π/2) − E(θk − π/2) )   (parameter-shift gradient)
```

`mode = 0` returns the expectation `E`; `mode = 1` returns the exact analytic
gradient of `E` with respect to a chosen variational parameter. The gradient is
computed by the hardware itself — the parameter-shift controller re-runs the
circuit with the parameter shifted by `±π/2` and subtracts, which is the
identity `∂⟨O⟩/∂θ = ½[⟨O⟩(θ+π/2) − ⟨O⟩(θ−π/2)]` valid for every gate whose
generator has eigenvalues `±½` (all the rotation gates here).

---

## 2. Operation set (implemented in hardware)

**Fixed single-qubit:** `I, X, Y, Z, H, S, S†, T, T†, √X, √X†`

**Parameterized single-qubit:** `RX(θ), RY(θ), RZ(θ), P(λ)` (phase / U1),
`U2(φ,λ), U3(θ,φ,λ)` — the fully general single-qubit rotation.

**Two-qubit:** `SWAP, iSWAP, √SWAP` and the Ising / Mølmer–Sørensen gates
`RXX(θ), RYY(θ), RZZ(θ), RZX(θ)` used throughout VQE/QAOA ansätze.

**Controlled and multi-controlled:** any single-qubit gate becomes a controlled
gate by setting a **control mask** — the kernel only updates amplitudes for
which all masked control qubits are `1`. This yields `CX/CNOT, CY, CZ, CH,
CRX, CRY, CRZ, CP` (one control) and `CCX/Toffoli` (two controls) with no extra
hardware; `CSWAP/Fredkin` is the 2-qubit kernel with a control mask.

**QML-specific operations:** angle encoding and IQP-style feature maps are just
sequences of the rotation and entangling gates above; entangling layers are
mask-gated gates; the measurement primitive computes `⟨⊗ Z_q⟩`, and any Pauli
observable is measured by inserting the standard basis-change gates (`H` for X,
`S†·H` for Y) before the measurement, all of which are in the gate set.

The generic primitives mean a gate the ISA does not name directly can still be
run by decomposing it onto 1- and 2-qubit unitaries.

---

## 3. Microarchitecture

The design splits cleanly into a **control plane** and a **fixed-point
datapath** (see the diagram).

**Instruction ROM + Sequencer.** The circuit is stored as a list of 64-bit
instructions. The sequencer fetches, decodes (opcode, target `qA`, second qubit
`qB`, 16-bit control/observable mask, parameter index), fetches the required
angles from the Parameter RAM, drives the gate matrix generator, then commands
the QPU core, advancing until `HALT`.

**Gate Matrix Generator.** Turns an opcode into the gate's complex coefficient
matrix (2×2 or 4×4) in Q1.14. Fixed gates come from a coefficient ROM; every
rotation is built from `cos`/`sin` produced by a **pipelined CORDIC**. The
generator sequences up to four CORDIC evaluations, which is what a full
`U3(θ,φ,λ)` needs, and assembles the entries combinationally.

**CORDIC.** A 16-stage pipelined CORDIC in circular/rotation mode with a
32-bit (Q4.28) internal datapath. An argument-reduction front-end folds any
angle — including the `±π/2`-shifted values from the parameter-shift rule —
into the `[−π/2, π/2]` convergence range while tracking a sign flip. Accuracy is
better than `6e-5` versus `numpy` (below one Q1.14 LSB).

**QPU Core.** Holds the `2^n` complex amplitudes and applies operations in
place. The address generator enumerates the butterfly index pairs (1-qubit) or
index quads (2-qubit) and enforces the control mask. The **complex
multiply-accumulate (cmac)** array is the arithmetic heart: each output
amplitude is a single-rounded, saturating dot product of a matrix row with the
read amplitudes (2 complex products for a 1-qubit gate, 4 for a 2-qubit gate).
The expectation unit streams the state and accumulates `Σ (−1)^parity·|amp|²`
over the observable mask.

**Parameter-Shift Controller.** Wraps the sequencer. In gradient mode it applies
`+π/2` to the target parameter via an override adder on the Parameter RAM read
port, runs the circuit to obtain `E₊`, then `−π/2` for `E₋`, and outputs
`(E₊ − E₋)/2`.

---

## 4. Number formats and precision

| Quantity | Format | Notes |
|---|---|---|
| Amplitudes, gate coefficients | signed **Q1.14** (16-bit) | range `[−2, 2)`, unit-norm states use `[−1, 1]` |
| Rotation angles | signed **Q4.12** (16-bit) | range `±8 rad`, covers `±3π/2` shifts |
| CORDIC internal | **Q4.28** (32-bit) | keeps angle resolution below the amplitude LSB |
| Expectation / gradient | **Q4.28** (32-bit) | `1.0 = 2^28` |

Complex products are formed at full 32-bit width and accumulated in a 40-bit
register before a **single** rounding step, so a butterfly does not double-round.
Because every gate is unitary and the state stays normalized, amplitudes never
leave `[−1, 1]`, so Q1.14 never overflows in practice; the cmac still saturates
defensively. Measured end-to-end error on random depth-10 circuits is
`≤ 5.5e-4`, which is more than adequate for QML training where gradients are
themselves stochastic. All formats are `define`s in `rtl/qml_defs.vh`; widen
`QF`/`DW` there for more precision.

---

## 5. Instruction format (64-bit)

```
[63:56] opcode      [55:52] qA (target)   [51:48] qB (2nd qubit)
[47:32] ctrl/z mask [31:16] param index   [15:0] reserved
```

The mask is a control mask for gates and the Z-string mask for `MEAS_Z`. The
parameter index points into the Parameter RAM; multi-angle gates (`U2`, `U3`)
read consecutive slots. The full opcode map lives in `rtl/qml_defs.vh` and is
mirrored in `model/golden_model.py`, so the RTL and the reference model can
never silently disagree.

---

## 6. Build and run the verification

Requires `iverilog` (Icarus Verilog ≥ 11) and `python3` with `numpy`.

```bash
bash run_all.sh   # runs the entire verification suite (no make needed)

# or, with make:
make test      # CORDIC + gate generator + system + fuzz  (everything)
make cordic    # CORDIC sweep vs numpy cos/sin
make gate      # every gate's matrix vs numpy
make system    # 11 named circuits (Bell, Toffoli, SWAP, U3, gradient, …)
make fuzz      # 40 randomized circuits, differential vs golden model
```

Expected tail of `make test`:

```
CORDIC vectors=254  max_cos_err=5.36e-05  max_sin_err=5.69e-05   CORDIC: PASS
gate_gen gates=29   worst_err=1.60e-04                           gate_gen: PASS
SYSTEM TESTS: 11 passed, 0 failed
FUZZ: 40/40 passed  worst_state_err=3.09e-04  worst_exp_err=5.50e-04
 ALL VERIFICATION PASSED
```

Verification is **differential**: `model/golden_model.py` is an independent
numpy state-vector simulator implementing the identical operation set, opcode
map, and instruction layout. The testbenches feed the same programs to the RTL
and to the model and compare final state vectors, expectation values, and
parameter-shift gradients within a fixed-point tolerance.

---

## 7. End-to-end QML case study (trained on the hardware)

Correct primitives are necessary but not sufficient — the real question is
whether the accelerator can *train* a model. It can. `model/train_vqc.py`
trains a **variational quantum classifier** on the real **Iris** dataset
(setosa vs versicolor, petal length/width → 2 qubits), where **every forward
value `E=⟨Z₀⟩` and every gradient `∂E/∂θ` is produced by the Verilog RTL** — the
CORDIC rotations, the state-vector kernels and the parameter-shift controller —
never by the numpy model. Optimisation is plain gradient descent on MSE loss.

Circuit: `RY(x₁)q0 · RY(x₂)q1` (angle encoding) then two variational layers
`RY(θ)·RY(θ)·CX` and measurement of `⟨Z₀⟩`.

Result (≈80 s of simulation, ~7000 RTL circuit evaluations):

```
epoch  0  loss=1.076  acc_train=0.36  acc_test=0.40
epoch  2  loss=0.030  acc_train=1.00  acc_test=1.00
epoch 13  loss=0.017  acc_train=1.00  acc_test=1.00
gradient check @ trained θ:  RTL vs golden  max|Δ| = 5.9e-4
FINAL  train acc = 100%   test acc = 100%
```

The loss curve and the learned `⟨Z₀⟩=0` decision boundary are in
`docs/vqc_training.png`. The gradient cross-check confirms the training signal
really is the hardware's parameter-shift output, not a numpy stand-in. This
exercises the whole datapath — encoding, entangling gates, expectation and
analytic gradients — on a genuine learning task.

Run it (after `iverilog` build):

```bash
bash train.sh   # builds tb_batch.vvp, runs model/train_vqc.py (~80 s)
# or:  make train
```

`tb/tb_batch.v` is a batch testbench that runs hundreds of circuits per
simulation (reloading the parameter RAM per job), which is what makes an
RTL-in-the-loop training run practical.

---

## 8. File layout

```
rtl/   qml_defs.vh      parameters, opcode map, instruction fields
       complex_ops.vh   fixed-point helpers (rounded/saturating multiply)
       cordic.v         pipelined CORDIC (cos/sin for rotations)
       cmac.v           complex multiply-accumulate cell (datapath core)
       gate_gen.v       opcode -> 2x2 / 4x4 coefficient matrix
       qpu_core.v       state-vector memory + 1Q/2Q kernels + expectation
       qml_accelerator.v top: ROM, param RAM, sequencer, parameter-shift ctrl
tb/    tb_cordic.v  tb_gate_gen.v  tb_system.v  tb_batch.v (fast training runner)
model/ golden_model.py  gen_*_vectors.py  check_*.py  system_tests.py  fuzz_tests.py
       vqc.py  train_vqc.py   (variational quantum classifier trained on RTL)
docs/  architecture.svg/png   qml_diagrams.pdf   vqc_training.png (learning curves)
       diagrams/  01_system 02_cordic 03_qpu_core 04_cmac 05_fsm  (.dot/.png/.pdf/.svg)
Makefile   run_all.sh
```

---

## 9. Extending and synthesis notes

`NUM_QUBITS` (state size) and the ROM/RAM depths are RTL parameters; the datapath
widths are `define`s. To add a gate: give it an opcode in `qml_defs.vh`, add its
matrix in `gate_gen.v` (and its CORDIC schedule if it is parameterized), and add
the same matrix to `golden_model.py` — the fuzz tester will then exercise it
automatically.

The kernels process one amplitude (1-qubit) or one amplitude-quad (2-qubit) per
clock; the natural FPGA/ASIC scaling is to **bank the state memory by the target
qubit bit** so a butterfly reads its pair/quad from separate dual-port banks,
and to instantiate several `cmac` lanes in parallel. The CORDIC is already
pipelined and shared across all rotations, so gate-matrix generation overlaps
amplitude processing of the previous gate. The current model memory uses
asynchronous read for clarity in simulation; for synthesis, register the read
port to map onto block-RAM.

**Scope.** This is a *simulation-style* (state-vector) accelerator — it emulates
quantum evolution deterministically in classical hardware, which is exactly what
QML training and inference need on today's hardware. It is not a controller for
physical qubits.
