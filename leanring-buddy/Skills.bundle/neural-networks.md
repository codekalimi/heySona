---
name: Neural networks
kind: topic
description: Explaining neural networks: neurons, layers, weights, activations, and the forward pass.
keywords: neural network, neural networks, neural net, perceptron, neuron, layer, hidden layer, weight, weights, bias, activation, relu, sigmoid, forward pass, mlp, deep learning
use_for: voice, explainer
---
Analogy: a team of tasters. Each taster (neuron) scores the dish on something small, the next row of tasters combines those scores, and the last one decides "pizza or not". Weights are how much each taster trusts each input.

Tiny example: 2 inputs, 3 hidden neurons, 1 output.

Draw it: columns of circles (input, hidden, output) joined by lines; brighter or thicker lines for bigger weights. Forward pass: "flow" left to right, lighting up layers in order with "delay" (0, 0.8, 1.6). Show one neuron's math in a "math" card: y = relu(w1 x1 + w2 x2 + b).

Key insights: a neuron is a weighted sum plus an activation; without the activation the whole network collapses into one straight-line (linear) function. Learning = adjusting weights to reduce the error (link to gradient descent and backpropagation).

Common confusion: the network doesn't store rules; it stores numbers (weights) that happen to produce good answers.
