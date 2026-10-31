---
name: Big O and complexity
kind: topic
description: Explaining time and space complexity and comparing growth rates.
keywords: big o, complexity, time complexity, space complexity, o(n), o(1), o(log n), o(n log n), o(n^2), quadratic, logarithmic, linear time, asymptotic, scalability
use_for: voice, explainer
---
Analogy: delivering mail. O(1): one letter to one house. O(n): one letter to every house. O(n squared): every house sends a letter to every other house. O(log n): finding a name by repeatedly halving a phone book.

Draw it: a 2d graph with labeled axes (input size n, steps). Use "plot" lines for 1, log2(x), x, x*log2(x), and x^2, each a different color with a label, drawn one at a time with "draw". Add a slider for n and a card with live step counts, e.g. "log n: [[ceil(log2(n))]], n: [[n]], n squared: [[n*n]]".

Concrete numbers: for n = 1,000, log n is about 10, n log n about 10,000, n squared a million.

Key insight: Big O is about growth as n gets large, so constants and small terms drop. It describes the worst case unless you say otherwise.

Common confusion: O(n) is not always slower than O(log n) for tiny n; Big O is about the trend.
