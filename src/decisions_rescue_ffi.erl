%% Runs a function and turns a raise into {error, Reason}, for the
%% conformance check of a savepoint whose body raises.
-module(decisions_rescue_ffi).
-export([rescue/1]).

rescue(Body) ->
    try {ok, Body()}
    catch
        _:Reason -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.
