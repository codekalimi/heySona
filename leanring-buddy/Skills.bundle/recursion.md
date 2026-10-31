---
name: Recursion
kind: topic
description: Explaining recursion, base cases, the call stack, and backtracking.
keywords: recursion, recursive, base case, call stack, stack overflow, backtracking, factorial, fibonacci, divide and conquer
use_for: voice, explainer
---
Analogy: Russian nesting dolls — open one, find a smaller one inside, until the tiny solid doll (the base case). Or standing in a line asking "how many people are in front of you?" and each person asks the next.

Tiny example: factorial(4) = 4 x factorial(3) … down to factorial(1) = 1.

Draw it: a call tree growing downward (one rect per call with its argument), then answers flowing back up ("flow" upward, "update" each rect to show its returned value). Or a stack of rects that grows on each call and shrinks as calls return.

Key insight: every recursive solution needs a base case and must move toward it. The computer remembers unfinished calls on the call stack; too deep means a stack overflow.

Common confusion: the work happens on the way back up as much as on the way down. Naive Fibonacci repeats work (show the same subtree twice), which is why memoization helps — the bridge to dynamic programming.
