# Symphony for Gleam

A Gleam/OTP implementation of the [OpenAI Symphony service specification](https://github.com/openai/symphony/blob/main/SPEC.md). It polls a tracker, creates isolated per-issue workspaces, and drives Codex app-server sessions until an issue leaves its active state.

## Run

Requirements: Gleam 1.18+, Erlang/OTP 26+, and an authenticated `codex` executable. OTP 26 is the minimum because older `httpc` versions do not verify TLS by default.

```sh
gleam deps download
cp WORKFLOW.example.md WORKFLOW.md
cp issues.example.json issues.json
gleam run
```

An explicit workflow path overrides `./WORKFLOW.md`:

```sh
gleam run -- /path/to/WORKFLOW.md
```

Run the conformance checks with:

```sh
gleam test
```

## Tracker boundary

The scheduler depends only on `symphony/tracker.Adapter`, a record containing two functions:

```gleam
Adapter(
  kind: String,
  secret_environment_names: List(String),
  fetch_by_states: fn(List(String)) -> Result(List(Issue), ServiceError),
  fetch_by_ids: fn(List(String)) -> Result(List(Issue), ServiceError),
)
```

To add a provider, implement those reads in `src/symphony/tracker/<provider>.gleam` and add its `kind` to `tracker_factory.create`. Provider-native writes should be Codex tools; they do not belong in this portable scheduling boundary.

### Built-in `file` adapter profile

The initial adapter reads a JSON array from `tracker.provider.path`. It is useful for local operation, tests, and as a reference adapter.

- `tracker.kind`: exactly `file`
- `tracker.provider.path`: required string; relative paths resolve beside `WORKFLOW.md`; `$VAR` resolves a host environment variable
- Scope: every record in the file
- Pagination/rate limits/authentication: none
- Dispatch identity: JSON `id`; duplicate IDs or identifiers reject the snapshot
- `native_ref`: preserved only when it is a non-secret JSON object; other values normalize to null
- Errors: missing/unreadable file -> `tracker_request`; invalid config -> `invalid_tracker_config`; malformed records -> `tracker_response`
- Tools/writes: none

Each record must contain `id`, `identifier`, `title`, `state`, and boolean `dispatchable`. Optional fields follow the normalized Issue model in the spec. Labels are trimmed, lowercased, and deduplicated; RFC 3339 timestamps are parsed to instants.

## Runtime behavior

- `WORKFLOW.md` is re-read before every poll. An invalid reload is reported and the last good configuration remains active.
- Workspaces use sanitized identifiers. Changed identifiers receive a 64-bit SHA-256 suffix, and symlink/non-directory workspace paths are rejected.
- Hooks run through `sh -lc` in the issue workspace with the configured timeout.
- Codex uses the current newline-delimited JSON app-server protocol: `initialize`, `thread/start`, and repeated `turn/start` calls on one thread.
- Normal exits receive a one-second continuation check; failures use capped 10-second exponential backoff.
- Reconciliation stops missing, terminal, inactive, unroutable, or stalled work. Terminal issues also have their workspaces removed.
- Logs use stable `key=value` fields and include issue identity where applicable.

The optional HTTP/status server, SSH workers, persistent retry state, and provider-native tools are intentionally not included.

## Security posture

Defaults are conservative: approval policy `never`, thread sandbox `workspace-write`, a workspace-write turn policy with network disabled, approval requests declined, and interactive user-input requests failed rather than left hanging. These values can be changed in `WORKFLOW.md` using values supported by the installed Codex app-server. A spec-shaped `turn_sandbox_policy` object is passed through; the string shorthands `workspace-write`, `read-only`, and `danger-full-access` are also accepted.

Tracker adapters declare credential environment names through `secret_environment_names`; Symphony removes them from the Codex child environment. The built-in file adapter has no credential, so it declares an empty list. Hooks are trusted repository-owned shell code.

Protocol implementation was validated against `codex-cli 0.150.1`; regenerate the installed schema and run the tests when targeting another Codex version:

```sh
codex app-server generate-json-schema --out /tmp/codex-schema
gleam test
```
