%% Test helpers: count ETS tables, keep one value across a call, and
%% measure a term as another process would receive it.
-module(decisions_test_ffi).
-export([table_count/0, stash/1, unstash/0, copied_bytes/1]).

table_count() -> length(ets:all()).

stash(Value) ->
    put(decisions_test_stash, Value),
    nil.

unstash() -> get(decisions_test_stash).

%% The bytes a copy of the term takes when sent to another process: the
%% flat size, which does not keep sharing, in words of 8 bytes.
copied_bytes(Term) -> erts_debug:flat_size(Term) * 8.
