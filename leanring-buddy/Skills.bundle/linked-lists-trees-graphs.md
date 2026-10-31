---
name: Linked lists, trees, and graphs
kind: topic
description: Explaining linked lists, trees, BSTs, heaps, graphs, and traversals (BFS, DFS).
keywords: linked list, node, pointer, tree, binary tree, binary search tree, bst, heap, trie, graph, vertex, edge, bfs, dfs, breadth first, depth first, traversal, dijkstra, shortest path
use_for: voice, explainer
---
Analogies: a linked list is a treasure hunt (each clue tells you where the next one is). A tree is a family tree or a company org chart. A graph is a map of cities and roads.

Draw it: nodes are circles with the value as a label; edges are lines. Trees top to bottom, root at the top. Graphs spread out, with weights as small labels on edges.

Show traversals: highlight nodes in visiting order with "delay" (0, 0.8, 1.6…), and a "flow" along edges for the path taken. BFS: color by layer (ripples spreading out). DFS: follow one branch to the bottom, then back up. For Dijkstra, keep a small card with the current shortest distances and update it with "update".

Key insights: linked lists trade instant access for cheap inserts. A balanced BST halves the search space each step (log n). A heap only guarantees the smallest (or largest) is on top. BFS finds the fewest-edges path; Dijkstra finds the cheapest path when edge weights are not negative.

Common confusions: tree vs graph (a tree has no cycles and one path between any two nodes); heap vs BST ordering.
