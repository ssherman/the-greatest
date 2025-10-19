# The Greatest - Sub-Agent Reference

This project uses specialized Claude Code sub-agents to handle specific types of tasks efficiently. Each agent has a focused purpose and access to specific tools.

## Available Sub-Agents

### 1. codebase-locator
**Purpose**: Find WHERE code lives in the Rails application
**Best for**: Locating files, directories, and components by feature or topic
**Tools**: Grep, Glob, LS, Ripgrep

**When to use**:
- "Where is the music artist import code?"
- "Find all files related to MusicBrainz integration"
- "Locate the ranking calculation logic"
- You need to find files but don't know exact paths

**What it does**:
- Searches across the codebase using multiple strategies
- Groups results by Rails conventions (models, controllers, services, etc.)
- Identifies domain-specific vs shared code
- Does NOT analyze file contents or implementation

---

### 2. codebase-analyzer
**Purpose**: Understand HOW existing code works
**Best for**: Deep dives into implementation details and data flow
**Tools**: Read, Grep, Glob, LS

**When to use**:
- "How does the artist import process work?"
- "Trace the data flow for ranking calculations"
- "Explain the MusicBrainz API integration"
- You need to understand implementation details

**What it does**:
- Reads and analyzes code files in detail
- Traces data flow through the system
- Documents architectural patterns and integration points
- Provides file:line references for all findings
- Does NOT critique code or suggest improvements

---

### 3. codebase-pattern-finder
**Purpose**: Find existing patterns to model new code after
**Best for**: Discovering similar implementations and reusable patterns
**Tools**: Grep, Glob, Read, LS, Ripgrep

**When to use**:
- "Show me examples of background job implementations"
- "Find patterns for polymorphic association usage"
- "How are service objects structured in this project?"
- You want to follow existing conventions

**What it does**:
- Locates similar implementations across the codebase
- Extracts concrete code examples with context
- Shows multiple variations of patterns
- Includes test patterns and usage examples
- Does NOT recommend which pattern is "better"

---

### 4. technical-writer
**Purpose**: Create and maintain comprehensive documentation
**Best for**: Documenting new classes, updating docs, task management
**Tools**: All tools (inherits full toolset)

**When to use**:
- After creating new models, services, or controllers
- When updating existing classes that need doc updates
- Creating or updating task files in `docs/todos/`
- Ensuring documentation stays in sync with code

**What it does**:
- Creates class documentation following project templates
- Updates task management files
- Maintains cross-references and consistency
- Tracks changes made by AI agents
- Follows strict documentation standards for The Greatest

---

### 5. web-search-researcher
**Purpose**: Research information from the web
**Best for**: Finding documentation, best practices, and current information
**Tools**: WebSearch, WebFetch, TodoWrite, Read, Grep, Glob, LS
**Color**: Yellow (for easy identification)

**When to use**:
- "What's the latest Rails 8 enum syntax?"
- "How does nginx-ultimate-bad-bot-blocker work?"
- "Find Docker Compose v2 plugin documentation"
- You need current information beyond the AI's training data

**What it does**:
- Performs strategic web searches
- Fetches and analyzes content from authoritative sources
- Synthesizes findings with proper attribution
- Prioritizes official documentation and expert sources
- Notes publication dates and version information

---

### 6. avo-engineer
**Purpose**: Expert in the Avo admin framework for Ruby on Rails
**Best for**: Creating/configuring Avo resources, actions, filters, and dashboards
**Tools**: All tools (inherits full toolset)

**When to use**:
- "Create an Avo resource for the Music::Artist model"
- "Add a custom action to bulk import artists"
- "Configure authorization for the admin panel"
- "Build a dashboard for ranking statistics"
- Any Avo-specific implementation or configuration

**What it does**:
- Creates and maintains Avo resources following domain namespacing
- Implements custom actions, filters, and scopes
- Configures Pundit authorization for admin access
- Builds dashboards and custom tools
- Ensures Avo resources mirror ActiveRecord models
- Follows Avo 3.x best practices and patterns

