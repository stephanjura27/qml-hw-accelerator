| Model | Trainable params | Train acc | Test acc | How it is trained |
|---|---|---|---|---|
| Variational Quantum Classifier (this hardware) | 4 | 100% | 100% | parameter-shift gradients on RTL |
| Logistic Regression (linear) | 3 | 100% | 100% | closed-form / sklearn |
| Neural Net  MLP 2-6-1 (nonlinear) | 25 | 100% | 100% | backprop / sklearn |
