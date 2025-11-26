# Branch Protection Recommendations

This document outlines the recommended branch protection settings for the EigenScript repository.

## Recommended Settings for `main` Branch

Maintainers should configure the following branch protection rules via GitHub Settings:

### Required Pull Request Reviews
- **Require pull request reviews before merging**: Enable this to ensure code review on all changes
- **Required number of approving reviews**: 1 (minimum)
- **Dismiss stale pull request approvals when new commits are pushed**: Enable to require re-review after changes

### Required Status Checks
- **Require status checks to pass before merging**: Enable to ensure CI passes
- **Require branches to be up to date before merging**: Enable to prevent merge conflicts
- **Status checks that are required**: 
  - `Test Python 3.10`, `Test Python 3.11`, `Test Python 3.12` (pytest matrix)
  - `Type Check` (mypy)
  - `Security Scan` (safety, bandit)

### Additional Protections
- **Include administrators**: Apply rules to repository administrators as well
- **Restrict who can push to matching branches**: Limit direct pushes to maintainers only
- **Allow force pushes**: Disable to preserve commit history
- **Allow deletions**: Disable to prevent accidental branch deletion

## How to Configure

1. Go to **Settings** → **Branches** in your GitHub repository
2. Click **Add branch protection rule**
3. Enter `main` as the branch name pattern
4. Configure the settings as described above
5. Click **Create** or **Save changes**

## Why These Settings?

- **Code Quality**: Reviews ensure multiple eyes on every change
- **CI/CD**: Status checks catch bugs before they reach main
- **History**: Preventing force pushes maintains a clear audit trail
- **Consistency**: Up-to-date requirements prevent integration issues
