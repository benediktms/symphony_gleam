import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response.{Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import symphony/tracker/github/client

pub fn main() -> Nil {
  let _ = project_url_validation_test()
  let _ = fetch_project_items_builds_request_and_decodes_issues_test()
  let _ = user_projects_select_only_the_user_root_test()
  let _ = project_item_pagination_requires_a_cursor_test()
  let _ = project_item_pagination_advances_test()
  let _ = nested_connection_overflow_fails_the_snapshot_test()
  let _ = fetch_by_ids_restores_requested_order_test()
  let _ = fetch_by_ids_limits_batches_to_fifty_test()
  let _ = http_status_errors_do_not_include_response_bodies_test()
  let _ = graphql_rate_limit_is_atomic_test()
  Nil
}

pub fn project_url_validation_test() {
  client.parse_project_url(
    "https://github.com/orgs/freshaengineering/projects/3/",
  )
  |> should.equal(
    Ok(client.ProjectReference(client.Organization, "freshaengineering", 3)),
  )

  client.parse_project_url("https://github.com/users/benediktms/projects/2")
  |> should.equal(Ok(client.ProjectReference(client.User, "benediktms", 2)))

  client.parse_project_url("https://example.com/orgs/acme/projects/1")
  |> should.be_error
}

pub fn fetch_project_items_builds_request_and_decodes_issues_test() {
  let send = fn(req: request.Request(String)) {
    req.method |> should.equal(http.Post)
    req.host |> should.equal("api.github.com")
    req.path |> should.equal("/graphql")
    request.get_header(req, "authorization")
    |> should.equal(Ok("Bearer secret"))
    request.get_header(req, "accept")
    |> should.equal(Ok("application/vnd.github+json"))
    request.get_header(req, "user-agent")
    |> should.equal(Ok("symphony-gleam/0.1"))
    request.get_header(req, "x-github-api-version")
    |> should.equal(Ok("2026-03-10"))
    string.contains(req.body, "SymphonyProjectItems") |> should.be_true
    string.contains(req.body, "owner: organization") |> should.be_true
    let body =
      project_page(
        "["
          <> issue_item("ITEM-1", 7)
          <> ",{\"id\":\"DRAFT-1\",\"type\":\"DRAFT_ISSUE\"}]",
        False,
        "null",
      )
    json.parse(body, decode.dynamic) |> should.be_ok
    Ok(Response(200, [], body))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )

  let assert Ok(client.Snapshot("PROJECT-1", "benediktms", [item])) =
    client.fetch_project_items(github)
  item.id |> should.equal("ITEM-1")
  item.status |> should.equal(Some(client.ProjectFieldValue("Todo")))
  item.priority |> should.equal(Some(client.ProjectFieldValue("P1")))
  item.issue.repository |> should.equal("acme/widgets")
  item.issue.assignees
  |> should.equal([
    client.Assignee("USER-2", "zebra"),
    client.Assignee("USER-1", "alpha"),
  ])
  item.issue.labels |> should.equal([client.Label("Bug")])
  item.issue.blocked_by
  |> should.equal([
    client.Blocker(
      "ISSUE-6",
      6,
      "OPEN",
      "https://github.com/acme/widgets/issues/6",
      "acme/widgets",
      [
        client.BlockerProjectItem(
          "BLOCKER-ITEM",
          "PROJECT-1",
          Some(client.ProjectFieldValue("Done")),
        ),
      ],
    ),
  ])
}

pub fn user_projects_select_only_the_user_root_test() {
  let send = fn(req: request.Request(String)) {
    string.contains(req.body, "owner: user") |> should.be_true
    string.contains(req.body, "owner: organization") |> should.be_false
    Ok(Response(200, [], project_page("[]", False, "null")))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/users/benediktms/projects/2",
      "secret",
      send,
    )

  client.fetch_project_items(github)
  |> should.equal(Ok(client.Snapshot("PROJECT-1", "benediktms", [])))
}

pub fn project_item_pagination_requires_a_cursor_test() {
  let send = fn(_req) {
    Ok(Response(200, [], project_page("[]", True, "null")))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )

  client.fetch_project_items(github)
  |> should.equal(
    Error(client.InvalidPagination(
      "project items hasNextPage without endCursor",
    )),
  )
}

pub fn project_item_pagination_advances_test() {
  let send = fn(req: request.Request(String)) {
    let body = case string.contains(req.body, "cursor-1") {
      True -> project_page("[]", False, "null")
      False -> project_page("[]", True, "\"cursor-1\"")
    }
    Ok(Response(200, [], body))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )

  client.fetch_project_items(github)
  |> should.equal(Ok(client.Snapshot("PROJECT-1", "benediktms", [])))
}

pub fn nested_connection_overflow_fails_the_snapshot_test() {
  let overflowing_item =
    issue_item("ITEM-1", 7)
    |> string.replace("\"hasNextPage\":false", "\"hasNextPage\":true")
  let send = fn(_req) {
    Ok(Response(
      200,
      [],
      project_page("[" <> overflowing_item <> "]", False, "null"),
    ))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )

  client.fetch_project_items(github)
  |> should.equal(
    Error(client.InvalidPagination(
      "a nested GitHub connection exceeds 100 entries",
    )),
  )
}

pub fn fetch_by_ids_restores_requested_order_test() {
  let send = fn(req: request.Request(String)) {
    string.contains(req.body, "SymphonyProjectNodes") |> should.be_true
    Ok(Response(
      200,
      [],
      "{\"data\":{\"viewer\":{\"login\":\"benediktms\"},\"owner\":{\"projectV2\":{\"id\":\"PROJECT-1\"}},\"nodes\":["
        <> node_item("ITEM-B", 2)
        <> ",null,"
        <> node_item("ITEM-A", 1)
        <> "]}}",
    ))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )

  let assert Ok(client.Snapshot(_, _, items)) =
    client.fetch_project_items_by_ids(github, ["ITEM-A", "missing", "ITEM-B"])
  list.map(items, fn(item) { item.id })
  |> should.equal(["ITEM-A", "ITEM-B"])
}

pub fn fetch_by_ids_limits_batches_to_fifty_test() {
  let send = fn(req: request.Request(String)) {
    let assert Ok(ids) = json.parse(req.body, request_ids_decoder())
    let assert True = list.length(ids) <= 50
    Ok(Response(
      200,
      [],
      "{\"data\":{\"viewer\":{\"login\":\"benediktms\"},\"owner\":{\"projectV2\":{\"id\":\"PROJECT-1\"}},\"nodes\":[]}}",
    ))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )
  let ids =
    int.range(from: 1, to: 52, with: [], run: fn(ids, number) {
      ["ITEM-" <> int.to_string(number), ..ids]
    })

  client.fetch_project_items_by_ids(github, ids)
  |> should.equal(Ok(client.Snapshot("PROJECT-1", "benediktms", [])))
}

pub fn http_status_errors_do_not_include_response_bodies_test() {
  let send = fn(_req) { Ok(Response(401, [], "secret response details")) }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )

  client.fetch_project_items(github)
  |> should.equal(
    Error(client.StatusFailed(401, "GitHub authentication failed")),
  )
}

