import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import symphony/runtime

const api_url = "https://api.github.com/graphql"

const api_version = "2026-03-10"

const nested_page_size = 100

const node_batch_size = 50

const fallback_rate_limit_delay_ms = 60_000

pub type OwnerKind {
  Organization
  User
}

pub type ProjectReference {
  ProjectReference(kind: OwnerKind, owner: String, number: Int)
}

pub type Error {
  InvalidConfig(message: String)
  RequestFailed(message: String)
  StatusFailed(status: Int, message: String)
  InvalidResponse(message: String)
  InvalidPagination(message: String)
  RateLimited(message: String, retry_after_ms: Int)
}

pub type Assignee {
  Assignee(id: String, login: String)
}

pub type Label {
  Label(name: String)
}

pub type ProjectFieldValue {
  ProjectFieldValue(name: String)
}

pub type BlockerProjectItem {
  BlockerProjectItem(
    id: String,
    project_id: String,
    status: Option(ProjectFieldValue),
  )
}

pub type Blocker {
  Blocker(
    id: String,
    number: Int,
    state: String,
    url: String,
    repository: String,
    project_items: List(BlockerProjectItem),
  )
}

pub type IssueContent {
  IssueContent(
    id: String,
    number: Int,
    title: String,
    body: String,
    state: String,
    url: String,
    repository: String,
    created_at: String,
    updated_at: String,
    assignees: List(Assignee),
    labels: List(Label),
    blocked_by: List(Blocker),
  )
}

pub type ProjectItem {
  ProjectItem(
    id: String,
    project_id: String,
    updated_at: String,
    status: Option(ProjectFieldValue),
    priority: Option(ProjectFieldValue),
    issue: IssueContent,
  )
}

pub type Snapshot {
  Snapshot(project_id: String, viewer_login: String, items: List(ProjectItem))
}

pub type Send =
  fn(Request(String)) -> Result(Response(String), httpc.HttpError)

pub opaque type Client {
  Client(reference: ProjectReference, token: String, send: Send)
}

type PageInfo {
  PageInfo(has_next_page: Bool, end_cursor: Option(String))
}

type RawPage {
  RawPage(
    project_id: String,
    viewer_login: String,
    nodes: List(Dynamic),
    page_info: PageInfo,
  )
}

type RawNodes {
  RawNodes(
    project_id: String,
    viewer_login: String,
    nodes: List(Option(Dynamic)),
  )
}

type GraphqlError {
  GraphqlError(message: String, error_type: Option(String))
}

pub fn new(project_url: String, token: String) -> Result(Client, Error) {
  let send = fn(request) {
    httpc.configure()
    |> httpc.verify_tls(True)
    |> httpc.follow_redirects(False)
    |> httpc.timeout(30_000)
    |> httpc.dispatch(request)
  }
  new_with_send(project_url, token, send)
}

pub fn new_with_send(
  project_url: String,
  token: String,
  send: Send,
) -> Result(Client, Error) {
  use reference <- result.try(parse_project_url(project_url))
  case string.trim(token) {
    "" -> Error(InvalidConfig("GitHub token must not be empty"))
    _ -> Ok(Client(reference:, token:, send:))
  }
}

pub fn parse_project_url(url: String) -> Result(ProjectReference, Error) {
  let url = case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1)
    False -> url
  }
  case string.split(url, "/") {
    ["https:", "", "github.com", "orgs", owner, "projects", number] ->
      project_reference(Organization, owner, number)
    ["https:", "", "github.com", "users", owner, "projects", number] ->
      project_reference(User, owner, number)
    _ ->
      Error(InvalidConfig(
        "project_url must be an exact github.com organization or user project URL",
      ))
  }
}

pub fn fetch_project_items(client: Client) -> Result(Snapshot, Error) {
  fetch_pages(client, None, [], [], None, None)
}

