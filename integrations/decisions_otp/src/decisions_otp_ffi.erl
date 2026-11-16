%% Native mechanics for decisions_otp: ETS tables for the store's committed
%% rows and each transaction's buffer, claims that die with their holder,
%% and exception capture. Every decision about what a row means is made in
%% Gleam; this module only moves terms.
%%
%% A key is always a 3-tuple {Tag, A, B} (a Gleam variant with two fields),
%% so that a scan can match {Tag, A, '_'} or {Tag, '_', '_'}.
%%
%% A buffer holds {{write, Key}, {put, Row}}, {{write, Key}, deleted} and
%% {{lock, Lock}, held}.
-module(decisions_otp_ffi).
-export([range/4, due_triggers/3, pending_due/3, stable/2, bump_version/1,
         version/1, new_table/0, new_buffer/0, drop_buffer/1, read/3, read_committed/2,
         scan/3, scan_limit/4, scan_committed/2, scan_kind/3, scan_kind_committed/3,
         scan_until/3, buffer_put/3, buffer_delete/2, buffer_writes/1,
         buffer_heads/2, snapshot/1, restore/2, holds_lock/2, note_lock/2,
         apply_writes/2, all_rows/1, load_rows/2, counter/2, peek_counter/2,
         put_counter/3, claim/2, unclaim/2, attempt/1, reraise/1,
         system_ms/0, monotonic_us/0, mailbox/1, schedulers/0, quiet/0,
         children/1, set_role/1, parent/0, identity/1]).

new_table() ->
    ets:new(decisions_otp_rows, [ordered_set, public, {read_concurrency, true}]).

new_buffer() ->
    ets:new(decisions_otp_buffer, [ordered_set, public]).

drop_buffer(Buffer) ->
    try ets:delete(Buffer) catch error:badarg -> true end,
    nil.

%% -- Reads -----------------------------------------------------------------

read(Table, Buffer, Key) ->
    case ets:lookup(Buffer, {write, Key}) of
        [{_, {put, Row}}] -> {ok, Row};
        [{_, deleted}] -> {error, nil};
        [] -> read_committed(Table, Key)
    end.

read_committed(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Row}] -> {ok, Row};
        [] -> {error, nil}
    end.

%% Rows whose key matches Probe in its first two elements, the buffer's
%% writes over the committed rows, in key order.
scan(Table, Buffer, Probe) ->
    merge(scan_committed(Table, Probe), buffered(Buffer, setelement(3, Probe, '_'))).

%% `scan`, at most Limit rows. Without writes of its own under the probe,
%% it reads only the first Limit committed rows.
scan_limit(Table, Buffer, Probe, Limit) ->
    Pattern = setelement(3, Probe, '_'),
    case buffered(Buffer, Pattern) of
        [] ->
            case ets:select(Table, [{{Pattern, '_'}, [], ['$_']}], max(1, Limit)) of
                {Rows, _} -> Rows;
                '$end_of_table' -> []
            end;
        Buffered ->
            lists:sublist(merge(select(Table, Pattern), Buffered), Limit)
    end.

scan_committed(Table, Probe) ->
    select(Table, setelement(3, Probe, '_')).

%% Rows whose key has Probe's tag, at most Limit of them when Limit > 0.
scan_kind(Table, Buffer, Probe) ->
    Pattern = setelement(2, setelement(3, Probe, '_'), '_'),
    merge(select(Table, Pattern), buffered(Buffer, Pattern)).

scan_kind_committed(Table, Probe, Limit) ->
    Pattern = setelement(2, setelement(3, Probe, '_'), '_'),
    case Limit > 0 of
        true ->
            case ets:select(Table, [{{Pattern, '_'}, [], ['$_']}], Limit) of
                {Rows, _} -> Rows;
                '$end_of_table' -> []
            end;
        false -> select(Table, Pattern)
    end.

%% Committed rows with Probe's tag whose third key element is at most Max.
scan_until(Table, Probe, Max) ->
    Tag = element(1, Probe),
    ets:select(Table, [{{{Tag, '_', '$1'}, '_'}, [{'=<', '$1', Max}], ['$_']}]).

