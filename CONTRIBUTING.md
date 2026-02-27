# Contributing to VPS Deploy Playbook

Thanks for your interest in contributing! This playbook improves with real-world feedback and community input.

## How to Contribute

### Report an Issue

Found an error, outdated command, or broken example? [Open an issue](https://github.com/adityonugrohoid/vps-deploy-playbook/issues/new) with:

- Which chapter and section
- What's wrong
- What the correct information should be (if you know)

### Suggest an Improvement

Have a better approach for something covered in the playbook? Open an issue first to discuss before submitting a PR. This saves everyone time if the change doesn't fit the playbook's philosophy.

### Submit a Pull Request

1. Fork the repository
2. Create a branch from `main`: `git checkout -b feat/your-change`
3. Make your changes
4. Commit with conventional commit style: `feat:`, `fix:`, `docs:`
5. Push to your fork and open a PR against `main`

## Content Guidelines

### What belongs here

- Battle-tested patterns you've used in production
- Corrections to commands or configuration examples
- New chapters covering VPS deployment topics not yet covered
- Improvements to clarity, especially for beginners

### What doesn't belong here

- Kubernetes, Swarm, or orchestration-heavy approaches (this is a single-VPS playbook)
- Cloud-specific services (AWS ECS, GCP Cloud Run, etc.)
- Theoretical patterns without practical examples
- Vendor-specific tools that require paid licenses

### Writing style

- **Be opinionated.** "We recommend X because Y" is better than "You could use X or Y or Z."
- **Include real commands.** Every recommendation should have copy-pasteable code.
- **Explain the why.** Don't just show the what — explain why this approach was chosen.
- **Use ASCII diagrams** for architecture visuals.
- **Target Ubuntu 22.04/24.04 LTS** unless explicitly noting another OS.

### Code style

- Shell scripts: Use `set -euo pipefail`, include usage comments
- YAML: 2-space indentation, include comments for non-obvious settings
- Nginx: Include comments explaining each directive's purpose

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add chapter on database management
fix: correct UFW command in chapter 01
docs: clarify Docker networking explanation
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
