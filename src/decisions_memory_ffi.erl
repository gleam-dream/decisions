%% A mutable table of text for `decisions/memory`. Every value is a binary,
%% so only what a database would hold survives `restart`.
-module(decisions_memory_ffi).
-export([new/0, get/2, put/3, rows/1, restore/2, guarded/2]).

new() -> ets:new(decisions_memory, [set, public]).

get(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

put(Table, Key, Value) ->
    ets:insert(Table, {Key, Value}),
    nil.

rows(Table) -> ets:tab2list(Table).

restore(Table, Rows) ->
    ets:delete_all_objects(Table),
    ets:insert(Table, Rows),
    nil.

%% Run Body; when it returns {error, _} or raises, put every row back.
guarded(Table, Body) ->
    Before = ets:tab2list(Table),
    try Body() of
        {error, _} = Refused ->
            restore(Table, Before),
            Refused;
        Result ->
            Result
    catch
        Class:Reason:Stack ->
            restore(Table, Before),
            erlang:raise(Class, Reason, Stack)
    end.