select(Table, Pattern) ->
    ets:select(Table, [{{Pattern, '_'}, [], ['$_']}]).

buffered(Buffer, Pattern) ->
    [{Key, Value} || {{write, Key}, Value} <- ets:select(Buffer, [{{{write, Pattern}, '_'}, [], ['$_']}])].

merge(Committed, []) -> Committed;
merge(Committed, Buffered) ->
    Map = lists:foldl(
        fun({Key, {put, Row}}, Acc) -> maps:put(Key, Row, Acc);
           ({Key, deleted}, Acc) -> maps:remove(Key, Acc)
        end,
        maps:from_list(Committed),
        Buffered),
    lists:sort(maps:to_list(Map)).

%% -- Pages read from an index, committed rows only --------------------------

%% Up to Limit committed rows {Key, Row} whose key has Probe's tag and
%% first field, strictly after After (or from the first when After is
%% none), in key order. It walks the ordered table from the start key, so
%% it costs what it returns.
range(Table, Probe, After, Limit) ->
    Tag = element(1, Probe),
    First = element(2, Probe),
    Start = case After of
        none -> setelement(3, Probe, -1.0e300);
        {some, Key} -> Key
    end,
    walk(Table, Tag, First, ets:next(Table, Start), Limit, []).

walk(_, _, _, _, 0, Acc) -> lists:reverse(Acc);
walk(_, _, _, '$end_of_table', _, Acc) -> lists:reverse(Acc);
walk(Table, Tag, First, Key, Limit, Acc) when element(1, Key) =:= Tag, element(2, Key) =:= First ->
    case ets:lookup(Table, Key) of
        [{_, Row}] -> walk(Table, Tag, First, ets:next(Table, Key), Limit - 1, [{Key, Row} | Acc]);
        [] -> walk(Table, Tag, First, ets:next(Table, Key), Limit, Acc)
    end;
walk(_, _, _, _, _, Acc) -> lists:reverse(Acc).

%% Committed triggers whose backoff has passed, oldest first, at most Limit.
due_triggers(Table, Now, Limit) ->
    Spec = [{{{trigger_key, '_', '_'}, {trigger_row, '_', '_', '_', '$1'}}, [{'=<', '$1', Now}], ['$_']}],
    case ets:select(Table, Spec, max(1, Limit)) of
        {Rows, _} -> Rows;
        '$end_of_table' -> []
    end.

%% Committed pending notices whose backoff has passed, oldest first.
pending_due(Table, Now, Limit) ->
    Spec = [{{{pending_key, '_', '_'}, {pending_row, '$1'}}, [{'=<', '$1', Now}], ['$_']}],
    case ets:select(Table, Spec, max(1, Limit)) of
        {Rows, _} -> Rows;
        '$end_of_table' -> []
    end.

%% -- Commits seen whole ----------------------------------------------------------
%% The owner makes the version odd while it applies a commit and even after.
%% A reader runs Fun between two even readings of the same version, so it saw
%% no commit in part. After 64 tries it gives up and the caller asks the owner.

version(Table) ->
    case ets:lookup(Table, '$version') of
        [{_, V}] -> V;
        [] -> 0
    end.

bump_version(Table) ->
    ets:update_counter(Table, '$version', 1, {'$version', 0}).

stable(Table, Fun) -> stable(Table, Fun, 64).

stable(_, _, 0) -> {error, nil};
stable(Table, Fun, Tries) ->
    Before = version(Table),
    case Before rem 2 of
        1 ->
            erlang:yield(),
            stable(Table, Fun, Tries - 1);
        0 ->
            Value = Fun(),
            case version(Table) of
                Before -> {ok, Value};
                _ ->
                    erlang:yield(),
                    stable(Table, Fun, Tries - 1)
            end
    end.

%% -- Writes, in the buffer --------------------------------------------------

buffer_put(Buffer, Key, Row) ->
    ets:insert(Buffer, {{write, Key}, {put, Row}}),
    nil.

buffer_delete(Buffer, Key) ->
    ets:insert(Buffer, {{write, Key}, deleted}),
    nil.

