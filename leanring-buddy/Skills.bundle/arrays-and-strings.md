---
name: Arrays and strings
kind: topic
description: Explaining arrays, strings, indexing, and two-pointer or sliding-window tricks.
keywords: array, arrays, list, index, string, substring, two pointers, sliding window, subarray, contiguous
use_for: voice, explainer
---
Analogy: a row of numbered lockers. Index = locker number; jumping to locker 7 is instant (no walking past 0 to 6). Breaks down when you insert in the middle: everyone behind has to shift one locker.

Tiny example: [4, 8, 15, 16, 23] — show index 0 to 4 under each box.

Draw it: a row of rects (size about 1.2 x 1.2) with the value as a label inside and the index as a small label below. Pointers are small colored circles or arrows above the row; "move" them to show i and j walking. Sliding window: a translucent rect behind the boxes that moves and stretches.

Key insight to land: random access is O(1) because the address is start + index x size. Insert or delete in the middle is O(n) because of shifting.

Common confusions: off-by-one (the last index is length - 1); strings are arrays of characters (immutable in many languages, so "changing" one makes a copy).

Connects to: hash maps (an array plus a hash function), dynamic arrays (doubling when full), sorting and binary search.
