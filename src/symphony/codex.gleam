import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import symphony/domain.{type CodexConfig, CodexConfig, CodexError}
import symphony/runtime

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int, total_tokens: Int)
}

pub type AgentEvent {
  AgentEvent(
    event: String,
    timestamp_ms: Int,
    session_id: Option(String),
    codex_app_server_pid: String,
    usage: Option(Usage),
    rate_limits: Option(Dynamic),
    message: String,
  )
}

pub type Session {
  Session(
    port: runtime.Port,
    thread_id: String,
    pid: String,
    next_id: Int,
    config: CodexConfig,
    cwd: String,
  )
}

pub fn start(
  config: CodexConfig,
  cwd: String,
) -> Result(Session, domain.ServiceError) {
  let CodexConfig(
    command:,
    approval_policy:,
    thread_sandbox:,
    read_timeout_ms:,
    ..,
  ) = config
  use port <- result.try(
    runtime.start_port(command, cwd)
    |> result.map_error(fn(message) { CodexError("codex_not_found", message) }),
  )
  let pid = runtime.port_pid(port)
  let initialize =
    json.object([
      #("method", json.string("initialize")),
      #("id", json.int(0)),
      #(
        "params",
        json.object([
          #(
            "clientInfo",
            json.object([
              #("name", json.string("symphony_gleam")),
              #("title", json.string("Symphony Gleam")),
              #("version", json.string("0.1.0")),
            ]),
          ),
        ]),
      ),
    ])
  use _ <- result.try(send(port, initialize))
  use _ <- result.try(wait_response(port, 0, read_timeout_ms))
  use _ <- result.try(send(
    port,
    json.object([
      #("method", json.string("initialized")),
      #("params", json.object([])),
    ]),
  ))
  let thread_start =
    json.object([
      #("method", json.string("thread/start")),
      #("id", json.int(1)),
      #(
        "params",
        json.object([
          #("cwd", json.string(cwd)),
          #("approvalPolicy", dynamic_json(approval_policy)),
          #("sandbox", json.string(thread_sandbox)),
          #("ephemeral", json.bool(True)),
        ]),
      ),
    ])
  use _ <- result.try(send(port, thread_start))
  use response <- result.try(wait_response(port, 1, read_timeout_ms))
  use thread_id <- result.try(
    string_at(response, ["thread", "id"])
    |> result.map_error(fn(_) {
      CodexError("response_error", "thread/start response has no thread id")
    }),
  )
  Ok(Session(port, thread_id, pid, 2, config, cwd))
}

pub fn run_turn(
  session: Session,
  prompt: String,
  on_event: fn(AgentEvent) -> Nil,
) -> Result(Session, domain.ServiceError) {
  let Session(port:, thread_id:, pid:, next_id:, config:, cwd:) = session
  let CodexConfig(approval_policy:, turn_sandbox_policy:, turn_timeout_ms:, ..) =
    config
  let request =
    json.object([
      #("method", json.string("turn/start")),
      #("id", json.int(next_id)),
      #(
        "params",
        json.object([
          #("threadId", json.string(thread_id)),
          #("cwd", json.string(cwd)),
          #("approvalPolicy", dynamic_json(approval_policy)),
          #("sandboxPolicy", sandbox_policy(turn_sandbox_policy, cwd)),
          #(
            "input",
            json.array([prompt], fn(text) {
              json.object([
                #("type", json.string("text")),
                #("text", json.string(text)),
              ])
            }),
          ),
        ]),
      ),
    ])
  use _ <- result.try(send(port, request))
  use response <- result.try(wait_response(
    port,
    next_id,
    config.read_timeout_ms,
  ))
  use turn_id <- result.try(
    string_at(response, ["turn", "id"])
    |> result.map_error(fn(_) {
      CodexError("response_error", "turn/start response has no turn id")
    }),
  )
  let session_id = thread_id <> "-" <> turn_id
  on_event(AgentEvent(
    "session_started",
    runtime.now_ms(),
    Some(session_id),
    pid,
    None,
    None,
    "",
  ))
  use _ <- result.try(stream_turn(
    port,
    session_id,
    pid,
    turn_timeout_ms,
    on_event,
  ))
  Ok(Session(..session, next_id: next_id + 1))
}

pub fn stop(session: Session) -> Nil {
  runtime.port_stop(session.port)
}

