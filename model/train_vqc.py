#!/usr/bin/env python3
"""
Train the variational quantum classifier on the REAL Iris dataset, using the
Verilog accelerator for every forward value and every parameter-shift gradient.
Produces docs/vqc_training.png (loss/accuracy curves + decision boundary).
"""
import numpy as np, time
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from sklearn.datasets import load_iris
import vqc

rng = np.random.default_rng(7)

# ---- real dataset: Iris, setosa (−1) vs versicolor (+1), petal length/width -
iris = load_iris()
mask = iris.target < 2                      # classes 0 and 1 (linearly separable)
X = iris.data[mask][:, [2,3]]               # petal length, petal width
y = np.where(iris.target[mask]==0, -1.0, +1.0)
# standardize then scale into a sensible rotation-angle range
X = (X - X.mean(0)) / X.std(0)
X = X * 1.1
# train / test split
idx = rng.permutation(len(X))
Xtr, ytr = X[idx[:25]], y[idx[:25]]
Xte, yte = X[idx[25:50]], y[idx[25:50]]
print(f"Iris 2-class: {len(Xtr)} train / {len(Xte)} test samples, 2 features -> 2 qubits")

vqc.write_prog()

# ---- helpers that call the RTL accelerator -------------------------------
def rtl_eval(Xs, theta, want_grad):
    """Return E[i] for all samples; if want_grad also g[i,p]=dE/dtheta_p."""
    slices, jobs, tags = [], [], []
    for xi in Xs:
        s = vqc.param_slice(xi[0], xi[1], theta)
        slices.append(s); jobs.append((0,0)); tags.append(('E',))
        if want_grad:
            for addr in vqc.THETA_ADDR:
                slices.append(s); jobs.append((1,addr)); tags.append(('G',))
    res = vqc.run_batch(slices, jobs)
    E=[]; G=[]; k=0
    for _ in Xs:
        E.append(res[k]); k+=1
        if want_grad:
            G.append(res[k:k+len(vqc.THETA_ADDR)]); k+=len(vqc.THETA_ADDR)
    return (np.array(E), np.array(G)) if want_grad else np.array(E)

def rtl_epoch(theta):
    """One vvp call: train forward+grads AND test forward together."""
    slices, jobs = [], []
    for xi in Xtr:
        s = vqc.param_slice(xi[0], xi[1], theta)
        slices.append(s); jobs.append((0,0))
        for addr in vqc.THETA_ADDR:
            slices.append(s); jobs.append((1,addr))
    for xi in Xte:
        s = vqc.param_slice(xi[0], xi[1], theta)
        slices.append(s); jobs.append((0,0))
    res = vqc.run_batch(slices, jobs)
    P = len(vqc.THETA_ADDR); k=0
    Etr=[]; G=[]
    for _ in Xtr:
        Etr.append(res[k]); G.append(res[k+1:k+1+P]); k+=1+P
    Ete = np.array(res[k:k+len(Xte)])
    return np.array(Etr), np.array(G), Ete

# ---- training loop (gradient descent on MSE, hardware gradients) ---------
theta = rng.uniform(-0.3, 0.3, 4)
LR, EPOCHS = 0.6, 14
hist = {'loss':[], 'acc_tr':[], 'acc_te':[]}
t0=time.time()
for ep in range(EPOCHS):
    E, G, Ete = rtl_epoch(theta)                 # forward + parameter-shift grads (RTL)
    err = E - ytr
    loss = np.mean(err**2)
    grad = 2.0 * (err[:,None] * G).mean(0)       # dL/dtheta
    acc_tr = np.mean(np.sign(E)==ytr)
    acc_te = np.mean(np.sign(Ete)==yte)
    hist['loss'].append(loss); hist['acc_tr'].append(acc_tr); hist['acc_te'].append(acc_te)
    theta = theta - LR*grad
    if ep%2==0 or ep==EPOCHS-1:
        print(f"epoch {ep:2d}  loss={loss:.4f}  acc_train={acc_tr:.3f}  acc_test={acc_te:.3f}")

def accuracy(Xs, ys, theta):
    E = rtl_eval(Xs, theta, False)
    return np.mean(np.sign(E) == ys)
