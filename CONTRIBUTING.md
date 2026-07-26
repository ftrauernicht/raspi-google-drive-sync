# Contributing

Thanks for wanting to improve this!

## Ground rules

- All changes land via Pull Request. Direct pushes to `main` are blocked
  for everyone, including the maintainer — enforced by branch protection,
  not just convention.
- Keep PRs focused: one logical change per PR.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for
  commit messages (`feat:`, `fix:`, `docs:`, `test:`, `ci:`, ...).
- The automated CI checks (shellcheck + tests) must pass before a PR can be
  merged.

## How to contribute

1. Fork the repo and create a branch.
2. Make your change under `scripts/`, `systemd/`, `docs/`, and/or `tests/`.
3. Validate locally before opening the PR:
   ```bash
   shellcheck scripts/*.sh
   # run the tests under tests/ (see tests/README.md for how)
   ```
4. If you changed `scripts/drive-backup.sh` or any other script, update
   `docs/setup-guide.md` (and `docs/architecture.md` if the change affects
   the reasoning, not just the mechanics) in the same PR — the docs and the
   scripts must never drift apart.
5. Open a Pull Request against `main`. Fill in the PR template checklist.

## Naming and privacy convention

Never include real hostnames, IPs, credentials, or personal details (yours
or anyone else's) in any example, script default, or test fixture — use
generic placeholders (`<YOUR_EMAIL>`, `Documents/`, `my-drive-backup`,
etc.) or `config.env` values instead. This repo is meant to be copy-pasted
and adapted, not to accumulate real household details over time.
