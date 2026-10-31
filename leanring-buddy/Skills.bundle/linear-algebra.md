---
name: Linear algebra
kind: topic
description: Explaining vectors, matrices, dot products, transformations, and eigenvectors.
keywords: vector, vectors, matrix, matrices, dot product, matrix multiplication, linear transformation, eigenvector, eigenvalue, basis, determinant, linear algebra
use_for: voice, explainer
---
Analogies: a vector is an arrow (a direction and a length), like "3 steps east, 2 north". A matrix is a machine that moves every arrow in the plane the same way (stretch, rotate, shear). A dot product measures how much two arrows point the same way.

Draw it: 2d axes with a light grid (lines); vectors as "arrow" actions from the origin, with labels like [3, 2]. Show a matrix as what it does to the grid and to two basis arrows (move their tips with "move"). Show equations in a "math" card, e.g. A v = lambda v.

Key insights: matrix times vector = a weighted mix of the matrix's columns. Eigenvectors are arrows that only get stretched, not turned. In ML, a layer of a neural network is a matrix multiplication (then an activation).

Common confusion: matrix multiplication order matters (AB is not BA).
