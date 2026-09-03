import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import symphony/domain.{
  type ServiceError, type Workflow, MissingWorkflowFile, Workflow,
  WorkflowFrontMatterNotAMap, WorkflowParseError,
}
import symphony/runtime

pub fn load(path: String) -> Result(Workflow, ServiceError) {
  let absolute = runtime.absolute_path(path)
  use source <- result.try(
    simplifile.read(absolute)
    |> result.map_error(fn(_) { MissingWorkflowFile(absolute) }),
  )

  use split <- result.try(split_front_matter(source))
  case split {
    #(None, prompt) ->
      Ok(Workflow(
        config: dynamic.properties([]),
        prompt_template: string.trim(prompt),
        path: absolute,
        directory: runtime.dirname(absolute),
      ))
    #(Some(yaml), prompt) -> {
      use raw <- result.try(
        runtime.parse_yaml(yaml) |> result.map_error(WorkflowParseError),
      )
      case decode.run(raw, decode.dict(decode.string, decode.dynamic)) {
        Error(_) -> Error(WorkflowFrontMatterNotAMap)
        Ok(_) ->
          Ok(Workflow(
            config: raw,
            prompt_template: string.trim(prompt),
            path: absolute,
            directory: runtime.dirname(absolute),
          ))
      }
    }
  }
}

fn split_front_matter(
  source: String,
) -> Result(#(Option(String), String), ServiceError) {
  case string.split(source, "\n") {
    ["---", ..rest] -> find_closing_delimiter(rest, [])
    _ -> Ok(#(None, source))
  }
}

fn find_closing_delimiter(
  lines: List(String),
  yaml: List(String),
) -> Result(#(Option(String), String), ServiceError) {
  case lines {
    [] ->
      Error(WorkflowParseError(
        "front matter is missing its closing --- delimiter",
      ))
    ["---", ..prompt] ->
      Ok(#(
        Some(string.join(list.reverse(yaml), "\n")),
        string.join(prompt, "\n"),
      ))
    [line, ..rest] -> find_closing_delimiter(rest, [line, ..yaml])
  }
}