print(f"trained in {time.time()-t0:.1f}s   final theta = {np.round(theta,3)}")

# cross-check: hardware vs golden gradient at the trained point (1st sample)
gh = rtl_eval(Xtr[:1], theta, True)[1][0]
gg = np.array([vqc.golden_grad(Xtr[0,0],Xtr[0,1],theta,p) for p in range(4)])
print("gradient check @ trained θ:  RTL =",np.round(gh,4)," golden =",np.round(gg,4),
      " max|Δ|=%.1e"%np.max(np.abs(gh-gg)))

acc_tr = accuracy(Xtr,ytr,theta); acc_te = accuracy(Xte,yte,theta)
print(f"FINAL  train acc = {acc_tr:.1%}   test acc = {acc_te:.1%}")

# ---- figure ---------------------------------------------------------------
C0, C1 = "#d1495b", "#2e86ab"      # class colors (colorblind-safe)
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13,5.2))

ax1.plot(hist['loss'], color="#8a5a1f", lw=2, marker='o', ms=3, label='MSE loss')
ax1b = ax1.twinx()
ax1b.plot(np.array(hist['acc_tr'])*100, color=C1, lw=2, marker='s', ms=3, label='train acc')
ax1b.plot(np.array(hist['acc_te'])*100, color=C0, lw=2, marker='^', ms=3, ls='--', label='test acc')
ax1.set_xlabel('epoch'); ax1.set_ylabel('MSE loss', color="#8a5a1f")
ax1b.set_ylabel('accuracy (%)'); ax1b.set_ylim(40,103)
ax1.set_title('Training on the Verilog accelerator\n(forward + parameter-shift gradients from RTL)', fontsize=11)
l1,lab1=ax1.get_legend_handles_labels(); l2,lab2=ax1b.get_legend_handles_labels()
ax1.legend(l1+l2, lab1+lab2, loc='center right', fontsize=9)
ax1.grid(alpha=0.25)

# decision boundary evaluated on the RTL accelerator
gx = np.linspace(X[:,0].min()-0.6, X[:,0].max()+0.6, 32)
gy = np.linspace(X[:,1].min()-0.6, X[:,1].max()+0.6, 32)
GX,GY = np.meshgrid(gx,gy)
grid = np.column_stack([GX.ravel(), GY.ravel()])
Eg = rtl_eval(grid, theta, False).reshape(GX.shape)
ax2.contourf(GX,GY,Eg, levels=np.linspace(-1,1,21), cmap='RdBu', alpha=0.7)
cs = ax2.contour(GX,GY,Eg, levels=[0.0], colors='k', linewidths=2)
ax2.scatter(Xtr[ytr<0,0],Xtr[ytr<0,1], c=C0, edgecolor='k', s=45, label='setosa (train)')
ax2.scatter(Xtr[ytr>0,0],Xtr[ytr>0,1], c=C1, edgecolor='k', s=45, label='versicolor (train)')
ax2.scatter(Xte[:,0],Xte[:,1], facecolors='none', edgecolor='k', s=70, linewidths=1.3, label='test')
ax2.set_xlabel('petal length (standardized)'); ax2.set_ylabel('petal width (standardized)')
ax2.set_title(f'Learned decision boundary  ⟨Z₀⟩=0\ntrain {acc_tr:.0%} · test {acc_te:.0%} accuracy', fontsize=11)
ax2.legend(loc='lower right', fontsize=8.5)
fig.suptitle('Variational Quantum Classifier — trained end-to-end on the QML hardware accelerator',
             fontsize=13, fontweight='bold')
fig.tight_layout(rect=[0,0,1,0.96])
fig.savefig('../docs/vqc_training.png', dpi=140)
print("saved docs/vqc_training.png")

# save results so the classical comparison can reuse them without re-simulating
np.savez('vqc_result.npz',
         theta=theta, Xtr=Xtr, ytr=ytr, Xte=Xte, yte=yte,
         gx=gx, gy=gy, Eg=Eg, loss=hist['loss'],
         acc_tr=hist['acc_tr'], acc_te=hist['acc_te'],
         final_acc_tr=acc_tr, final_acc_te=acc_te)
print("saved model/vqc_result.npz")