pub fn fetch_project_items_by_ids(
  client: Client,
  ids: List(String),
) -> Result(Snapshot, Error) {
  case ids {
    [] -> fetch_nodes_batch(client, [])
    _ -> {
      use snapshot <- result.try(fetch_node_batches(client, ids, [], None, None))
      let Snapshot(project_id:, viewer_login:, items:) = snapshot
      use _ <- result.try(require_unique_items(items))
      let by_id =
        items
        |> list.map(fn(item) { #(item.id, item) })
        |> dict.from_list
      Ok(Snapshot(
        project_id:,
        viewer_login:,
        items: list.filter_map(ids, fn(id) { dict.get(by_id, id) }),
      ))
    }
  }
}

fn project_reference(
  kind: OwnerKind,
  owner: String,
  number: String,
) -> Result(ProjectReference, Error) {
  case string.trim(owner), int.parse(number) {
    "", _ -> Error(InvalidConfig("project_url owner must not be empty"))
    _, Ok(number) if number > 0 -> Ok(ProjectReference(kind:, owner:, number:))
    _, _ ->
      Error(InvalidConfig(
        "project_url project number must be a positive integer",
      ))
  }
}

fn fetch_pages(
  client: Client,
  cursor: Option(String),
  seen_cursors: List(String),
  items: List(ProjectItem),
  expected_project_id: Option(String),
  expected_viewer: Option(String),
) -> Result(Snapshot, Error) {
  let Client(reference:, ..) = client
  let variables =
    json.object([
      #("owner", json.string(reference.owner)),
      #("number", json.int(reference.number)),
      #("after", case cursor {
        Some(value) -> json.string(value)
        None -> json.null()
      }),
    ])
  use document <- result.try(send_query(
    client,
    owner_query(project_items_query, reference.kind),
    variables,
  ))
  use page <- result.try(decode_document(document, project_page_decoder()))
  use page_items <- result.try(decode_project_items(page.nodes, False))
  use _ <- result.try(require_consistent(
    "project",
    expected_project_id,
    page.project_id,
  ))
  use _ <- result.try(require_consistent(
    "viewer",
    expected_viewer,
    page.viewer_login,
  ))
  let items = list.append(items, page_items)
  case page.page_info {
    PageInfo(False, _) -> {
      use _ <- result.try(require_unique_items(items))
      Ok(Snapshot(
        project_id: page.project_id,
        viewer_login: page.viewer_login,
        items:,
      ))
    }
    PageInfo(True, None) ->
      Error(InvalidPagination("project items hasNextPage without endCursor"))
    PageInfo(True, Some("")) ->
      Error(InvalidPagination("project items returned an empty endCursor"))
    PageInfo(True, Some(cursor)) ->
      case list.contains(seen_cursors, cursor) {
        True -> Error(InvalidPagination("project items repeated an endCursor"))
        False ->
          fetch_pages(
            client,
            Some(cursor),
            [cursor, ..seen_cursors],
            items,
            Some(page.project_id),
            Some(page.viewer_login),
          )
      }
  }
}

fn fetch_node_batches(
  client: Client,
  remaining: List(String),
  items: List(ProjectItem),
  expected_project_id: Option(String),
  expected_viewer: Option(String),
) -> Result(Snapshot, Error) {
  case remaining {
    [] ->
      case expected_project_id, expected_viewer {
        Some(project_id), Some(viewer_login) ->
          Ok(Snapshot(project_id:, viewer_login:, items:))
        _, _ -> fetch_nodes_batch(client, [])
      }
    _ -> {
      let batch = list.take(remaining, node_batch_size)
      use snapshot <- result.try(fetch_nodes_batch(client, batch))
      let Snapshot(project_id:, viewer_login:, items: batch_items) = snapshot
      use _ <- result.try(require_consistent(
        "project",
        expected_project_id,
        project_id,
      ))
      use _ <- result.try(require_consistent(
        "viewer",
        expected_viewer,
        viewer_login,
      ))
      fetch_node_batches(
        client,
        list.drop(remaining, node_batch_size),
        list.append(items, batch_items),
        Some(project_id),
        Some(viewer_login),
      )
    }
  }
}

fn fetch_nodes_batch(
  client: Client,
  ids: List(String),
) -> Result(Snapshot, Error) {
  let Client(reference:, ..) = client
  let variables =
    json.object([
      #("owner", json.string(reference.owner)),
      #("number", json.int(reference.number)),
      #("ids", json.array(ids, json.string)),
    ])
  use document <- result.try(send_query(
    client,
    owner_query(project_nodes_query, reference.kind),
    variables,
  ))
  use raw <- result.try(decode_document(document, project_nodes_decoder()))
  let nodes =
    list.filter_map(raw.nodes, fn(node) {
      case node {
        Some(value) -> Ok(value)
        None -> Error(Nil)
      }
    })
  use items <- result.try(decode_project_items(nodes, True))
  use _ <- result.try(validate_project_membership(items, raw.project_id))
  Ok(Snapshot(
    project_id: raw.project_id,
    viewer_login: raw.viewer_login,
    items:,
  ))
}

