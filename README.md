# Tools Playground

Experimental repository for various tools.

## Bash command guard

The [Bash command guard](.claude/hooks/pre-bash-guard.sh)
blocks representative direct Bash invocations that match its configured rules.

- Requires `jq`
- Blocks Bash calls with exit code `2` when the hook input cannot be validated
- Allows valid commands that do not match a blocking rule
- Does not comprehensively inspect wrappers, expansions, absolute paths, or
  other interpreters

Run `./tests/pre-bash-guard.sh` to verify the guard.
