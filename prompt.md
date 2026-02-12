# Agent Instructions

You are an autonomous coding agent working on a software project.

## Your task

1. Read the `specs.md` and `plan.md` files (in the same directory as this file)
2. Read the progress log at `progress.txt`
3. Check you are on the correct branch `looop`. If not, check it our or create from main.
4. From the plan.md file, pick the first non-striked-through task of the task tree
5. Implement that single task
6. Run quality checks (e.g. tests - use whatever your project requires)
7. Update AGENTS.md files if you discover reusable patterns (see below)
8. If quality checks and all acceptance criteria pass, commit ALL changes
9. Update the `plan.md` striking through the completed task
10. Append your progress to `progress.txt`


## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered (e.g., "this codebase uses X for Y")
  - Gotchas encountered (e.g., "don't forget to update Z when changing W")
  - Useful context (e.g., "the evaluation panel is in component X")
---
```

The learnings section is critical - it helps future iterations avoid repeating mistakes and understand the codebase better.

## Consolidate Patterns

If you discover a **reusable pattern** that future iterations should know, add it to the `## Codebase Patterns` section at the TOP of progress.txt (create it if it doesn't exist). This section should consolidate the most important learnings:

```
## Codebase Patterns
- Example: Use `sql<number>` template for aggregations
- Example: Always use `IF NOT EXISTS` for migrations
```

Only add patterns that are **general and reusable**, not story-specific details.

## Update AGENTS.md Files

Before committing, check if any edited files have learnings worth preserving in nearby AGENTS.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing AGENTS.md** - Look for AGENTS.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Examples of good AGENTS.md additions:**
- "When modifying X, also update Y to keep them in sync"
- "This module uses pattern Z for all API calls"
- "Tests require the dev server running on PORT 3000"
- "Field names must match the template exactly"

**Do NOT add:**
- Story-specific implementation details
- Temporary debugging notes
- Information already in progress.txt

Only update AGENTS.md if you have **genuinely reusable knowledge** that would help future work in that directory.

## Quality Requirements

- ALL commits must pass your project's quality checks (e.g. lint, test, etc.)
- Do NOT commit broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Stop Condition

After completing a task, check if ALL tasks are striked through (i.e. done)

If ALL tasks are complete and passing, reply with:
<promise>COMPLETE</promise>

If there are still tasks without strike through, end your response normally (another iteration will pick up the next story).

## The `plan.md` task tree format

The task tree is structured as follows:

```
- tasks section (refers to one of the larger components of the system)
  - task list (contains a list of tasks related to the section / larger component)
    - task (a single task)
      - acceptance criterion (needs to pass)
      - acceptance criterion (needs to pass)
    - task (a single task)
      - sub-task (a single sub-task)
        - acceptance criterion (needs to pass)
        - ...

- tasks section (repeats)
...
```

If a task has no sub-tasks, you can consider it as the smallest unit of work you can pick up.
If a task has sub-tasks, you should pick up a single sub-task as a smallest unit of work.
If a sub-task has sub-sub-tasks, you should instead consider them.
And so on...

## Important

- Work on ONE task per iteration
- Commit frequently
- Keep CI green
- Read the Codebase Patterns section in progress.txt before starting