fn send_query(
  client: Client,
  query: String,
  variables: json.Json,
) -> Result(Dynamic, Error) {
  let Client(token:, send:, ..) = client
  let body =
    json.object([
      #("query", json.string(query)),
      #("variables", variables),
    ])
    |> json.to_string
  let assert Ok(base_request) = request.to(api_url)
  let request =
    base_request
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> token)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_header("user-agent", "symphony-gleam/0.1")
    |> request.set_header("x-github-api-version", api_version)
    |> request.set_body(body)
  use response <- result.try(
    send(request)
    |> result.map_error(fn(error) { RequestFailed(http_error_message(error)) }),
  )
  case response.status >= 200 && response.status < 300 {
    True -> decode_graphql_response(response)
    False ->
      case response_is_rate_limited(response) {
        True ->
          Error(RateLimited(
            "GitHub rate limit exceeded",
            rate_limit_delay_ms(response),
          ))
        False ->
          Error(StatusFailed(response.status, status_message(response.status)))
      }
  }
}

fn decode_graphql_response(
  response: Response(String),
) -> Result(Dynamic, Error) {
  use document <- result.try(
    json.parse(response.body, decode.dynamic)
    |> result.map_error(fn(_) {
      InvalidResponse("GitHub returned invalid JSON")
    }),
  )
  use errors <- result.try(
    decode.run(
      document,
      optional_field_decoder("errors", [], decode.list(graphql_error_decoder())),
    )
    |> result.map_error(fn(_) {
      InvalidResponse("GitHub returned a malformed GraphQL error envelope")
    }),
  )
  case errors {
    [] -> Ok(document)
    _ ->
      case
        graphql_rate_limited(errors)
        || header(response, "retry-after") != None
        || header(response, "x-ratelimit-remaining") == Some("0")
      {
        True ->
          Error(RateLimited(
            "GitHub GraphQL rate limit exceeded",
            rate_limit_delay_ms(response),
          ))
        False -> Error(InvalidResponse("GitHub GraphQL returned errors"))
      }
  }
}

fn decode_document(
  document: Dynamic,
  decoder: decode.Decoder(a),
) -> Result(a, Error) {
  decode.run(document, field_decoder("data", decoder))
  |> result.map_error(fn(_) {
    InvalidResponse("GitHub returned malformed GraphQL data")
  })
}

fn field_decoder(
  name: String,
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.field(name, decoder, decode.success)
}

fn optional_field_decoder(
  name: String,
  default: a,
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.optional_field(name, default, decoder, decode.success)
}

fn project_page_decoder() -> decode.Decoder(RawPage) {
  use viewer_login <- decode.field(
    "viewer",
    field_decoder("login", decode.string),
  )
  use project <- decode.field(
    "owner",
    field_decoder("projectV2", project_page_body_decoder()),
  )
  decode.success(RawPage(
    project_id: project.0,
    viewer_login:,
    nodes: project.1,
    page_info: project.2,
  ))
}

