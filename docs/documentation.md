# The Greatest - Documentation Guide

## Documentation Philosophy

**Code is the source of truth.** We document features and architecture at a high level, not individual classes.

### Why Not Class-Level Documentation?

- **Maintenance burden**: Class-specific docs quickly become stale and misleading
- **AI agents read code well**: Modern LLMs understand Ruby classes, associations, validations, and method signatures directly from source code
- **Duplication**: Class docs duplicate what's already clear from well-written code with good naming

### What We Document

| Type | Location | Purpose |
|------|----------|---------|
| **Feature docs** | `docs/features/` | High-level architecture, flows, patterns, usage examples |
| **Object models** | `docs/object_models/` | Data model diagrams and relationships |
| **Specs** | `docs/specs/` | Feature specifications (planned and completed) |
| **Guides** | `docs/*.md` | Setup, testing, conventions, principles |

## Documentation Structure

```
docs/
├── features/           # High-level feature documentation
│   ├── authentication.md
│   ├── data_importers.md
│   ├── igdb-api-wrapper.md
│   ├── rankings.md
│   └── ...
├── object_models/      # Data model diagrams
│   └── music/
├── specs/              # Feature specifications
│   ├── completed/      # Implemented specs
│   └── *.md            # In-progress specs
├── dev_setup.md        # Development environment setup
├── dev-core-values.md  # Coding principles and style
├── testing.md          # Testing conventions
├── spec-instructions.md # How to write specs
├── view-components.md  # ViewComponent patterns
└── summary.md          # Project overview
```

## Feature Documentation

Feature docs in `docs/features/` explain **how things work together** - the "why" and "how" that isn't obvious from reading individual files.

### When to Create Feature Documentation

- New features spanning multiple classes
- Complex integrations (APIs, external services)
- Architectural patterns used across the codebase
- Workflows involving multiple components

### Feature Doc Template

```markdown
# Feature Name

## Overview
One paragraph explaining what the feature does and why it exists.

## Architecture
- Component diagram or layer diagram
- How pieces fit together
- Key design decisions

## Key Files
Table of important files with their purposes.

## Usage Examples
Code examples showing how to use the feature.

## Key Patterns
Important patterns, conventions, or gotchas.

## Related Documentation
Links to related features, specs, or external docs.
```

### Good Feature Doc Examples

- `features/authentication.md` - Auth flow diagrams, provider patterns, key files table
- `features/data_importers.md` - Strategy pattern, provider architecture, extension points
- `features/igdb-api-wrapper.md` - API wrapper architecture, rate limiting, query builder

## Specifications

Specs in `docs/specs/` define features **before** implementation. See `spec-instructions.md` for the full spec template.

### Spec Lifecycle

1. Create spec in `docs/specs/` with status "Proposed"
2. Update status to "In Progress" when work begins
3. Move to `docs/specs/completed/` when done
4. Update spec with implementation notes and deviations

## What NOT to Document

- **Individual classes** - The code documents itself
- **Method signatures** - Read the source
- **Validations and associations** - Visible in model files
- **Implementation details** - These change frequently
- **Obvious Rails conventions** - Standard Rails patterns don't need explanation

## For AI Agents

When working with this codebase:

1. **Read the code directly** - Don't look for class-specific docs; they don't exist
2. **Check `docs/features/`** - For understanding how features work together
3. **Check `docs/specs/`** - For feature requirements and design decisions
4. **Use codebase exploration** - Glob, Grep, and Read tools to understand code

### Finding Information

| Need to understand... | Do this |
|-----------------------|---------|
| How a feature works | Read `docs/features/<feature>.md` |
| Data model relationships | Check `docs/object_models/` |
| Feature requirements | Check `docs/specs/` |
| How a class works | Read the class file directly |
| Testing patterns | Read `docs/testing.md` |
| Project conventions | Read `docs/dev-core-values.md` |
