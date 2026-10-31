---
name: Sorting and searching
kind: topic
description: Explaining binary search and sorting algorithms (bubble, insertion, merge, quick).
keywords: sort, sorting, bubble sort, insertion sort, merge sort, quicksort, quick sort, pivot, binary search, search, sorted
use_for: voice, explainer
---
Analogies: binary search is the "guess my number, higher or lower" game, or opening a dictionary in the middle. Merge sort is two sorted piles of cards merged by always taking the smaller top card. Quicksort is picking a pivot and splitting people into "shorter than" and "taller than" groups.

Tiny example: sort [5, 2, 8, 1, 9] or search for 23 in [4, 8, 15, 16, 23, 42].

Draw it: a row of rects (heights or labeled values). Compare two items with "highlight"; swap them with "move" (to: each other's positions), using "delay" so compare, then swap, then the next pair play in order. For binary search, fade out the half you throw away (opacity) and move a low, mid, high marker.

Key insight: binary search needs sorted data and takes about log2(n) steps (a million items, about 20 steps). Merge sort is always n log n; quicksort is usually n log n but n squared with bad pivots.

Common confusion: "fast" means how the step count grows as n grows, not seconds.