%% Every write as {Key, {some, Row}} or {Key, none}.
buffer_writes(Buffer) ->
    [{Key, case Value of {put, Row} -> {some, Row}; deleted -> none end}
     || {{write, Key}, Value} <- ets:select(Buffer, [{{{write, '_'}, '_'}, [], ['$_']}])].

%% The rows written under keys with Probe's tag.
buffer_heads(Buffer, Probe) ->
    Pattern = setelement(2, setelement(3, Probe, '_'), '_'),
    [{Key, Row} || {{write, Key}, {put, Row}} <- ets:select(Buffer, [{{{write, Pattern}, '_'}, [], ['$_']}])].

snapshot(Buffer) -> ets:tab2list(Buffer).

restore(Buffer, Rows) ->
    ets:delete_all_objects(Buffer),
    ets:insert(Buffer, Rows),
    nil.

holds_lock(Buffer, Lock) -> ets:member(Buffer, {lock, Lock}).

note_lock(Buffer, Lock) ->
    ets:insert(Buffer, {{lock, Lock}, held}),
    nil.

%% -- The committed table, written only by its owner -------------------------

apply_writes(Table, Writes) ->
    ets:insert(Table, [{Key, Row} || {Key, {some, Row}} <- Writes]),
    lists:foreach(fun({Key, none}) -> ets:delete(Table, Key); (_) -> ok end, Writes),
    nil.

all_rows(Table) -> ets:tab2list(Table).

load_rows(Table, Rows) ->
    ets:insert(Table, Rows),
    nil.

%% -- Sequences ----------------------------------------------------------------

counter(Table, Name) -> ets:update_counter(Table, Name, 1, {Name, 0}).

peek_counter(Table, Name) ->
    case ets:lookup(Table, Name) of
        [{_, Value}] -> Value;
        [] -> 0
    end.

put_counter(Table, Name, Value) ->
    ets:insert(Table, {Name, Value}),
    nil.

%% -- Claims that die with their holder ----------------------------------------

claim(Claims, Key) ->
    Self = self(),
    case ets:insert_new(Claims, {Key, Self}) of
        true -> true;
        false ->
            case ets:lookup(Claims, Key) of
                %% Held by the caller already: not a new claim, so a worker
                %% that keeps a claim while it looks goes on to the next.
                [{_, Self}] -> false;
                [{_, Holder}] ->
                    case is_process_alive(Holder) of
                        true -> false;
                        false ->
                            %% The holder died with its claim: take it over,
                            %% unless another process did first.
                            ets:select_replace(Claims,
                                [{{Key, Holder}, [], [{{{const, Key}, {const, Self}}}]}]) =:= 1
                    end;
                [] -> claim(Claims, Key)
            end
    end.

unclaim(Claims, Key) ->
    ets:delete_object(Claims, {Key, self()}),
    nil.

%% -- Exceptions ----------------------------------------------------------------

attempt(Body) ->
    try {ok, Body()}
    catch Class:Reason:Stack -> {error, {Class, Reason, Stack}}
    end.

reraise({Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack).

%% -- Small facts about the runtime ---------------------------------------------

system_ms() -> erlang:system_time(millisecond).

monotonic_us() -> erlang:monotonic_time(microsecond).

mailbox(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> 0
    end.

schedulers() -> erlang:system_info(schedulers_online).

%% Crash and supervisor reports are noise in a run that kills on purpose.
quiet() ->
    logger:set_primary_config(level, none),
    nil.

%% A supervisor's live children, with the role each put in its process
%% dictionary under decisions_otp_role, or `undefined`.
children(Supervisor) ->
    [{Pid, role(Pid)} || {_, Pid, _, _} <- supervisor:which_children(Supervisor), is_pid(Pid)].

role(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            case lists:keyfind(decisions_otp_role, 1, Dictionary) of
                {_, Role} -> {some, Role};
                false -> none
            end;
        undefined -> none
    end.

%% The process that started the caller: a supervised child's supervisor.
parent() ->
    case erlang:process_info(self(), parent) of
        {parent, Pid} when is_pid(Pid) -> Pid;
        _ -> self()
    end.

set_role(Role) ->
    erlang:put(decisions_otp_role, Role),
    nil.

identity(Value) -> Value.
