# Implement Spec

Please implement the following spec:

$ARGUMENTS

## Context & Guidelines

Review these documents for context and standards:

- @docs/spec-instructions.md - spec format details
- @docs/summary.md - project-specific details
- @docs/dev-core-values.md - development principles
- @docs/testing.md - testing requirements
- @docs/documentation.md - documentation standards

## Core Principles

- **Ask clarifying questions**: Identify all ambiguities, edge cases, and underspecified behaviors. Ask specific, concrete questions rather than making assumptions. Wait for user answers before proceeding with implementation. Ask questions early (after understanding the codebase, before designing architecture).
- **Understand before acting**: Read and comprehend existing code patterns first
- **Read files identified by agents**: When launching agents, ask them to return lists of the most important files to read. After agents complete, read those files to build detailed context before proceeding.
- **Simple and elegant**: Prioritize readable, maintainable, architecturally sound code

## Process

1. Read and understand the spec thoroughly
2. Use sub-agents for research as needed per @docs/sub-agents.md
3. Implement the feature according to the spec
4. Write tests per testing guidelines
5. Update documentation as needed

## Important

- Follow the spec precisely
- If anything in the spec is unclear or seems incorrect, ask before proceeding
- Ensure all tests pass before considering implementation complete