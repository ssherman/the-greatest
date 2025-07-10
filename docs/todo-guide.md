# The Greatest - Task Management Guide

## Overview
All work is tracked through markdown files that serve as both task management and historical documentation. This creates a comprehensive record of what was planned, why decisions were made, and how features were implemented.

## Structure

### Main Todo List
`todo.md` - Priority-sorted list of all tasks
```markdown
# The Greatest - Todo List

## High Priority
1. [Multi-domain routing setup](todos/001-multi-domain-routing.md)
2. [Books data import from existing site](todos/002-books-data-import.md)
3. [User authentication with Firebase](todos/003-firebase-auth.md)

## Medium Priority
4. [Recommendation engine MVP](todos/004-recommendation-engine.md)
5. [OpenSearch integration](todos/005-opensearch-integration.md)

## Low Priority
6. [Admin interface with Avo](todos/006-admin-interface.md)

## Completed
- ✅ [2024-11-15] [Project setup and structure](todos/000-project-setup.md)
```

### Individual Task Files
Each task has its own detailed file in `todos/` folder:

```
todos/
├── 001-multi-domain-routing.md
├── 002-books-data-import.md
├── 003-firebase-auth.md
├── completed/
│   └── 000-project-setup.md
└── templates/
    └── task-template.md
```

## Task File Template

```markdown
# [Task Number] - [Task Title]

## Status
- **Status**: Not Started | In Progress | Completed
- **Priority**: High | Medium | Low
- **Created**: YYYY-MM-DD
- **Started**: YYYY-MM-DD
- **Completed**: YYYY-MM-DD
- **Developer**: [Name/Handle]

## Overview
Brief description of what needs to be accomplished and why.

## Context
- Why is this needed?
- What problem does it solve?
- How does it fit into the larger system?

## Requirements
- [ ] Specific requirement 1
- [ ] Specific requirement 2
- [ ] Specific requirement 3

## Technical Approach
Proposed technical solution and architecture decisions.

## Dependencies
- Other tasks that must be completed first
- External services or APIs needed
- Gems or libraries to be added

## Acceptance Criteria
- [ ] User can...
- [ ] System should...
- [ ] Performance metrics...

## Design Decisions
Document any important decisions made during planning.

---

## Implementation Notes
*[This section is filled out during/after implementation]*

### Approach Taken
Describe how the feature was actually implemented.

### Key Files Changed
- `app/models/user.rb` - Added authentication methods
- `config/routes.rb` - Added auth routes
- `app/controllers/sessions_controller.rb` - New controller

### Challenges Encountered
Document any unexpected issues and how they were resolved.

### Deviations from Plan
Note any changes from the original technical approach and why.

### Code Examples
```ruby
# Key code snippets that illustrate the implementation
```

### Testing Approach
How the feature was tested, any edge cases discovered.

### Performance Considerations
Any optimizations made or needed.

### Future Improvements
Potential enhancements identified during implementation.

### Lessons Learned
What worked well, what could be done better next time.

### Related PRs
- #123 - Initial implementation
- #125 - Bug fix for edge case

### Documentation Updated
- [ ] Class documentation files updated
- [ ] API documentation updated
- [ ] README updated if needed
```

## Workflow

### Creating a New Task
1. Add entry to `todo.md` in appropriate priority section
2. Create detailed task file in `todos/` folder
3. Use sequential numbering (001, 002, etc.)
4. Include all known context and requirements

### During Implementation
1. Update status to "In Progress"
2. Add implementation notes as you work
3. Document decisions and trade-offs
4. Note any scope changes

### After Completion
1. Fill out Implementation Notes section completely
2. Update status to "Completed" with date
3. Move to Completed section in `todo.md`
4. Consider moving file to `todos/completed/` folder
5. Update any affected documentation

## Best Practices

### Task Sizing
- Break large features into smaller tasks
- Each task should be completable in 1-5 days
- Create sub-tasks as separate files if needed

### Documentation Detail
- Include enough context for AI agents to understand
- Link to relevant documentation or external resources
- Add diagrams or mockups if helpful

### Historical Value
- Think of these as archaeological records
- Future developers (or AI) should understand the "why"
- Include failed approaches and why they didn't work

### Cross-References
- Link between related tasks
- Reference class documentation files
- Link to external resources or discussions

## Benefits
- Complete historical record of development
- AI agents have full context for any feature
- Easy to understand why decisions were made
- Onboarding new developers is simpler
- Can trace evolution of features over time
- Helps with debugging and maintenance

## Example Task Lifecycle

1. **Planning**: Task identified, file created with requirements
2. **Refinement**: Technical approach added after research
3. **Implementation**: Status updated, notes added during coding
4. **Review**: Implementation notes completed
5. **Archive**: Serves as permanent documentation

## Recent Example: RankedList Model Implementation

**Task**: [009-ranked-list-model.md](todos/009-ranked-list-model.md)

**Lifecycle**:
1. **Planning**: Identified need for linking lists to ranking configurations with weights
2. **Refinement**: Initially planned polymorphic association, then refined to use STI approach
3. **Implementation**: Created model, migration, tests, and fixtures
4. **Review**: Fixed polymorphic vs STI confusion, updated schema, all tests passing
5. **Archive**: Documented in [ranked_list.md](models/ranked_list.md) and marked complete in todo.md

**Key Learning**: Polymorphic associations are not needed when using STI - regular associations work better for same-table inheritance scenarios.

This system creates a living history of the project that's invaluable for maintenance, debugging, and AI-assisted development.