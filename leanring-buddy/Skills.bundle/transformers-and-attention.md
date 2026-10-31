---
name: Transformers and attention
kind: topic
description: Explaining tokens, embeddings, self-attention, and how transformers and LLMs work.
keywords: transformer, transformers, attention, self-attention, query, key, value, embedding, token, tokens, llm, large language model, gpt, context window, positional encoding
use_for: voice, explainer
---
Analogy: attention is a student highlighting the words in a sentence that matter for the question they're answering. Query = what I'm looking for, key = what each word offers, value = what I take from it.

Tiny example: "The animal didn't cross the street because it was tired" — what does "it" attend to?

Draw it: words as cards in a row; lines from one word to the others with brightness showing attention weight (highlight the strongest). Then show the result: "it" now carries the meaning of "animal". Stack a few layers as rows to show depth. Show softmax(Q K^T / sqrt(d)) V in a "math" card only after the intuition.

Key insights: every word looks at every other word at once (that's why transformers parallelize well). An LLM repeatedly predicts the next token and appends it. Embeddings place similar meanings near each other.

Common confusion: the model doesn't "look things up"; its knowledge is in the weights, and the context window is its short-term memory.
