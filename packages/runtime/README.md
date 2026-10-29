# @piopio/runtime

Shared Node and Cloudflare logic on top of pi-durable: local agent definitions/templates, conversations,
proactivity (schedules, reminders and outbox), approvals and budgets, agent-to-agent messages, Mac-app tool
interfaces, and built-in memory with keyword/optional semantic recall and learned facts.

Local Agents use this implementation. The Cloudflare package exercises it in a local Durable Object spike;
production cloud deployment and channels are pending. See [current status](../../docs/status.md).
