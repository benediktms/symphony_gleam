import symphony/domain.{type Issue, type ServiceError}

/// The complete tracker boundary used by the scheduler. New providers implement
/// these two reads; provider-specific writes belong in Codex tools, not here.
pub type Adapter {
  Adapter(
    kind: String,
    secret_environment_names: List(String),
    fetch_by_states: fn(List(String)) -> Result(List(Issue), ServiceError),
    fetch_by_ids: fn(List(String)) -> Result(List(Issue), ServiceError),
  )
}

pub fn fetch_issues_by_states(
  adapter: Adapter,
  states: List(String),
) -> Result(List(Issue), ServiceError) {
  case states {
    [] -> Ok([])
    _ -> adapter.fetch_by_states(states)
  }
}

pub fn fetch_issues_by_ids(
  adapter: Adapter,
  ids: List(String),
) -> Result(List(Issue), ServiceError) {
  case ids {
    [] -> Ok([])
    _ -> adapter.fetch_by_ids(ids)
  }
}
