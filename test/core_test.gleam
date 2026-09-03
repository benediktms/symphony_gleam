import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import simplifile
import symphony/codex
import symphony/config
import symphony/domain.{
  AgentConfig, BlockerRef, CodexConfig, Config, HooksConfig, Issue,
  TrackerConfig,
}
import symphony/orchestrator
import symphony/prompt
import symphony/runtime
import symphony/tracker
import symphony/tracker/file
import symphony/workflow
import symphony/workspace

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn workflow_and_config_test() {
  let root = test_dir("workflow")
  let path = runtime.join(root, "WORKFLOW.md")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "---\ntracker:\n  kind: file\n  provider:\n    path: issues.json\n  active_states: [Todo]\n  terminal_states: [Done]\npolling:\n  interval_ms: 25\nworkspace:\n  root: workspaces\n---\nWork on {{issue.identifier}}\n",
    )
  let loaded = workflow.load(path) |> should.be_ok
  should.equal(loaded.prompt_template, "Work on {{issue.identifier}}")
  let effective = config.from_workflow(loaded) |> should.be_ok
  should.equal(effective.polling_interval_ms, 25)
  should.equal(effective.workspace_root, runtime.join(root, "workspaces"))
  should.equal(effective.agent.max_turns, 20)
  let _ = runtime.remove_tree(root)
}

pub fn malformed_front_matter_test() {
  let root = test_dir("bad_workflow")
  let path = runtime.join(root, "WORKFLOW.md")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(to: path, contents: "---\ntracker:\n  kind: file\n")
  workflow.load(path) |> should.be_error
  let _ = runtime.remove_tree(root)
}

pub fn strict_prompt_and_iteration_test() {
  let issue = issue("A-1", "Todo", ["bug", "ready"], 2)
  prompt.render(
    "{{issue.identifier}} {{#each issue.labels}}{{.}} {{/each}}attempt={{attempt}}",
    issue,
    Some(3),
  )
  |> should.equal(Ok("A-1 bug ready attempt=3"))
  prompt.render("{{unknown}}", issue, None) |> should.be_error
}

pub fn workspace_safety_and_hooks_test() {
  let root = test_dir("workspace")
  let config =
    test_config(
      root,
      HooksConfig(Some("printf x >> created"), None, None, None, 1000),
    )
  should.not_equal(workspace.key("A/B"), workspace.key("A?B"))
  should.equal(workspace.key("ABC-123"), "ABC-123")
  let first = workspace.create(config, "A/B") |> should.be_ok
  should.be_true(first.created_now)
  let second = workspace.create(config, "A/B") |> should.be_ok
  should.be_false(second.created_now)
  simplifile.read(runtime.join(first.path, "created")) |> should.equal(Ok("x"))
  workspace.remove(config, "A/B") |> should.equal(Ok(Nil))
  simplifile.exists(first.path, follow_links: False) |> should.equal(Ok(False))
  let _ = runtime.remove_tree(root)
}

pub fn file_tracker_boundary_test() {
  let root = test_dir("tracker")
  let path = runtime.join(root, "issues.json")
  let provider =
    dynamic.properties([
      #(dynamic.string("path"), dynamic.string(path)),
    ])
  let config = TrackerConfig("file", provider, [], ["Todo"], ["Done"])
  let adapter = file.new(config, root) |> should.be_ok
  tracker.fetch_issues_by_states(adapter, []) |> should.equal(Ok([]))
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(_) =
    simplifile.write(
      to: path,
      contents: "[{\"id\":\"1\",\"identifier\":\"T-1\",\"title\":\"Task\",\"state\":\"Todo\",\"labels\":[\" Ready \",\"READY\"],\"dispatchable\":true,\"priority\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}]",
    )
  let issues =
    tracker.fetch_issues_by_states(adapter, [" todo "]) |> should.be_ok
  let fetched = issues |> list.first |> should.be_ok
  should.equal(fetched.labels, ["ready"])
  should.equal(fetched.priority, Some(1))
  tracker.fetch_issues_by_ids(adapter, ["1"]) |> should.equal(Ok(issues))
  let _ = runtime.remove_tree(root)
}

pub fn scheduling_rules_test() {
  let later = issue("T-2", "Todo", [], 2)
  let first = issue("T-1", "Todo", [], 1)
  orchestrator.sort_issues([later, first]) |> should.equal([first, later])
  should.equal(orchestrator.retry_delay(1, 300_000), 10_000)
  should.equal(orchestrator.retry_delay(6, 300_000), 300_000)
  let tracker_config =
    TrackerConfig("file", dynamic.properties([]), ["ready"], ["Todo"], ["Done"])
  should.be_false(orchestrator.issue_routable(first, tracker_config))
}

pub fn codex_jsonl_protocol_test() {
  let root = test_dir("codex")
  let assert Ok(_) = simplifile.create_directory_all(root)
  let fixture = runtime.absolute_path("test/fixtures/fake_codex.py")
  let config =
    CodexConfig(
      "python3 " <> fixture,
      dynamic.string("never"),
      "workspace-write",
      dynamic.string("workspace-write"),
      2000,
      2000,
      2000,
    )
  let events = process.new_subject()
  let session = codex.start(config, root) |> should.be_ok
  let session =
    codex.run_turn(session, "Do the work", fn(event) {
      process.send(events, event)
    })
    |> should.be_ok
  let first = process.receive(events, 100) |> should.be_ok
  should.equal(first.event, "session_started")
  let usage_event = process.receive(events, 100) |> should.be_ok
  should.equal(usage_event.usage, Some(codex.Usage(3, 2, 5)))
  let completed = process.receive(events, 100) |> should.be_ok
  should.equal(completed.event, "turn_completed")
  codex.stop(session)
  let _ = runtime.remove_tree(root)
}

fn issue(
  identifier: String,
  state: String,
  labels: List(String),
  priority: Int,
) -> domain.Issue {
  Issue(
    id: identifier,
    native_ref: None,
    identifier: identifier,
    title: "Task " <> identifier,
    description: None,
    priority: Some(priority),
    state: state,
    branch_name: None,
    url: None,
    assignee_id: None,
    labels: labels,
    blocked_by: [BlockerRef(None, None, None)],
    dispatchable: True,
    created_at: Some(priority),
    updated_at: None,
  )
}

fn test_config(root: String, hooks: domain.HooksConfig) -> domain.Config {
  Config(
    tracker: TrackerConfig("file", dynamic.properties([]), [], ["Todo"], [
      "Done",
    ]),
    polling_interval_ms: 30_000,
    workspace_root: root,
    hooks: hooks,
    agent: AgentConfig(2, 2, 300_000, []),
    codex: CodexConfig(
      "codex app-server",
      dynamic.string("never"),
      "workspace-write",
      dynamic.string("workspace-write"),
      1000,
      1000,
      1000,
    ),
  )
}

fn test_dir(name: String) -> String {
  runtime.join(
    runtime.temp_dir(),
    "symphony_gleam_" <> name <> "_" <> int.to_string(runtime.now_ms()),
  )
}
