# Agent execution security boundary

## Product rule

`PermissionService` is the single owner of a tool's declaration-level permission decision. A matching explicit deny (a disabled tool or a project deny rule) is a hard block. It takes precedence over plan-mode transitions, interaction prompts, session grants, project allow rules, read-only shortcuts, `yolo`, and any future automatic reviewer. A denied call emits the existing denial event and never enters the approval broker or tool handler. `auto` remains unsupported.

Bash project rules already support exact commands and `:*` command prefixes. For a statically parsed compound command, a deny prefix matching any invocation blocks the whole call; an allow prefix must cover every invocation that is not classified read-only. These are declaration-level rules over the parsed command text, not an operating-system sandbox and not a guarantee about child processes or scripts. Dynamic syntax and nested interpreters can obscure later effects, so the UI and documentation must not call these rules kernel-enforced containment. A user who needs a true filesystem or network boundary must wait for a platform execution adapter that enforces it.

This phase does not activate Guardian. If added later, the reviewer must use only a model provider and credentials the user configured for CCbuddy. Missing model configuration leaves ordinary human approval available; a reviewer error cannot grant a request. Reviewer output can resolve only an `ask` decision. It cannot change a matching deny, widen filesystem or network access, persist an allow rule, or authorize an unsandboxed retry by itself. Reviewer input must be bounded and avoid secrets. Reviewer state, if persisted, belongs under `~/.ccbuddy`.

`ExecutionRequest.sandbox` is currently a declaration with no enforcement in `NodeExecutionAdapter`; until platform adapters are implemented, neither telemetry nor product copy may claim an OS sandbox. A future adapter must apply a real child-process policy before `spawn`, report the effective policy, and fail closed when a requested policy cannot be installed. macOS Seatbelt, Linux Landlock/seccomp/bubblewrap, and Windows restricted-token or equivalent paths require separate packaging and platform tests. The parent process may retain model network access, while child command access is governed by its own policy.

## Ownership and event order

```text
validated tool input -> PermissionService explicit deny -> mode/allow/ask policy
                   deny -> denial event -> return without execution
                    ask -> existing broker -> user decision -> handler
                  allow -> handler -> ExecutionPort
```

Project permissions remain in the existing session store. This change adds no new configuration file, state owner, migration, or model endpoint.

## Acceptance

1. A disabled tool is denied in build, plan, and yolo modes, including plan-mode transition tools.
2. A matching project deny rule blocks Bash in yolo mode even when a project allow rule also matches. A deny prefix matching one command in a static compound call blocks the whole call.
3. A nonmatching deny rule leaves the existing mode and allow behavior intact; a project ask rule continues to prompt.
4. A hard-denied call does not reach the approval broker or tool handler. The decision and error metadata preserve the rule ID, and the denial event preserves the reason.
5. No test or release note describes the current Bash execution as OS-sandboxed or Guardian-reviewed.
