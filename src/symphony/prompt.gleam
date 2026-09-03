import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import handles
import handles/ctx
import symphony/domain.{
  type BlockerRef, type Issue, BlockerRef, Issue, TemplateParseError,
  TemplateRenderError,
}

pub fn render(
  template: String,
  issue: Issue,
  attempt: Option(Int),
) -> Result(String, domain.ServiceError) {
  let template = case string.trim(template) {
    "" -> "You are working on an issue from the configured tracker."
    value -> value
  }
  use prepared <- result.try(
    result.map_error(handles.prepare(template), fn(error) {
      TemplateParseError(string.inspect(error))
    }),
  )
  use output <- result.try(
    result.map_error(
      handles.run(prepared, issue_context(issue, attempt), []),
      fn(error) { TemplateRenderError(string.inspect(error)) },
    ),
  )
  Ok(string_tree.to_string(output))
}

fn issue_context(issue: Issue, attempt: Option(Int)) -> ctx.Value {
  let Issue(
    id:,
    native_ref:,
    identifier:,
    title:,
    description:,
    priority:,
    state:,
    branch_name:,
    url:,
    assignee_id:,
    labels:,
    blocked_by:,
    dispatchable:,
    created_at:,
    updated_at:,
  ) = issue
  ctx.Dict([
    ctx.Prop(
      "issue",
      ctx.Dict([
        ctx.Prop("id", ctx.Str(id)),
        ctx.Prop("native_ref", option_value(native_ref, dynamic_to_ctx)),
        ctx.Prop("identifier", ctx.Str(identifier)),
        ctx.Prop("title", ctx.Str(title)),
        ctx.Prop("description", option_value(description, ctx.Str)),
        ctx.Prop("priority", option_value(priority, ctx.Int)),
        ctx.Prop("state", ctx.Str(state)),
        ctx.Prop("branch_name", option_value(branch_name, ctx.Str)),
        ctx.Prop("url", option_value(url, ctx.Str)),
        ctx.Prop("assignee_id", option_value(assignee_id, ctx.Str)),
        ctx.Prop("labels", ctx.List(list.map(labels, ctx.Str))),
        ctx.Prop("blocked_by", ctx.List(list.map(blocked_by, blocker_context))),
        ctx.Prop("dispatchable", ctx.Bool(dispatchable)),
        ctx.Prop("created_at", option_value(created_at, ctx.Int)),
        ctx.Prop("updated_at", option_value(updated_at, ctx.Int)),
      ]),
    ),
    ctx.Prop("attempt", option_value(attempt, ctx.Int)),
  ])
}

fn blocker_context(blocker: BlockerRef) -> ctx.Value {
  let BlockerRef(id, identifier, state) = blocker
  ctx.Dict([
    ctx.Prop("id", option_value(id, ctx.Str)),
    ctx.Prop("identifier", option_value(identifier, ctx.Str)),
    ctx.Prop("state", option_value(state, ctx.Str)),
  ])
}

fn option_value(value: Option(a), convert: fn(a) -> ctx.Value) -> ctx.Value {
  case value {
    Some(value) -> convert(value)
    None -> ctx.Str("")
  }
}

fn dynamic_to_ctx(value: Dynamic) -> ctx.Value {
  case decode.run(value, decode.string) {
    Ok(value) -> ctx.Str(value)
    Error(_) ->
      case decode.run(value, decode.int) {
        Ok(value) -> ctx.Int(value)
        Error(_) ->
          case decode.run(value, decode.float) {
            Ok(value) -> ctx.Float(value)
            Error(_) ->
              case decode.run(value, decode.bool) {
                Ok(value) -> ctx.Bool(value)
                Error(_) ->
                  case decode.run(value, decode.list(decode.dynamic)) {
                    Ok(values) -> ctx.List(list.map(values, dynamic_to_ctx))
                    Error(_) ->
                      case
                        decode.run(
                          value,
                          decode.dict(decode.string, decode.dynamic),
                        )
                      {
                        Ok(values) ->
                          ctx.Dict(
                            values
                            |> dict.to_list
                            |> list.map(fn(entry) {
                              ctx.Prop(entry.0, dynamic_to_ctx(entry.1))
                            }),
                          )
                        Error(_) -> ctx.Str("")
                      }
                  }
              }
          }
      }
  }
}