**Knowledge Base**:
- Complete Avo 3.x documentation embedded in agent
- Deep understanding of field types and configurations
- Authorization patterns with Pundit
- Custom component development
- Performance optimization strategies

---

## Common Sub-Agent Workflows

### Finding and Understanding Code
1. **codebase-locator** → Find where code lives
2. **codebase-analyzer** → Understand how it works
3. **codebase-pattern-finder** → Find similar patterns to follow

### Implementing New Features
1. **codebase-pattern-finder** → Find existing patterns
2. **codebase-analyzer** → Understand the pattern details
3. **technical-writer** → Document the new code

### Research and Implementation
1. **web-search-researcher** → Research best practices/APIs
2. **codebase-pattern-finder** → Find how similar things are done
3. **technical-writer** → Document decisions and implementation

### Avo Admin Development
1. **codebase-analyzer** → Understand the model structure and associations
2. **avo-engineer** → Create Avo resources, actions, and authorization
3. **technical-writer** → Document the admin interface capabilities

---

## Potential Additional Sub-Agents

### Backend Engineer Agent (Proposed)
**Purpose**: Implement backend features following Rails conventions
**Focus**: Models, services, background jobs, API integrations
**Tools**: Read, Write, Edit, Grep, Glob, Bash (Rails commands)

**Would be useful for**:
- Implementing new models with proper namespacing
- Creating service objects following project patterns
- Building background jobs and data importers
- Integrating external APIs (MusicBrainz, TMDB, etc.)

**Considerations**:
- Overlaps with general-purpose agent
- Most valuable if highly specialized in Rails 8 + project conventions
- Should enforce namespacing, polymorphic patterns, service patterns
- Could auto-invoke technical-writer for documentation

### Frontend Engineer Agent (Proposed)
**Purpose**: Implement Hotwire/Stimulus features following project conventions
**Focus**: Views, Stimulus controllers, Turbo Frames, ViewComponents
**Tools**: Read, Write, Edit, Grep, Glob

**Would be useful for**:
- Creating domain-specific views and layouts
- Building Stimulus controllers for interactivity
- Implementing Turbo Frame navigation
- Creating reusable ViewComponents

**Considerations**:
- Overlaps with general-purpose agent
- Most valuable for pure UI/UX work
- Could enforce domain-specific asset organization
- Would need deep knowledge of Hotwire patterns

---

## When to Use Sub-Agents vs Main Agent

### Use Sub-Agents When:
- Task is clearly within a sub-agent's specialty
- You want focused, non-judgmental analysis
- Multiple search/analysis rounds would be needed
- Documentation needs to be created/updated

### Use Main Agent When:
- Task requires code changes and testing
- Multiple concerns need to be balanced
- Decisions need to be made about approach
- Implementation requires multiple tool types

---

## Sub-Agent Conventions

### All Sub-Agents Share:
- **Descriptive, not prescriptive**: Document what exists, don't judge
- **Precise references**: Always include file:line numbers
- **Focus on their specialty**: Stay in their lane
- **AI-friendly**: Structured output for easy parsing

### None of Them:
- Critique code quality or architecture
- Suggest improvements (unless explicitly asked)
- Perform root cause analysis (unless explicitly asked)
- Identify "problems" or "anti-patterns"

---

## Getting Started with Sub-Agents

To invoke a sub-agent, the main Claude Code assistant will use the Task tool with the appropriate `subagent_type`:

```
Task: codebase-locator
Prompt: "Find all files related to MusicBrainz artist import"
```

The sub-agent will complete its task and return structured findings, which the main agent can then use to continue the work.

---

## Related Documentation

- [AGENTS.md](../AGENTS.md) - Quick reference for AI agents
- [dev-core-values.md](dev-core-values.md) - Project development principles
- [documentation.md](documentation.md) - Documentation standards
- [testing.md](testing.md) - Testing guidelines
- [todo-guide.md](todo-guide.md) - Task management workflow
