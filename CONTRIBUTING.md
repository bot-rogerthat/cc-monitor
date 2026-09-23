# Contributing

Issues and pull requests are welcome.

- Keep it a single bash script with `jq` and `curl` as the only dependencies.
- It must work with the stock macOS tools (bash 3.2, BSD `date`, `stat`, `find`) as well as on Linux.
- Every change in behaviour comes with a case in `tests/run.sh`.
- Run `make` before sending a pull request: `shellcheck` and the tests must pass.
- Commit messages follow `<type>: <description>` (`feat`, `fix`, `refactor`, `docs`, `test`, `chore`).
