import argv
import gleam/io
import gleam/string
import symphony/orchestrator
import symphony/runtime

pub fn main() {
  let argv.Argv(arguments:, ..) = argv.load()
  case workflow_path(arguments) {
    Error(message) -> {
      io.println(message)
      runtime.halt(2)
    }
    Ok(path) ->
      case orchestrator.run(path) {
        Ok(_) -> Nil
        Error(error) -> {
          io.println(
            "component=symphony startup=failed reason=" <> string.inspect(error),
          )
          runtime.halt(1)
        }
      }
  }
}

pub fn workflow_path(arguments: List(String)) -> Result(String, String) {
  case arguments {
    [] -> Ok("./WORKFLOW.md")
    [path] -> Ok(path)
    _ -> Error("usage: symphony [path-to-WORKFLOW.md]")
  }
}
