---
name: Dynamic programming
kind: topic
description: Explaining dynamic programming, memoization, and filling DP tables.
keywords: dynamic programming, dp, memoization, memoize, tabulation, subproblem, overlapping subproblems, knapsack, longest common subsequence, edit distance, coin change
use_for: voice, explainer
---
Analogy: writing answers on sticky notes so you never solve the same small problem twice. Or climbing stairs: the ways to reach step 5 = ways to reach step 4 + ways to reach step 3.

Tiny example: climbing stairs up to 5 steps, or coin change for amount 6 with coins [1, 3, 4].

Draw it: a small grid of rects (one row for 1D problems, a table for 2D). Fill cells one at a time with "update" or "add" and "delay", and draw arrows from the cells each value depends on. Highlight the final answer cell.

Key insight: DP works when a problem breaks into overlapping subproblems with an optimal substructure. Top-down = recursion plus memo; bottom-up = fill the table in order.

Common confusion: DP is not a specific algorithm; it's "remember answers to smaller versions". Always say what one cell means in words ("cell i is the number of ways to reach step i").
