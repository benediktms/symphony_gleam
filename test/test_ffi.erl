-module(test_ffi).
-export([putenv/2, unsetenv/1]).

putenv(Name, Value) ->
    true = os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unsetenv(Name) ->
    true = os:unsetenv(binary_to_list(Name)),
    nil.
