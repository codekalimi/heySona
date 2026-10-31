---
name: Gradient descent and training
kind: topic
description: Explaining loss, gradient descent, learning rate, backpropagation, and overfitting.
keywords: gradient descent, gradient, loss, loss function, learning rate, backpropagation, backprop, training, epoch, overfitting, optimizer, adam, sgd, stochastic gradient descent, convergence
use_for: voice, explainer
---
Analogy: walking down a foggy hill by feeling the slope under your feet and stepping downhill. The learning rate is your step size: tiny steps take forever, huge steps jump across the valley.

Tiny example: loss L(w) = w^2, start at w = 2.8, learning rate 0.1.

Draw it: a plotted bowl "x^2" and an "iterate" plot of the steps ("next": "x - lr * 2 * x", markers on), drawn with "draw". Add a learning-rate slider (0.01 to 1.05) so the user sees crawl, settle, zigzag, and diverge. Show the update rule in a "math" card and a live card with the loss after 10 steps. For backpropagation, "flow" right to left through a small network.

Key insights: the gradient points uphill, so we step the opposite way. Backpropagation is the chain rule, used to find each weight's share of the blame. Overfitting is memorizing the practice questions instead of learning the subject.

Common confusion: lower training loss isn't always better; check loss on data the model hasn't seen.
