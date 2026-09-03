import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import symphony/domain.{
  type TrackerConfig, BlockerRef, Issue, TrackerConfig, TrackerError, normalize,
}
import symphony/runtime
import symphony/tracker.{type Adapter, Adapter}

pub fn new(
  config: TrackerConfig,
  workflow_directory: String,
) -> Result(Adapter, domain.ServiceError) {
  let TrackerConfig(provider:, ..) = config
  let decoder = {
    use path <- decode.field("path", decode.string)
    decode.success(path)
  }
  use path <- result.try(
    decode.run(provider, decoder)
    |> result.map_error(fn(errors) {
      TrackerError(
        "invalid_tracker_config",
        "file provider.path: " <> string.inspect(errors),
      )
    }),
  )
  use path <- result.try(resolve_path(path, workflow_directory))
  let read = fn() { read_issues(path) }
  Ok(
    Adapter(
      kind: "file",
      fetch_by_states: fn(states) {
        use issues <- result.try(read())
        let states = list.map(states, normalize)
        Ok(
          list.filter(issues, fn(issue) {
            list.contains(states, normalize(issue.state))
          }),
        )
      },
      fetch_by_ids: fn(ids) {
        use issues <- result.try(read())
        Ok(list.filter(issues, fn(issue) { list.contains(ids, issue.id) }))
      },
    ),
  )
}

fn resolve_path(
  path: String,
  workflow_directory: String,
) -> Result(String, domain.ServiceError) {
  let expanded = case path {
    "$" <> variable ->
      case runtime.getenv(variable) {
        Ok(value) if value != "" -> Ok(value)
        _ ->
          Error(TrackerError(
            "missing_tracker_secret",
            "provider.path environment variable is missing",
          ))
      }
    _ -> Ok(path)
  }
  use expanded <- result.try(expanded)
  Ok(case string.starts_with(expanded, "/") {
    True -> runtime.absolute_path(expanded)
    False -> runtime.absolute_path(runtime.join(workflow_directory, expanded))
  })
}

fn read_issues(
  path: String,
) -> Result(List(domain.Issue), domain.ServiceError) {
  use source <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      TrackerError(
        "tracker_request",
        "could not read " <> path <> ": " <> simplifile.describe_error(error),
      )
    }),
  )
  json.parse(source, decode.list(issue_decoder()))
  |> result.map_error(fn(errors) {
    TrackerError(
      "tracker_response",
      "invalid issue snapshot: " <> string.inspect(errors),
    )
  })
}

fn issue_decoder() -> decode.Decoder(domain.Issue) {
  use id <- decode.field("id", non_empty_string())
  use native_ref <- decode.optional_field(
    "native_ref",
    None,
    decode.optional(decode.dynamic),
  )
  use identifier <- decode.field("identifier", non_empty_string())
  use title <- decode.field("title", non_empty_string())
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use priority <- decode.optional_field(
    "priority",
    None,
    decode.optional(decode.int),
  )
  use state <- decode.field("state", non_empty_string())
  use branch_name <- decode.optional_field(
    "branch_name",
    None,
    decode.optional(decode.string),
  )
  use url <- decode.optional_field("url", None, decode.optional(decode.string))
  use assignee_id <- decode.optional_field(
    "assignee_id",
    None,
    decode.optional(decode.string),
  )
  use labels <- decode.optional_field("labels", [], decode.list(decode.string))
  use blocked_by <- decode.optional_field(
    "blocked_by",
    [],
    decode.list(blocker_decoder()),
  )
  use dispatchable <- decode.field("dispatchable", decode.bool)
  use created_at <- decode.optional_field(
    "created_at",
    None,
    decode.optional(decode.string),
  )
  use updated_at <- decode.optional_field(
    "updated_at",
    None,
    decode.optional(decode.string),
  )
  decode.success(Issue(
    id: id,
    native_ref: native_ref,
    identifier: identifier,
    title: title,
    description: description,
    priority: priority,
    state: state,
    branch_name: branch_name,
    url: url,
    assignee_id: assignee_id,
    labels: normalize_labels(labels),
    blocked_by: blocked_by,
    dispatchable: dispatchable,
    created_at: parse_time(created_at),
    updated_at: parse_time(updated_at),
  ))
}

fn non_empty_string() -> decode.Decoder(String) {
  decode.string
  |> decode.then(fn(value) {
    case string.trim(value) {
      "" -> decode.failure("", expected: "non-empty String")
      trimmed -> decode.success(trimmed)
    }
  })
}

fn blocker_decoder() -> decode.Decoder(domain.BlockerRef) {
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use identifier <- decode.optional_field(
    "identifier",
    None,
    decode.optional(decode.string),
  )
  use state <- decode.optional_field(
    "state",
    None,
    decode.optional(decode.string),
  )
  decode.success(BlockerRef(id, identifier, state))
}

fn normalize_labels(labels: List(String)) -> List(String) {
  labels
  |> list.map(fn(label) { label |> string.trim |> string.lowercase })
  |> list.filter(fn(label) { label != "" })
  |> list.unique
}

fn parse_time(value: Option(String)) -> Option(Int) {
  case value {
    None -> None
    Some(value) ->
      runtime.parse_rfc3339(value) |> result.map(Some) |> result.unwrap(None)
  }
}
