# Issue tracker: GitHub

Issues and specs live in GitHub Issues. Use the `gh` CLI.
Infer the repository from the git remote.

## Conventions

- Create: `gh issue create --title "..." --body-file <file>`
- Read: `gh issue view <number> --comments`
- List: `gh issue list --state open --json number,title,body,labels`
- Comment: `gh issue comment <number> --body-file <file>`
- Apply labels: `gh issue edit <number> --add-label "..."`
- Remove labels: `gh issue edit <number> --remove-label "..."`
- Close: `gh issue close <number> --comment "..."`

For multiline bodies and comments, write the exact text to a temporary
file and pass it with `--body-file`.

When a skill says "publish to the issue tracker", create a GitHub issue.
When it says "fetch the relevant ticket", read the issue with comments.

## Pull requests as a triage surface

**PRs as a request surface: no.**
