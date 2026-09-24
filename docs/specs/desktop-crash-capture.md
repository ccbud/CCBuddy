# Desktop crash capture at startup

## Behavior and ownership

Desktop main owns crash dump paths and starts crash capture before creating any
window. The early data-directory bootstrap runs first, then local crash dump
archiving and capture configuration, then optional ARMS initialization. One
shared startup decision uses the telemetry switch and a configured ARMS RUM
endpoint to select the crash reporter mode. The decision is read once from
the runtime environment; it is not persisted or changed during a process run.

```text
data directory bootstrap -> crash dump path and archive -> reporter selection
                                                     -> optional ARMS init
```

If ARMS RUM is enabled, the local-only Electron crashReporter is skipped so
that ARMS can own remote crash reporting. If telemetry is disabled or no ARMS
endpoint is configured, Electron crashReporter starts with remote upload
disabled, preserving local crash dumps. A missing endpoint must never leave
both reporters inactive. Existing crash dump archiving and retention apply in
either mode. Failure to initialize configured ARMS remains a startup failure;
this change does not add a second reporter after that failure.

## Acceptance

1. An empty ARMS endpoint selects the local-only crashReporter.
2. A configured ARMS endpoint with telemetry enabled selects ARMS and avoids
   starting a second crashReporter.
3. Telemetry disabled selects local capture even when an endpoint is present.
4. The crash bootstrap and ARMS bootstrap read the same startup decision, with
   crash dump setup still occurring before ARMS initialization.