fn project_page_body_decoder() -> decode.Decoder(
  #(String, List(Dynamic), PageInfo),
) {
  use project_id <- decode.field("id", decode.string)
  use nodes <- decode.field(
    "items",
    field_decoder("nodes", decode.list(decode.dynamic)),
  )
  use page_info <- decode.field("items", page_info_decoder())
  decode.success(#(project_id, nodes, page_info))
}

fn project_nodes_decoder() -> decode.Decoder(RawNodes) {
  use viewer_login <- decode.field(
    "viewer",
    field_decoder("login", decode.string),
  )
  use project_id <- decode.field(
    "owner",
    field_decoder("projectV2", field_decoder("id", decode.string)),
  )
  use nodes <- decode.field(
    "nodes",
    decode.list(decode.optional(decode.dynamic)),
  )
  decode.success(RawNodes(project_id:, viewer_login:, nodes:))
}

fn page_info_decoder() -> decode.Decoder(PageInfo) {
  use has_next_page <- decode.field(
    "pageInfo",
    field_decoder("hasNextPage", decode.bool),
  )
  use end_cursor <- decode.field(
    "pageInfo",
    field_decoder("endCursor", decode.optional(decode.string)),
  )
  decode.success(PageInfo(has_next_page:, end_cursor:))
}

fn decode_project_items(
  nodes: List(Dynamic),
  global_nodes: Bool,
) -> Result(List(ProjectItem), Error) {
  use items <- result.try(
    list.try_map(nodes, fn(node) {
      use is_project_item <- result.try(case global_nodes {
        True ->
          decode.run(node, field_decoder("__typename", decode.string))
          |> result.map(fn(name) { name == "ProjectV2Item" })
          |> result.map_error(fn(_) {
            InvalidResponse("GitHub returned a malformed node")
          })
        False -> Ok(True)
      })
      case is_project_item {
        False -> Ok(None)
        True -> decode_project_item(node)
      }
    }),
  )
  Ok(
    list.filter_map(items, fn(item) {
      case item {
        Some(item) -> Ok(item)
        None -> Error(Nil)
      }
    }),
  )
}

fn decode_project_item(item: Dynamic) -> Result(Option(ProjectItem), Error) {
  use item_type <- result.try(
    decode.run(item, field_decoder("type", decode.string))
    |> result.map_error(fn(_) {
      InvalidResponse("GitHub returned a project item without a type")
    }),
  )
  case item_type {
    "ISSUE" -> {
      use overflow <- result.try(
        decode.run(item, nested_overflow_decoder())
        |> result.map_error(fn(_) {
          InvalidResponse("GitHub returned a malformed project item")
        }),
      )
      case overflow {
        True ->
          Error(InvalidPagination(
            "a nested GitHub connection exceeds 100 entries",
          ))
        False ->
          decode.run(item, issue_project_item_decoder())
          |> result.map(Some)
          |> result.map_error(fn(_) {
            InvalidResponse("GitHub returned a malformed project item")
          })
      }
    }
    _ -> Ok(None)
  }
}

fn nested_overflow_decoder() -> decode.Decoder(Bool) {
  use assignees <- decode.field(
    "content",
    field_decoder("assignees", connection_has_next_decoder()),
  )
  use labels <- decode.field(
    "content",
    field_decoder("labels", connection_has_next_decoder()),
  )
  use blocked_by <- decode.field(
    "content",
    field_decoder("blockedBy", connection_has_next_decoder()),
  )
  use blockers <- decode.field(
    "content",
    field_decoder(
      "blockedBy",
      field_decoder("nodes", decode.list(blocker_overflow_decoder())),
    ),
  )
  decode.success(
    assignees || labels || blocked_by || list.any(blockers, fn(value) { value }),
  )
}

fn blocker_overflow_decoder() -> decode.Decoder(Bool) {
  decode.field("projectItems", connection_has_next_decoder(), decode.success)
}

fn connection_has_next_decoder() -> decode.Decoder(Bool) {
  decode.field(
    "pageInfo",
    field_decoder("hasNextPage", decode.bool),
    decode.success,
  )
}

fn issue_project_item_decoder() -> decode.Decoder(ProjectItem) {
  use id <- decode.field("id", decode.string)
  use project_id <- decode.field("project", field_decoder("id", decode.string))
  use updated_at <- decode.field("updatedAt", decode.string)
  use status <- decode.field(
    "status",
    decode.optional(project_field_value_decoder()),
  )
  use priority <- decode.field(
    "priority",
    decode.optional(project_field_value_decoder()),
  )
  use issue <- decode.field("content", issue_decoder())
  decode.success(ProjectItem(
    id:,
    project_id:,
    updated_at:,
    status:,
    priority:,
    issue:,
  ))
}

fn issue_decoder() -> decode.Decoder(IssueContent) {
  use id <- decode.field("id", decode.string)
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  use state <- decode.field("state", decode.string)
  use url <- decode.field("url", decode.string)
  use repository <- decode.field(
    "repository",
    field_decoder("nameWithOwner", decode.string),
  )
  use created_at <- decode.field("createdAt", decode.string)
  use updated_at <- decode.field("updatedAt", decode.string)
  use assignees <- decode.field(
    "assignees",
    bounded_connection_decoder(assignee_decoder(), "issue assignees"),
  )
  use labels <- decode.field(
    "labels",
    bounded_connection_decoder(label_decoder(), "issue labels"),
  )
  use blocked_by <- decode.field(
    "blockedBy",
    bounded_connection_decoder(blocker_decoder(), "issue blockers"),
  )
  decode.success(IssueContent(
    id:,
    number:,
    title:,
    body:,
    state:,
    url:,
    repository:,
    created_at:,
    updated_at:,
    assignees:,
    labels:,
    blocked_by:,
  ))
}

fn project_field_value_decoder() -> decode.Decoder(ProjectFieldValue) {
  field_decoder("name", decode.string)
  |> decode.map(ProjectFieldValue)
}

fn assignee_decoder() -> decode.Decoder(Assignee) {
  use id <- decode.field("id", decode.string)
  use login <- decode.field("login", decode.string)
  decode.success(Assignee(id:, login:))
}

fn label_decoder() -> decode.Decoder(Label) {
  field_decoder("name", decode.string)
  |> decode.map(Label)
}

fn blocker_decoder() -> decode.Decoder(Blocker) {
  use id <- decode.field("id", decode.string)
  use number <- decode.field("number", decode.int)
  use state <- decode.field("state", decode.string)
  use url <- decode.field("url", decode.string)
  use repository <- decode.field(
    "repository",
    field_decoder("nameWithOwner", decode.string),
  )
  use project_items <- decode.field(
    "projectItems",
    bounded_connection_decoder(
      blocker_project_item_decoder(),
      "blocker project items",
    ),
  )
  decode.success(Blocker(
    id:,
    number:,
    state:,
    url:,
    repository:,
    project_items:,
  ))
}

fn blocker_project_item_decoder() -> decode.Decoder(BlockerProjectItem) {
  use id <- decode.field("id", decode.string)
  use project_id <- decode.field("project", field_decoder("id", decode.string))
  use status <- decode.field(
    "status",
    decode.optional(project_field_value_decoder()),
  )
  decode.success(BlockerProjectItem(id:, project_id:, status:))
}

fn bounded_connection_decoder(
  node_decoder: decode.Decoder(a),
  name: String,
) -> decode.Decoder(List(a)) {
  use nodes <- decode.field("nodes", decode.list(node_decoder))
  use has_next_page <- decode.field(
    "pageInfo",
    field_decoder("hasNextPage", decode.bool),
  )
  case has_next_page {
    False -> decode.success(nodes)
    True ->
      decode.failure(
        [],
        expected: name
          <> " to contain at most "
          <> int.to_string(nested_page_size)
          <> " entries",
      )
  }
}

fn graphql_error_decoder() -> decode.Decoder(GraphqlError) {
  use message <- decode.field("message", decode.string)
  use error_type <- decode.optional_field(
    "type",
    None,
    decode.optional(decode.string),
  )
  decode.success(GraphqlError(message:, error_type:))
}

fn graphql_rate_limited(errors: List(GraphqlError)) -> Bool {
  list.any(errors, fn(error) {
    let GraphqlError(message:, error_type:) = error
    string.contains(string.lowercase(message), "rate limit")
    || case error_type {
      Some(value) -> string.uppercase(value) == "RATE_LIMITED"
      None -> False
    }
  })
}

fn response_is_rate_limited(response: Response(String)) -> Bool {
  response.status == 429
  || header(response, "retry-after") != None
  || {
    response.status == 403
    && {
      header(response, "x-ratelimit-remaining") == Some("0")
      || string.contains(string.lowercase(response.body), "rate limit")
    }
  }
}

fn rate_limit_delay_ms(response: Response(String)) -> Int {
  case header_int(response, "retry-after") {
    Some(seconds) if seconds > 0 -> seconds * 1000
    _ ->
      case
        header(response, "x-ratelimit-remaining"),
        header_int(response, "x-ratelimit-reset")
      {
        Some("0"), Some(reset_seconds) ->
          int.max(reset_seconds * 1000 - runtime.unix_ms(), 1000)
        _, _ -> fallback_rate_limit_delay_ms
      }
  }
}

fn header(resp: Response(String), name: String) -> Option(String) {
  case response.get_header(resp, name) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn header_int(resp: Response(String), name: String) -> Option(Int) {
  case header(resp, name) {
    Some(value) -> int.parse(value) |> result.map(Some) |> result.unwrap(None)
    None -> None
  }
}

fn http_error_message(error: httpc.HttpError) -> String {
  case error {
    httpc.InvalidUtf8Response -> "GitHub returned invalid UTF-8"
    httpc.ResponseTimeout -> "GitHub request timed out"
    httpc.FailedToConnect(_, _) -> "could not connect to GitHub"
  }
}

fn status_message(status: Int) -> String {
  case status {
    401 -> "GitHub authentication failed"
    403 -> "GitHub request was forbidden"
    404 -> "GitHub project was not found or is inaccessible"
    _ -> "GitHub returned HTTP " <> int.to_string(status)
  }
}

fn owner_query(query: String, kind: OwnerKind) -> String {
  case kind {
    Organization -> string.replace(query, "__OWNER_ROOT__", "organization")
    User -> string.replace(query, "__OWNER_ROOT__", "user")
  }
}

fn require_consistent(
  name: String,
  expected: Option(String),
  actual: String,
) -> Result(Nil, Error) {
  case expected {
    None -> Ok(Nil)
    Some(expected) if expected == actual -> Ok(Nil)
    Some(_) ->
      Error(InvalidResponse("GitHub changed " <> name <> " during pagination"))
  }
}

fn validate_project_membership(
  items: List(ProjectItem),
  project_id: String,
) -> Result(Nil, Error) {
  case list.all(items, fn(item) { item.project_id == project_id }) {
    True -> Ok(Nil)
    False ->
      Error(InvalidResponse("GitHub returned an item from a different project"))
  }
}

fn require_unique_items(items: List(ProjectItem)) -> Result(Nil, Error) {
  let ids = list.map(items, fn(item) { item.id })
  case list.length(ids) == list.length(list.unique(ids)) {
    True -> Ok(Nil)
    False -> Error(InvalidResponse("GitHub returned a duplicate project item"))
  }
}

const project_items_query = "query SymphonyProjectItems($owner: String!, $number: Int!, $after: String) { viewer { login } owner: __OWNER_ROOT__(login: $owner) { projectV2(number: $number) { id items(first: 50, after: $after) { nodes { ...SymphonyProjectItem } pageInfo { hasNextPage endCursor } } } } } fragment SymphonyProjectItem on ProjectV2Item { id type updatedAt project { id } status: fieldValueByName(name: \"Status\") { ... on ProjectV2ItemFieldSingleSelectValue { name } } priority: fieldValueByName(name: \"Priority\") { ... on ProjectV2ItemFieldSingleSelectValue { name } } content { ... on Issue { id number title body state url createdAt updatedAt repository { nameWithOwner } assignees(first: 100) { nodes { id login } pageInfo { hasNextPage } } labels(first: 100) { nodes { name } pageInfo { hasNextPage } } blockedBy(first: 100) { nodes { id number state url repository { nameWithOwner } projectItems(first: 100, includeArchived: false) { nodes { id project { id } status: fieldValueByName(name: \"Status\") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } pageInfo { hasNextPage } } } pageInfo { hasNextPage } } } } }"

const project_nodes_query = "query SymphonyProjectNodes($owner: String!, $number: Int!, $ids: [ID!]!) { viewer { login } owner: __OWNER_ROOT__(login: $owner) { projectV2(number: $number) { id } } nodes(ids: $ids) { __typename ...SymphonyProjectItem } } fragment SymphonyProjectItem on ProjectV2Item { id type updatedAt project { id } status: fieldValueByName(name: \"Status\") { ... on ProjectV2ItemFieldSingleSelectValue { name } } priority: fieldValueByName(name: \"Priority\") { ... on ProjectV2ItemFieldSingleSelectValue { name } } content { ... on Issue { id number title body state url createdAt updatedAt repository { nameWithOwner } assignees(first: 100) { nodes { id login } pageInfo { hasNextPage } } labels(first: 100) { nodes { name } pageInfo { hasNextPage } } blockedBy(first: 100) { nodes { id number state url repository { nameWithOwner } projectItems(first: 100, includeArchived: false) { nodes { id project { id } status: fieldValueByName(name: \"Status\") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } pageInfo { hasNextPage } } } pageInfo { hasNextPage } } } } }"
