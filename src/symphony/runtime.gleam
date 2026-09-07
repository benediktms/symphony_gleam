import gleam/dynamic.{type Dynamic}

pub type Port

@external(erlang, "runtime_ffi", "parse_yaml")
pub fn parse_yaml(source: String) -> Result(Dynamic, String)

@external(erlang, "runtime_ffi", "absolute_path")
pub fn absolute_path(path: String) -> String

@external(erlang, "runtime_ffi", "dirname")
pub fn dirname(path: String) -> String

@external(erlang, "runtime_ffi", "join")
pub fn join(left: String, right: String) -> String

@external(erlang, "runtime_ffi", "home")
pub fn home() -> String

@external(erlang, "runtime_ffi", "temp_dir")
pub fn temp_dir() -> String

@external(erlang, "runtime_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "runtime_ffi", "hash_suffix")
pub fn hash_suffix(value: String) -> String

@external(erlang, "runtime_ffi", "mkdir")
pub fn mkdir(path: String) -> Result(Nil, String)

@external(erlang, "runtime_ffi", "is_directory")
pub fn is_directory(path: String) -> Bool

@external(erlang, "runtime_ffi", "remove_tree")
pub fn remove_tree(path: String) -> Result(Nil, String)

@external(erlang, "runtime_ffi", "run_hook")
pub fn run_hook(
  script: String,
  cwd: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "runtime_ffi", "now_ms")
pub fn now_ms() -> Int

@external(erlang, "runtime_ffi", "unix_ms")
pub fn unix_ms() -> Int

@external(erlang, "runtime_ffi", "parse_rfc3339")
pub fn parse_rfc3339(value: String) -> Result(Int, Nil)

@external(erlang, "runtime_ffi", "sleep")
pub fn sleep(milliseconds: Int) -> Nil

@external(erlang, "runtime_ffi", "start_port")
pub fn start_port(
  command: String,
  cwd: String,
  excluded_environment_names: List(String),
) -> Result(Port, String)

@external(erlang, "runtime_ffi", "port_pid")
pub fn port_pid(port: Port) -> String

@external(erlang, "runtime_ffi", "port_send")
pub fn port_send(port: Port, message: String) -> Result(Nil, String)

@external(erlang, "runtime_ffi", "port_read")
pub fn port_read(port: Port, timeout_ms: Int) -> Result(String, String)

@external(erlang, "runtime_ffi", "port_stop")
pub fn port_stop(port: Port) -> Nil

@external(erlang, "runtime_ffi", "halt")
pub fn halt(status: Int) -> Nil
