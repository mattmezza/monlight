Study the specs.md and plan.md files.
Study the rest of the codebase.
All of your work shall be done in a a branch off of main called 'loop'.

From the plan.md file, take the first non-striked-through task of the task tree and start its implementation.
Make sure you read the file progress.txt: it contains learnings from previous implementations.
Make sure you respect ALL of the acceptance criteria listed under the task.
Acceptance criteria are always leaf nodes in the task tree.

While you implement a task, if you discover something useful for future implementations (e.g. a codebase pattern, an error that might recur, etc.) APPEND the learning to a progress.txt file.


When all of the criteria are verified and the implementation is done, mark the task itself (with all of its acceptance criteria) as done by striking them through, then commit the work and exit.
A subsequent iteration will tackle the next section of the plan.

When all tasks from a section of the plan are done, start tackling the next section's first task.
If no undone task is present in any of the sections of the plan (i.e. all of the tasks of all of the sections are striked through), create a PR for manual review, then output `<promise>COMPLETE</promise>` and exit.
