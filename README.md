# QML Hardware Accelerator

A small **Verilog** design that runs the math of **quantum machine learning
(QML)** directly in hardware — the quantum gates, the rotations, the
measurements, and the gradients used to train quantum models. It is verified
against an independent simulator and used to train a real classifier
end‑to‑end, entirely on the accelerator.

> **In one line:** a *"quantum-math co-processor."* You hand it a quantum circuit
> as a list of instructions; it computes the result **and** the training
> gradients in hardware.

![architecture](docs/architecture.png)

---

## The idea in 60 seconds

A quantum computer with **n qubits** is described by a list of **2ⁿ complex
numbers** (the "amplitudes"). Everything quantum is just linear algebra on that
list, and each piece maps to a hardware block:

| Quantum thing | What it really is | How the hardware does it |
|---|---|---|
| **A gate** (X, H, CNOT, …) | multiply the list by a small matrix | complex multiply‑accumulate (`cmac`) |
| **A rotation** RX/RY/RZ(θ) | needs cos(θ/2), sin(θ/2) | **CORDIC** (shift‑and‑add, no lookup tables) |
| **A measurement** ⟨Z⟩ | a weighted sum of \|amplitude\|² | the expectation unit |
| **A gradient** ∂⟨O⟩/∂θ | run twice at θ±π/2, subtract, ÷2 | the **parameter‑shift** controller |

That last row is the important one for machine learning: the **parameter‑shift
rule** gives *exact* gradients for training, and the chip computes them itself —
no backprop, no external simulator.

---

## What operations it supports

**Single‑qubit gates:** `I, X, Y, Z, H, S, S†, T, T†, √X, √X†`
**Rotations (trainable):** `RX, RY, RZ, P(λ), U2, U3` — the full parameterized set
**Two‑qubit gates:** `CNOT, CZ, CY, CH, SWAP, iSWAP, √SWAP`, Ising `RXX, RYY, RZZ, RZX`
**Multi‑controlled:** `Toffoli (CCX)`, `Fredkin (CSWAP)` — via a control mask
**QML operations:** data encoding (angle/feature maps), entangling layers,
expectation value ⟨O⟩ for any Pauli observable, and **parameter‑shift gradients**.

Everything reduces to two generic hardware primitives — a **1‑qubit (2×2) kernel
with a control mask** and a **2‑qubit (4×4) kernel** — which is what makes it
general: it runs *any* variational quantum circuit, not one fixed model.

---

## How it works — the flow

Follow the picture above, left to right:

1. **Load** the circuit as a *program* (a list of 64‑bit instructions) and the
   *angles* into two on‑chip memories.
2. The **sequencer** reads one instruction at a time and decodes it (which gate,
   which qubits, which parameter).
3. For a gate, the **gate generator** builds its matrix — using the **CORDIC**
   to get the sine/cosine for rotations.
4. The **QPU core** applies that matrix to the amplitude list (the "butterfly"
   update), or, for a measurement, sums up \|amplitude\|² to produce ⟨Z⟩.
5. To **train**, the **parameter‑shift controller** runs the circuit twice
   (angle +π/2 and −π/2) and outputs the gradient `(E₊ − E₋)/2`.

Numbers are fixed‑point (amplitudes `Q1.14`, angles `Q4.12`). Deeper detail —
module ports, FSMs, precision analysis — is in **[ARCHITECTURE.md](ARCHITECTURE.md)**
and the diagrams in `docs/diagrams/`.

---

## Does it actually work?

**Verified.** An independent numpy simulator checks every part: the CORDIC (254
angles), every gate's matrix (29), 11 hand‑built circuits (Bell, Toffoli, SWAP,
U3, gradients…), and 40 random circuits. All match to **< 6×10⁻⁴**.

**It trains a real model.** A variational quantum classifier trained on the real
**Iris** dataset — with *every forward value and every gradient produced by the
Verilog RTL* — reaches **100% train / 100% test** accuracy. The gradients the
hardware produced match the reference to `5.9×10⁻⁴`.

![training](docs/vqc_training.png)

**It matches classical ML.** On the same task, against a linear model and a small
neural net — the hardware‑trained quantum classifier ties them, with the fewest
trainable parameters:

| Model | Trainable params | Test acc | How it is trained |
|---|---|---|---|
| **Variational Quantum Classifier (this hardware)** | **4** | **100%** | parameter‑shift gradients on RTL |
| Logistic Regression (linear) | 3 | 100% | sklearn |
| Neural Net MLP 2‑6‑1 (nonlinear) | 25 | 100% | backprop (sklearn) |

![quantum vs classical](docs/quantum_vs_classical.png)

*(Iris setosa vs versicolor is linearly separable, so all three reach 100%. The
point here is that the accelerator trains a correct model end‑to‑end; the three
boundaries differ in shape because the quantum model works in a different feature
space.)*

---

## Run it

Needs `iverilog` (Icarus Verilog ≥ 11) and `python3` + `numpy`
(plus `matplotlib` + `scikit‑learn` for the training/comparison demos).

```bash
git clone <your-repo-url> && cd qml-hw-accelerator

bash run_all.sh                       # 1) verify everything (CORDIC, gates, circuits, fuzz)
bash train.sh                         # 2) train the quantum classifier on the accelerator (~80 s)
cd model && python3 compare_classical.py   # 3) quantum vs classical comparison
```

Or with `make`: `make test`, `make train`.

---

## Repo layout

```
rtl/    the hardware (Verilog)
        qml_defs.vh · cordic.v · cmac.v · gate_gen.v · qpu_core.v · qml_accelerator.v
tb/     testbenches (cordic, gate generator, system, batch training runner)
model/  numpy reference + tests + the quantum classifier & classical comparison
docs/   diagrams (Graphviz) + result figures
ARCHITECTURE.md   the detailed technical write-up
run_all.sh · train.sh · Makefile
```

---

## Deep dive

**[ARCHITECTURE.md](ARCHITECTURE.md)** has the full story: microarchitecture,
instruction format, fixed‑point precision analysis, the finite‑state machines,
and synthesis notes. The `docs/diagrams/` folder has five Graphviz diagrams
(system, CORDIC, QPU core, MAC cell, FSMs) as PNG/PDF/SVG.

*Scope: this is a state‑vector accelerator — it runs quantum‑ML math
deterministically in classical hardware (what QML training needs today). It is
not a controller for physical qubits.*
