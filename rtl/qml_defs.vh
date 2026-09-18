// ============================================================================
//  qml_defs.vh  -  Global parameters and opcode map for the QML accelerator
//  Shared by all RTL modules and mirrored by model/golden_model.py
// ============================================================================
`ifndef QML_DEFS_VH
`define QML_DEFS_VH

// ---- Fixed-point formats ---------------------------------------------------
`define DW   16          // amplitude / coefficient width (signed)   Q1.14
`define QF   14          // fractional bits for amplitudes/coefficients
`define AW   16          // angle width (signed)                     Q4.12
`define AF   12          // fractional bits for angles (range +/-8 rad)

`define ONE_Q14   16'sd16384      // 1.0
`define INVSQRT2  16'sd11585      // 0.70710678
`define COS45     16'sd11585      // cos(pi/4)=sin(pi/4)=1/sqrt2
`define HALF_Q14  16'sd8192       // 0.5

// ---- System sizing ---------------------------------------------------------
// NUM_QUBITS and depths are overridable parameters on the top module; these
// are the defaults used by the sequencer/memories when not overridden.
`define MAX_QUBITS      5          // state vector up to 2^5 = 32 amplitudes
`define STATE_AW        5          // address bits for state memory (=MAX_QUBITS)

// ---- Angle constants (Q4.12) ----------------------------------------------
`define PI_Q412      16'sd12868    // 3.14159265
`define HALFPI_Q412  16'sd6434     // 1.57079633

// ---- Instruction word layout (64 bits) ------------------------------------
//  [63:56] opcode      (8)
//  [55:52] qA / target (4)
//  [51:48] qB          (4)
//  [47:32] ctrl_mask / zmask (16)
//  [31:16] param_idx   (16)  base index into angle RAM (U2/U3 use +1,+2)
//  [15:0 ] reserved
`define INSTR_W   64
`define OPC_HI    63
`define OPC_LO    56
`define QA_HI     55
`define QA_LO     52
`define QB_HI     51
`define QB_LO     48
`define MASK_HI   47
`define MASK_LO   32
`define PIDX_HI   31
`define PIDX_LO   16

// ---- Opcodes ---------------------------------------------------------------
`define OP_NOP    8'h00
`define OP_I      8'h01
`define OP_X      8'h02
`define OP_Y      8'h03
`define OP_Z      8'h04
`define OP_H      8'h05
`define OP_S      8'h06
`define OP_SDG    8'h07
`define OP_T      8'h08
`define OP_TDG    8'h09
`define OP_SX     8'h0A
`define OP_SXDG   8'h0B
// parameterized single-qubit
`define OP_RX     8'h10
`define OP_RY     8'h11
`define OP_RZ     8'h12
`define OP_P      8'h13
`define OP_U2     8'h14
`define OP_U3     8'h15
// two-qubit (4x4)
`define OP_SWAP   8'h20
`define OP_ISWAP  8'h21
`define OP_SQSWAP 8'h22
`define OP_RXX    8'h23
`define OP_RYY    8'h24
`define OP_RZZ    8'h25
`define OP_RZX    8'h26
// measurement / control
`define OP_MEASZ  8'h30
`define OP_RESET  8'hF0
`define OP_HALT   8'hFF

`endif
