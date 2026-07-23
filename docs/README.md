# Sergeant Documentation

Sergeant is a single-user, local-first project orchestrator for developers who
work across one or more related repositories. Each developer runs an independent
installation with local configuration, credentials, workers, worktrees, and fleet
state.

## Start here

| Goal | Document |
|---|---|
| Understand the product and its boundaries | [What is Sergeant?](what-is-sergeant.md) |
| Install and configure a first project | [Getting started](getting-started.md) |
| Install the engineering skills used by agents | [Skills and their sources](skills.md) |
| Run direct and dispatched workflows | [Using Sergeant](using-sergeant.md) |
| Diagnose installation, worker, auth, and fleet problems | [Troubleshooting](troubleshooting.md) |

## Reference

- [Project YAML schema](schema.md)
- [OpenCode message injection](oc-inject.md)
- [Annotated project example](../schema/project.yaml.example)
- [Repository agent policy](../AGENTS.md)
- [Sergeant command skills](../skills/)

## Documentation authority

- `AGENTS.md` owns always-on agent execution and safety policy.
- `skills/*/SKILL.md` own trigger-specific procedures.
- `docs/schema.md` owns project configuration fields and path resolution.
- This documentation set owns user installation and operating instructions.
- Command `--help` output wins when the command implements it. Otherwise use the
  command's emitted usage/error contract and its tests; file a task when prose
  disagrees with released behavior.

Documentation examples must not contain real credentials, private repository
names, prompt bodies, response bodies, or secret-bearing environment values.
