import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import symphony/domain.{type Config, type HooksConfig, Config, WorkspaceError}
import symphony/runtime

pub type Workspace {
  Workspace(path: String, workspace_key: String, created_now: Bool)
}

pub fn key(identifier: String) -> String {
  let sanitized =
    identifier
    |> string.to_graphemes
    |> list.map(fn(char) {
      case allowed(char) {
        True -> char
        False -> "_"
      }
    })
    |> string.concat
  case sanitized == identifier {
    True -> sanitized
    False -> sanitized <> "-" <> runtime.hash_suffix(identifier)
  }
}

pub fn create(
  config: Config,
  identifier: String,
) -> Result(Workspace, domain.ServiceError) {
  let Config(workspace_root: root, hooks:, ..) = config
  let root = runtime.absolute_path(root)
  let workspace_key = key(identifier)
  let path = runtime.absolute_path(runtime.join(root, workspace_key))
  use _ <- result.try(ensure_contained(root, path))
  use root_exists <- result.try(exists(root))
  use _ <- result.try(case root_exists {
    False ->
      simplifile.create_directory_all(root)
      |> result.map_error(fn(error) {
        WorkspaceError(simplifile.describe_error(error))
      })
    True -> require_real_directory(root)
  })
  use path_exists <- result.try(exists(path))
  case path_exists {
    True -> {
      use _ <- result.try(require_real_directory(path))
      Ok(Workspace(path, workspace_key, False))
    }
    False -> {
      use _ <- result.try(
        simplifile.create_directory(path)
        |> result.map_error(fn(error) {
          WorkspaceError(simplifile.describe_error(error))
        }),
      )
      use _ <- result.try(run_fatal_hook(
        hooks.after_create,
        hooks,
        path,
        "after_create",
      ))
      Ok(Workspace(path, workspace_key, True))
    }
  }
}

pub fn before_run(
  config: Config,
  workspace: Workspace,
) -> Result(Nil, domain.ServiceError) {
  run_fatal_hook(
    config.hooks.before_run,
    config.hooks,
    workspace.path,
    "before_run",
  )
}

pub fn after_run(
  config: Config,
  workspace: Workspace,
) -> Result(Nil, domain.ServiceError) {
  run_fatal_hook(
    config.hooks.after_run,
    config.hooks,
    workspace.path,
    "after_run",
  )
}

pub fn after_run_for_issue(
  config: Config,
  identifier: String,
) -> Result(Nil, domain.ServiceError) {
  let root = runtime.absolute_path(config.workspace_root)
  let path = runtime.absolute_path(runtime.join(root, key(identifier)))
  use _ <- result.try(ensure_contained(root, path))
  use path_exists <- result.try(exists(path))
  case path_exists {
    False -> Ok(Nil)
    True -> {
      use _ <- result.try(require_real_directory(path))
      after_run(config, Workspace(path, key(identifier), False))
    }
  }
}

pub fn remove(
  config: Config,
  identifier: String,
  on_hook_failure: fn(domain.ServiceError) -> Nil,
) -> Result(Nil, domain.ServiceError) {
  let Config(workspace_root: root, hooks:, ..) = config
  let root = runtime.absolute_path(root)
  let path = runtime.absolute_path(runtime.join(root, key(identifier)))
  use _ <- result.try(ensure_contained(root, path))
  use path_exists <- result.try(exists(path))
  case path_exists {
    False -> Ok(Nil)
    True -> {
      use _ <- result.try(require_real_directory(path))
      case run_fatal_hook(hooks.before_remove, hooks, path, "before_remove") {
        Error(error) -> on_hook_failure(error)
        Ok(_) -> Nil
      }
      runtime.remove_tree(path) |> result.map_error(WorkspaceError)
    }
  }
}

pub fn validate_agent_cwd(
  config: Config,
  workspace: Workspace,
) -> Result(Nil, domain.ServiceError) {
  let root = runtime.absolute_path(config.workspace_root)
  let cwd = runtime.absolute_path(workspace.path)
  use _ <- result.try(ensure_contained(root, cwd))
  case cwd == workspace.path {
    True -> Ok(Nil)
    False -> Error(WorkspaceError("agent cwd does not equal workspace path"))
  }
}

fn allowed(char: String) -> Bool {
  string.contains(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-",
    char,
  )
}

fn ensure_contained(
  root: String,
  child: String,
) -> Result(Nil, domain.ServiceError) {
  case runtime.dirname(child) == root {
    True -> Ok(Nil)
    False -> Error(WorkspaceError("workspace path escapes configured root"))
  }
}

fn exists(path: String) -> Result(Bool, domain.ServiceError) {
  simplifile.exists(path, follow_links: False)
  |> result.map_error(fn(error) {
    WorkspaceError(simplifile.describe_error(error))
  })
}

fn require_real_directory(path: String) -> Result(Nil, domain.ServiceError) {
  case simplifile.is_symlink(path), simplifile.is_directory(path) {
    Ok(False), Ok(True) -> Ok(Nil)
    Ok(True), _ ->
      Error(WorkspaceError("refusing symlink workspace path: " <> path))
    _, Ok(False) ->
      Error(WorkspaceError("workspace path is not a directory: " <> path))
    Error(error), _ | _, Error(error) ->
      Error(WorkspaceError(simplifile.describe_error(error)))
  }
}

fn run_fatal_hook(
  script: Option(String),
  hooks: HooksConfig,
  cwd: String,
  name: String,
) -> Result(Nil, domain.ServiceError) {
  case script {
    None -> Ok(Nil)
    Some(script) -> {
      io.println(
        "component=symphony hook=" <> name <> " status=started cwd=" <> cwd,
      )
      runtime.run_hook(script, cwd, hooks.timeout_ms)
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(reason) {
        WorkspaceError(name <> " failed: " <> reason)
      })
    }
  }
}
