%% Test helpers: count ETS tables, and keep one value across a call.
-module(decisions_test_ffi).
-export([table_count/0, stash/1, unstash/0]).

table_count() -> length(ets:all()).

stash(Value) ->
    put(decisions_test_stash, Value),
    nil.

unstash() -> get(decisions_test_stash).
