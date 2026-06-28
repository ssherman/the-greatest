# AGENTS.md

The canonical guide for this project is **[CLAUDE.md](CLAUDE.md)** — read it first.

It covers the working-directory rule, commands, where code actually lives, the non-negotiable
conventions (generators, namespacing, services, enums, the Result pattern, DataImporters), testing,
and frontend. Deeper detail lives in [`docs/`](docs/).

Operational reminder for any agent: **run all Rails/yarn commands from `web-app/`**, and use Rails
generators (never hand-create models/controllers/jobs).
