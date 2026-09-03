import argv
import gleam/io
import gleam/string
import symphony/orchestrator
import symphony/runtime

pub fn main() {
  let argv.Argv(arguments:, ..) = argv.load()
  let workflow_path = case arguments {
    [] -> Ok("./WORKFLOW.md")
    [path] -> Ok(path)
    _ -> Error("usage: symphony [path-to-WORKFLOW.md]")
  }
  case workflow_path {
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
