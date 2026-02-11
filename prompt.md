Branch off main in a feature branch aptly named.

Study the specs.md and plan.md files.
Study the rest of the codebase.

From the plan.md file, take the first non-striked-through task of the task tree and start its implementation.
Make sure you read the file progress.txt: it contains learnings from previous implementations.
Make sure you respect ALL of the acceptance criteria listed under the task.
Acceptance criteria are always leaf nodes in the task tree.

While you implement a task, if you discover something useful for future implementations (e.g. a codebase pattern, an error that might recur, etc.) APPEND the learning to a progress.txt file.


When all of the criteria are verified and the implementation is done, mark the task itself (with all of its acceptance criteria) as done by striking them through, then commit the work and exit.
IF no undone task is present in the plan.md (i.e. all of the tasks are striked through), create a PR for manual review, then exit outputting the following: `<promise>COMPLETE</promise>`
