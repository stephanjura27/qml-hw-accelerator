#!/usr/bin/env python3
"""
Compare the hardware-trained Variational Quantum Classifier against classical
baselines (logistic regression, small neural net) on the SAME Iris split.
Reuses model/vqc_result.npz produced by train_vqc.py (no re-simulation).
Produces docs/quantum_vs_classical.png and prints a comparison table.
"""
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from sklearn.linear_model import LogisticRegression
from sklearn.neural_network import MLPClassifier

d = np.load('vqc_result.npz')
Xtr, ytr, Xte, yte = d['Xtr'], d['ytr'], d['Xte'], d['yte']
gx, gy, Eg = d['gx'], d['gy'], d['Eg']
GX, GY = np.meshgrid(gx, gy)
grid = np.column_stack([GX.ravel(), GY.ravel()])
ytr01 = (ytr > 0).astype(int); yte01 = (yte > 0).astype(int)

def acc(pred01, y01): return float(np.mean(pred01 == y01))

# ---- quantum (from RTL run) ----------------------------------------------
vqc_test = float(d['final_acc_te']); vqc_train = float(d['final_acc_tr'])
vqc_params = 4

# ---- logistic regression (linear) ----------------------------------------
lr = LogisticRegression().fit(Xtr, ytr01)
lr_train = acc(lr.predict(Xtr), ytr01); lr_test = acc(lr.predict(Xte), yte01)
lr_params = Xtr.shape[1] + 1
Zlr = lr.decision_function(grid).reshape(GX.shape)

# ---- small neural net (nonlinear) ----------------------------------------
mlp = MLPClassifier(hidden_layer_sizes=(6,), activation='tanh', max_iter=3000,
                    random_state=0).fit(Xtr, ytr01)
mlp_train = acc(mlp.predict(Xtr), ytr01); mlp_test = acc(mlp.predict(Xte), yte01)
mlp_params = 2*6 + 6 + 6*1 + 1
Zmlp = mlp.predict_proba(grid)[:,1].reshape(GX.shape) - 0.5

# ---- table ----------------------------------------------------------------
rows = [
    ("Variational Quantum Classifier (this hardware)", vqc_params, vqc_train, vqc_test,
     "parameter-shift gradients on RTL"),
    ("Logistic Regression (linear)", lr_params, lr_train, lr_test, "closed-form / sklearn"),
    ("Neural Net  MLP 2-6-1 (nonlinear)", mlp_params, mlp_train, mlp_test, "backprop / sklearn"),
]
print("\n%-46s %8s %10s %9s  %s" % ("model","#params","train acc","test acc","training"))
print("-"*100)
for name,p,tr,te,how in rows:
    print("%-46s %8d %9.0f%% %8.0f%%  %s" % (name,p,tr*100,te*100,how))
print()

# save a markdown table for the README
with open('../docs/comparison_table.md','w') as f:
    f.write("| Model | Trainable params | Train acc | Test acc | How it is trained |\n")
    f.write("|---|---|---|---|---|\n")
    for name,p,tr,te,how in rows:
        f.write("| %s | %d | %.0f%% | %.0f%% | %s |\n" % (name,p,tr*100,te*100,how))

# ---- figure: three decision boundaries side by side -----------------------
C0, C1 = "#d1495b", "#2e86ab"
panels = [
    ("Variational Quantum Classifier\n(trained on the Verilog accelerator)", Eg, vqc_params, vqc_test),
    ("Logistic Regression\n(classical, linear)", Zlr, lr_params, lr_test),
    ("Neural Net  MLP 2-6-1\n(classical, nonlinear)", Zmlp, mlp_params, mlp_test),
]
fig, axes = plt.subplots(1, 3, figsize=(15, 5.0))
for ax,(title,Z,p,te) in zip(axes, panels):
    v = np.max(np.abs(Z))
    ax.contourf(GX,GY,Z, levels=np.linspace(-v,v,21), cmap='RdBu', alpha=0.7)
    ax.contour(GX,GY,Z, levels=[0.0], colors='k', linewidths=2)
    ax.scatter(Xtr[ytr<0,0],Xtr[ytr<0,1], c=C0, edgecolor='k', s=40)
    ax.scatter(Xtr[ytr>0,0],Xtr[ytr>0,1], c=C1, edgecolor='k', s=40)
    ax.scatter(Xte[:,0],Xte[:,1], facecolors='none', edgecolor='k', s=65, linewidths=1.2)
    ax.set_title(f"{title}\n{p} params · test {te:.0%}", fontsize=11)
    ax.set_xlabel('petal length (std)'); ax.set_ylabel('petal width (std)')
fig.suptitle('Quantum vs classical on the same Iris task (setosa vs versicolor)',
             fontsize=14, fontweight='bold')
# shared legend
from matplotlib.lines import Line2D
leg = [Line2D([0],[0],marker='o',color='w',markerfacecolor=C0,markeredgecolor='k',markersize=9,label='setosa'),
       Line2D([0],[0],marker='o',color='w',markerfacecolor=C1,markeredgecolor='k',markersize=9,label='versicolor'),
       Line2D([0],[0],marker='o',color='w',markerfacecolor='none',markeredgecolor='k',markersize=9,label='test point')]
fig.legend(handles=leg, loc='lower center', ncol=3, fontsize=10, bbox_to_anchor=(0.5,-0.02))
fig.tight_layout(rect=[0,0.04,1,0.95])
fig.savefig('../docs/quantum_vs_classical.png', dpi=140, bbox_inches='tight')
print("saved docs/quantum_vs_classical.png and docs/comparison_table.md")
