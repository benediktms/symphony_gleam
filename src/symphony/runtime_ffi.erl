-module(runtime_ffi).
-export([parse_yaml/1, absolute_path/1, dirname/1, join/2, home/0, temp_dir/0,
         getenv/1, hash_suffix/1, mkdir/1, is_directory/1, remove_tree/1,
         run_hook/3, now_ms/0, parse_rfc3339/1, sleep/1,
         start_port/3, port_pid/1, port_send/2, port_read/2, port_stop/1, halt/1]).

parse_yaml(Source) ->
    try yamerl_constr:string(Source) of
        [Document] -> {ok, yaml_to_gleam(Document)};
        [] -> {ok, maps:new()};
        _ -> {error, <<"multiple YAML documents are not supported">>}
    catch
        Class:Reason -> {error, iolist_to_binary(io_lib:format("~p: ~p", [Class, Reason]))}
    end.

yaml_to_gleam(null) -> nil;
yaml_to_gleam(Value) when is_binary(Value); is_integer(Value); is_float(Value); is_boolean(Value) -> Value;
yaml_to_gleam(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
yaml_to_gleam(Value) when is_list(Value) ->
    case Value of
        [] -> [];
        [{_, _} | _] -> maps:from_list([{yaml_key(K), yaml_to_gleam(V)} || {K, V} <- Value]);
        _ ->
            case io_lib:printable_unicode_list(Value) of
                true -> unicode:characters_to_binary(Value);
                false -> [yaml_to_gleam(Item) || Item <- Value]
            end
    end;
yaml_to_gleam(Value) -> Value.

yaml_key(Key) when is_binary(Key) -> Key;
yaml_key(Key) when is_list(Key) -> unicode:characters_to_binary(Key);
yaml_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
yaml_key(Key) -> iolist_to_binary(io_lib:format("~p", [Key])).

absolute_path(Path) ->
    Absolute = filename:absname(binary_to_list(Path)),
    unicode:characters_to_binary(filename:join(lists:reverse(lists:foldl(
        fun
            (".", Parts) -> Parts;
            ("..", [Root]) -> [Root];
            ("..", [_Part | Rest]) -> Rest;
            ("..", Parts) -> Parts;
            (Part, Parts) -> [Part | Parts]
        end,
        [],
        filename:split(Absolute)
    )))).
dirname(Path) -> unicode:characters_to_binary(filename:dirname(binary_to_list(Path))).
join(A, B) -> unicode:characters_to_binary(filename:join(binary_to_list(A), binary_to_list(B))).
home() -> unicode:characters_to_binary(os:getenv("HOME", "" )).
temp_dir() -> unicode:characters_to_binary(os:getenv("TMPDIR", "/tmp")).
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of false -> {error, nil}; Value -> {ok, unicode:characters_to_binary(Value)} end.

hash_suffix(Value) ->
    Hex = binary:encode_hex(crypto:hash(sha256, Value), lowercase),
    binary:part(Hex, 0, 16).

mkdir(Path) ->
    case filelib:ensure_path(filename:join(binary_to_list(Path), ".keep")) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

is_directory(Path) -> filelib:is_dir(binary_to_list(Path)).

remove_tree(Path) ->
    case file:del_dir_r(binary_to_list(Path)) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

run_hook(Script, Cwd, Timeout) ->
    Port = open_port({spawn_executable, "/bin/sh"}, [binary, exit_status, use_stdio,
        {args, ["-lc", binary_to_list(Script)]}, {cd, binary_to_list(Cwd)}]),
    collect_hook(Port, erlang:monotonic_time(millisecond) + Timeout, <<>>).

collect_hook(Port, Deadline, Output) ->
    Remaining = erlang:max(Deadline - erlang:monotonic_time(millisecond), 0),
    receive
        {Port, {data, Data}} -> collect_hook(Port, Deadline, truncate(<<Output/binary, Data/binary>>));
        {Port, {exit_status, 0}} -> {ok, Output};
        {Port, {exit_status, Status}} -> {error, iolist_to_binary(io_lib:format("exit=~p output=~s", [Status, Output]))}
    after Remaining ->
        safe_port_close(Port),
        {error, <<"hook timed out">>}
    end.

truncate(Data) when byte_size(Data) > 8192 -> binary:part(Data, byte_size(Data) - 8192, 8192);
truncate(Data) -> Data.

now_ms() -> erlang:monotonic_time(millisecond).

parse_rfc3339(Value) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Value), [{unit, millisecond}]) of
        Millis -> {ok, Millis}
    catch _:_ -> {error, nil}
    end.

sleep(Milliseconds) -> timer:sleep(Milliseconds).

start_port(Command, Cwd, ExcludedEnvironmentNames) ->
    Environment = [{binary_to_list(Name), false} || Name <- ExcludedEnvironmentNames],
    try open_port({spawn_executable, "/bin/bash"}, [binary, exit_status, use_stdio,
            {line, 10485760}, {args, ["-lc", binary_to_list(Command)]},
            {cd, binary_to_list(Cwd)}, {env, Environment}]) of
        Port -> {ok, Port}
    catch Class:Reason -> {error, iolist_to_binary(io_lib:format("~p: ~p", [Class, Reason]))}
    end.

port_pid(Port) ->
    case erlang:port_info(Port, os_pid) of {os_pid, Pid} -> integer_to_binary(Pid); _ -> <<>> end.

port_send(Port, Message) ->
    try erlang:port_command(Port, <<Message/binary, "\n">>) of true -> {ok, nil}
    catch _:_ -> {error, <<"app-server port is closed">>}
    end.

port_read(Port, Timeout) -> port_read(Port, Timeout, <<>>).
port_read(Port, Timeout, Acc) ->
    receive
        {Port, {data, {noeol, Data}}} -> port_read(Port, Timeout, <<Acc/binary, Data/binary>>);
        {Port, {data, {eol, Data}}} -> {ok, <<Acc/binary, Data/binary>>};
        {Port, {exit_status, Status}} -> {error, iolist_to_binary(io_lib:format("port_exit: ~p", [Status]))}
    after Timeout -> {error, <<"response_timeout">>}
    end.

port_stop(Port) -> safe_port_close(Port).

safe_port_close(Port) ->
    try port_close(Port) of
        true -> nil
    catch
        _:_ -> nil
    end.

halt(Status) -> erlang:halt(Status).