pub fn graphql_rate_limit_is_atomic_test() {
  let send = fn(_req) {
    Ok(Response(
      200,
      [#("retry-after", "7")],
      "{\"data\":{\"viewer\":{\"login\":\"partial\"}},\"errors\":[{\"type\":\"FORBIDDEN\",\"message\":\"try later\"}]}",
    ))
  }
  let assert Ok(github) =
    client.new_with_send(
      "https://github.com/orgs/freshaengineering/projects/3",
      "secret",
      send,
    )

  client.fetch_project_items(github)
  |> should.equal(
    Error(client.RateLimited("GitHub GraphQL rate limit exceeded", 7000)),
  )
}

fn project_page(
  nodes: String,
  has_next_page: Bool,
  end_cursor: String,
) -> String {
  "{\"data\":{\"viewer\":{\"login\":\"benediktms\"},\"owner\":{\"projectV2\":{\"id\":\"PROJECT-1\",\"items\":{\"nodes\":"
  <> nodes
  <> ",\"pageInfo\":{\"hasNextPage\":"
  <> bool_json(has_next_page)
  <> ",\"endCursor\":"
  <> end_cursor
  <> "}}}}}}"
}

fn request_ids_decoder() -> decode.Decoder(List(String)) {
  decode.field(
    "variables",
    field_decoder("ids", decode.list(decode.string)),
    decode.success,
  )
}

fn field_decoder(
  name: String,
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.field(name, decoder, decode.success)
}

fn node_item(id: String, number: Int) -> String {
  "{\"__typename\":\"ProjectV2Item\","
  <> string.drop_start(issue_item(id, number), 1)
}

fn issue_item(id: String, number: Int) -> String {
  "{\"id\":\""
  <> id
  <> "\",\"type\":\"ISSUE\",\"updatedAt\":\"2026-09-07T12:01:00Z\",\"project\":{\"id\":\"PROJECT-1\"},\"status\":{\"name\":\"Todo\"},\"priority\":{\"name\":\"P1\"},\"content\":{\"id\":\"ISSUE-"
  <> int_to_string(number)
  <> "\",\"number\":"
  <> int_to_string(number)
  <> ",\"title\":\"Fix it\",\"body\":\"Details\",\"state\":\"OPEN\",\"url\":\"https://github.com/acme/widgets/issues/"
  <> int_to_string(number)
  <> "\",\"createdAt\":\"2026-09-07T12:00:00Z\",\"updatedAt\":\"2026-09-07T12:01:00Z\",\"repository\":{\"nameWithOwner\":\"acme/widgets\"},\"assignees\":{\"nodes\":[{\"id\":\"USER-2\",\"login\":\"zebra\"},{\"id\":\"USER-1\",\"login\":\"alpha\"}],\"pageInfo\":{\"hasNextPage\":false}},\"labels\":{\"nodes\":[{\"name\":\"Bug\"}],\"pageInfo\":{\"hasNextPage\":false}},\"blockedBy\":{\"nodes\":[{\"id\":\"ISSUE-6\",\"number\":6,\"state\":\"OPEN\",\"url\":\"https://github.com/acme/widgets/issues/6\",\"repository\":{\"nameWithOwner\":\"acme/widgets\"},\"projectItems\":{\"nodes\":[{\"id\":\"BLOCKER-ITEM\",\"project\":{\"id\":\"PROJECT-1\"},\"status\":{\"name\":\"Done\"}}],\"pageInfo\":{\"hasNextPage\":false}}}],\"pageInfo\":{\"hasNextPage\":false}}}}"
}

fn bool_json(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn int_to_string(value: Int) -> String {
  value |> string.inspect
}