fn stream_turn(
  port: runtime.Port,
  session_id: String,
  pid: String,
  timeout_ms: Int,
  on_event: fn(AgentEvent) -> Nil,
) -> Result(Nil, domain.ServiceError) {
  use line <- result.try(
    runtime.port_read(port, timeout_ms)
    |> result.map_error(fn(message) {
      CodexError(
        case message {
          "response_timeout" -> "turn_timeout"
          _ -> "port_exit"
        },
        message,
      )
    }),
  )
  use message <- result.try(parse_message(line))
  let method = string_at(message, ["method"])
  case method {
    Ok("turn/completed") -> {
      let status = string_at(message, ["params", "turn", "status"])
      let event = case status {
        Ok("completed") -> "turn_completed"
        Ok("interrupted") -> "turn_cancelled"
        _ -> "turn_failed"
      }
      on_event(AgentEvent(
        event,
        runtime.now_ms(),
        Some(session_id),
        pid,
        usage(message),
        None,
        status |> result.unwrap("unknown"),
      ))
      case status {
        Ok("completed") -> Ok(Nil)
        Ok("interrupted") ->
          Error(CodexError("turn_cancelled", "turn was interrupted"))
        Ok(value) -> Error(CodexError("turn_failed", value))
        Error(_) -> Error(CodexError("turn_failed", "missing turn status"))
      }
    }
    Ok("item/commandExecution/requestApproval")
    | Ok("item/fileChange/requestApproval")
    | Ok("item/permissions/requestApproval") -> {
      use _ <- result.try(reply_decision(port, message, "decline"))
      on_event(AgentEvent(
        "approval_declined",
        runtime.now_ms(),
        Some(session_id),
        pid,
        None,
        None,
        "safe default policy",
      ))
      stream_turn(port, session_id, pid, timeout_ms, on_event)
    }
    Ok("item/tool/requestUserInput") -> {
      let _ =
        reply_error(
          port,
          message,
          "user input is not supported by this service",
        )
      on_event(AgentEvent(
        "turn_input_required",
        runtime.now_ms(),
        Some(session_id),
        pid,
        None,
        None,
        "",
      ))
      Error(CodexError(
        "turn_input_required",
        "agent requested interactive user input",
      ))
    }
    Ok("item/tool/call") -> {
      use _ <- result.try(reply_error(
        port,
        message,
        "unsupported dynamic tool call",
      ))
      on_event(AgentEvent(
        "unsupported_tool_call",
        runtime.now_ms(),
        Some(session_id),
        pid,
        None,
        None,
        "",
      ))
      stream_turn(port, session_id, pid, timeout_ms, on_event)
    }
    Ok(event) -> {
      case int_at(message, ["id"]) {
        Ok(_) -> {
          use _ <- result.try(reply_error(
            port,
            message,
            "unsupported server request",
          ))
          on_event(AgentEvent(
            "unsupported_tool_call",
            runtime.now_ms(),
            Some(session_id),
            pid,
            None,
            None,
            event,
          ))
          stream_turn(port, session_id, pid, timeout_ms, on_event)
        }
        Error(_) -> {
          let rate_limits = case event {
            "account/rateLimits/updated" ->
              dynamic_at(message, ["params"])
              |> result.map(Some)
              |> result.unwrap(None)
            _ -> None
          }
          on_event(AgentEvent(
            event,
            runtime.now_ms(),
            Some(session_id),
            pid,
            usage(message),
            rate_limits,
            "",
          ))
          stream_turn(port, session_id, pid, timeout_ms, on_event)
        }
      }
    }
    Error(_) -> stream_turn(port, session_id, pid, timeout_ms, on_event)
  }
}

fn wait_response(
  port: runtime.Port,
  id: Int,
  timeout_ms: Int,
) -> Result(Dynamic, domain.ServiceError) {
  use line <- result.try(
    runtime.port_read(port, timeout_ms)
    |> result.map_error(fn(message) { CodexError("response_timeout", message) }),
  )
  use message <- result.try(parse_message(line))
  case int_at(message, ["id"]) {
    Ok(message_id) if message_id == id ->
      case
        dynamic_at(message, ["result"]),
        string_at(message, ["error", "message"])
      {
        Ok(value), _ -> Ok(value)
        _, Ok(error) -> Error(CodexError("response_error", error))
        _, _ -> Error(CodexError("response_error", "malformed response"))
      }
    _ -> wait_response(port, id, timeout_ms)
  }
}

