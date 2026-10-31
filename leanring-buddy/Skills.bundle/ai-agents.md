---
name: AI agents
kind: topic
description: Explaining AI agents: the loop, tools, memory, and planning.
keywords: ai agent, ai agents, agent, agents, agentic, tool use, tools, function calling, react, planning, memory, multi-agent, mcp, autonomous
use_for: voice, explainer
---
Analogy: an intern with a to-do list. They read the task, decide what to do next, use a tool (search, calculator, email), look at the result, and repeat until done or stuck — and they ask when unsure.

Tiny example: "book a table for two tomorrow" → search restaurants → check availability → book → confirm.

Draw it: a loop of cards (goal → think → choose a tool → act → observe) with a "flow" going around it; tool cards off to the side with arrows to "act"; a memory card that grows with "update". Step through one loop iteration at a time with "delay".

Key insights: the model doesn't run tools itself; it asks for a tool call and the program runs it and returns the result. Agents are powerful but can loop or drift, so good ones have limits, checks, and a human in the loop.

Common confusion: an agent is not a different kind of model — it's a normal model in a loop with tools. (heySona itself is a small agent: it can open apps, set reminders, and search your past chats.)
