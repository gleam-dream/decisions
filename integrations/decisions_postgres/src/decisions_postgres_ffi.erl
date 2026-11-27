%% The few things decisions_postgres needs below pog: ids, a unique
%% savepoint suffix, and a `pgo_notifications` listener for `LISTEN`.
-module(decisions_postgres_ffi).
-export([rescue/1, listener_connected/1, on_raise/2, new_id/0, unique/0, system_ms/0, listen/7, stop_listener/1]).

%% A UUID version 7: 48 bits of Unix milliseconds, then random bits. Ids made
%% later sort later, which keeps the primary key's inserts at one end.
new_id() ->
    Ms = erlang:system_time(millisecond),
    <<RandA:12, RandB:62, _:6>> = crypto:strong_rand_bytes(10),
    <<A:32, B:16, C:16, D:16, E:48>> =
        <<Ms:48, 7:4, RandA:12, 2:2, RandB:62>>,
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
                                   [A, B, C, D, E])).

%% Run Body; when it raises, run Cleanup and raise the same again.
on_raise(Body, Cleanup) ->
    try Body()
    catch Class:Reason:Stack ->
        _ = Cleanup(),
        erlang:raise(Class, Reason, Stack)
    end.

unique() -> erlang:unique_integer([positive]).

system_ms() -> erlang:system_time(millisecond).

%% Start a `pgo_notifications` process linked to the caller, with its own
%% connection outside any pool, and LISTEN on Channel. Notifications reach
%% the caller as `{notification, Pid, Ref, Channel, Payload}`.
listen(Host, Port, Database, User, Password, Ssl, Channel) ->
    Base = #{host => binary_to_list(Host),
             port => Port,
             database => Database,
             user => User,
             trace => false},
    WithSsl = case Ssl of
                  ssl_disabled -> Base;
                  ssl_unverified ->
                      Base#{ssl => true, ssl_options => [{verify, verify_none}]};
                  ssl_verified ->
                      Base#{ssl => true,
                            ssl_options =>
                                [{verify, verify_peer},
                                 {cacerts, public_key:cacerts_get()},
                                 {server_name_indication, binary_to_list(Host)},
                                 {customize_hostname_check,
                                  [{match_fun,
                                    public_key:pkix_verify_hostname_match_fun(https)}]}]}
              end,
    Config = case Password of
                 {some, Secret} -> WithSsl#{password => Secret};
                 none -> WithSsl
             end,
    case pgo_notifications:start_link(Config) of
        {ok, Pid} ->
            try pgo_notifications:listen(Pid, Channel) of
                {ok, _Ref} -> {ok, Pid};
                %% Not connected yet: the process sends LISTEN once it is.
                {eventually, _Ref} -> {ok, Pid};
                error ->
                    stop_listener(Pid),
                    {error, <<"LISTEN was refused">>}
            catch
                Class:Reason ->
                    stop_listener(Pid),
                    {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
            end;
        Other ->
            {error, iolist_to_binary(io_lib:format("~p", [Other]))}
    end.

stop_listener(Pid) ->
    unlink(Pid),
    try gen_statem:stop(Pid) catch _:_ -> ok end,
    nil.

%% Whether a `pgo_notifications` process holds an open connection. Its state
%% is `{connected, #data{conn = #conn{socket = Socket}}}` while connected;
%% pgo 0.20 does not notice a connection closed by the server (it ignores
%% `tcp_closed`), so the socket's port is checked as well.
listener_connected(Pid) ->
    try sys:get_state(Pid, 1000) of
        {connected, Data} ->
            Conn = element(2, Data),
            Socket = element(3, Conn),
            case Socket of
                S when is_port(S) -> erlang:port_info(S) =/= undefined;
                _ -> true
            end;
        _ -> false
    catch _:_ -> false
    end.

%% Run Body; a raise becomes {error, Text}. An exit signal that kills the
%% process is not a raise and is not caught.
rescue(Body) ->
    try {ok, Body()}
    catch Class:Reason ->
        {error, iolist_to_binary(io_lib:format("~p: ~p", [Class, Reason]))}
    end.
