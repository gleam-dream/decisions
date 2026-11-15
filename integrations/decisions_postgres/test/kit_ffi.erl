%% Test support below Gleam: the environment, unique numbers, clocks, and
%% running a body with a cleanup whatever it does.
-module(kit_ffi).
-export([offset_new/0, offset_get/1, offset_add/2, claims_new/0, claim/2, unclaim/2, machine/0, once/1, write_file/2, getenv/1, unique/0, monotonic_us/0, ensure/2, read_file/1,
         plain_arguments/0, quiet_pool_shutdown/0, rescue/1]).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

unique() -> erlang:unique_integer([positive]).

monotonic_us() -> erlang:monotonic_time(microsecond).

ensure(Body, Cleanup) ->
    try Body() after Cleanup() end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, nil}
    end.

plain_arguments() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

%% Run Body; a crash becomes an error with its reason as text.
rescue(Body) ->
    try {ok, Body()}
    catch Class:Reason ->
        {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

%% pgo's pool supervisor reports an error each time a pool is stopped
%% while a connection is opening. Every test stops its pool, so drop
%% exactly that report.
quiet_pool_shutdown() ->
    Filter = fun(#{msg := {report, #{label := {supervisor, shutdown_error},
                                     report := Report}}}, _) ->
                     case proplists:get_value(supervisor, Report) of
                         {_, pgo_pool_sup} -> stop;
                         _ -> ignore
                     end;
                (_, _) -> ignore
             end,
    _ = logger:add_primary_filter(decisions_quiet_pool_shutdown, {Filter, nil}),
    nil.

write_file(Path, Text) ->
    ok = filelib:ensure_dir(binary_to_list(Path)),
    ok = file:write_file(Path, Text),
    nil.

%% True the first time it is called with Key on this node, false after.
once(Key) ->
    Counter = case persistent_term:get({?MODULE, Key}, undefined) of
                  undefined ->
                      C = atomics:new(1, []),
                      persistent_term:put({?MODULE, Key}, C),
                      C;
                  C -> C
              end,
    atomics:add_get(Counter, 1, 1) =:= 1.

%% The machine the numbers were measured on.
machine() ->
    Cpu = string:trim(os:cmd("sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m")),
    Mem = string:trim(os:cmd("sysctl -n hw.memsize 2>/dev/null || echo unknown")),
    Os = string:trim(os:cmd("uname -sr")),
    iolist_to_binary(io_lib:format("~s, ~p logical cores, ~s bytes of memory, ~s, OTP ~s",
        [Cpu, erlang:system_info(logical_processors), Mem, Os,
         erlang:system_info(otp_release)])).

%% A store clock offset in milliseconds that every process reads.
offset_new() -> atomics:new(1, [{signed, true}]).
offset_get(Offset) -> atomics:get(Offset, 1).
offset_add(Offset, Ms) -> atomics:add(Offset, 1, Ms), nil.

%% Trigger claims that die with the process holding them: a public table
%% owned by a process that lives as long as the node.
claims_new() ->
    Parent = self(),
    spawn(fun() ->
        Table = ets:new(decisions_test_claims, [set, public]),
        Parent ! {claims, Table},
        receive stop -> ok end
    end),
    receive {claims, Table} -> Table end.

claim(Table, Id) ->
    Me = self(),
    case ets:insert_new(Table, {Id, Me}) of
        true -> true;
        false ->
            case ets:lookup(Table, Id) of
                [{Id, Holder}] when Holder =/= Me ->
                    case is_process_alive(Holder) of
                        true -> false;
                        false ->
                            ets:delete_object(Table, {Id, Holder}),
                            ets:insert_new(Table, {Id, Me})
                    end;
                [{Id, Me}] -> false;
                [] -> ets:insert_new(Table, {Id, Me})
            end
    end.

unclaim(Table, Id) ->
    ets:delete(Table, Id),
    nil.