fn parse_message(line: String) -> Result(Dynamic, domain.ServiceError) {
  json.parse(line, decode.dynamic)
  |> result.map_error(fn(error) {
    CodexError(
      "response_error",
      "invalid JSONL message: " <> string.inspect(error),
    )
  })
}

fn send(
  port: runtime.Port,
  message: json.Json,
) -> Result(Nil, domain.ServiceError) {
  runtime.port_send(port, json.to_string(message))
  |> result.map_error(fn(message) { CodexError("port_exit", message) })
}

fn reply_decision(
  port: runtime.Port,
  message: Dynamic,
  decision: String,
) -> Result(Nil, domain.ServiceError) {
  use id <- result.try(
    int_at(message, ["id"])
    |> result.map_error(fn(_) {
      CodexError("response_error", "approval request has no integer id")
    }),
  )
  send(
    port,
    json.object([
      #("id", json.int(id)),
      #("result", json.object([#("decision", json.string(decision))])),
    ]),
  )
}

fn reply_error(
  port: runtime.Port,
  message: Dynamic,
  reason: String,
) -> Result(Nil, domain.ServiceError) {
  use id <- result.try(
    int_at(message, ["id"])
    |> result.map_error(fn(_) {
      CodexError("response_error", "server request has no integer id")
    }),
  )
  send(
    port,
    json.object([
      #("id", json.int(id)),
      #(
        "error",
        json.object([
          #("code", json.int(-32_000)),
          #("message", json.string(reason)),
        ]),
      ),
    ]),
  )
}

fn sandbox_policy(policy: Dynamic, cwd: String) -> json.Json {
  case decode.run(policy, decode.string) {
    Ok("danger-full-access") ->
      json.object([#("type", json.string("dangerFullAccess"))])
    Ok("read-only") ->
      json.object([
        #("type", json.string("readOnly")),
        #("networkAccess", json.bool(False)),
      ])
    Ok(_) ->
      json.object([
        #("type", json.string("workspaceWrite")),
        #("writableRoots", json.array([cwd], json.string)),
        #("networkAccess", json.bool(False)),
      ])
    Error(_) -> dynamic_json(policy)
  }
}

fn dynamic_json(value: Dynamic) -> json.Json {
  case decode.run(value, decode.string) {
    Ok(value) -> json.string(value)
    Error(_) ->
      case decode.run(value, decode.int) {
        Ok(value) -> json.int(value)
        Error(_) ->
          case decode.run(value, decode.float) {
            Ok(value) -> json.float(value)
            Error(_) ->
              case decode.run(value, decode.bool) {
                Ok(value) -> json.bool(value)
                Error(_) ->
                  case decode.run(value, decode.list(decode.dynamic)) {
                    Ok(values) -> json.array(values, dynamic_json)
                    Error(_) ->
                      case
                        decode.run(
                          value,
                          decode.dict(decode.string, decode.dynamic),
                        )
                      {
                        Ok(values) ->
                          values
                          |> dict.to_list
                          |> list.map(fn(entry) {
                            #(entry.0, dynamic_json(entry.1))
                          })
                          |> json.object
                        Error(_) -> json.null()
                      }
                  }
              }
          }
      }
  }
}

fn usage(message: Dynamic) -> Option(Usage) {
  case
    int_at(message, ["params", "tokenUsage", "total", "inputTokens"]),
    int_at(message, ["params", "tokenUsage", "total", "outputTokens"]),
    int_at(message, ["params", "tokenUsage", "total", "totalTokens"])
  {
    Ok(input), Ok(output), Ok(total) -> Some(Usage(input, output, total))
    _, _, _ -> None
  }
}

fn string_at(
  value: Dynamic,
  path: List(String),
) -> Result(String, List(decode.DecodeError)) {
  decode.run(value, decode.at(path, decode.string))
}

fn int_at(
  value: Dynamic,
  path: List(String),
) -> Result(Int, List(decode.DecodeError)) {
  decode.run(value, decode.at(path, decode.int))
}

fn dynamic_at(
  value: Dynamic,
  path: List(String),
) -> Result(Dynamic, List(decode.DecodeError)) {
  decode.run(value, decode.at(path, decode.dynamic))
}
