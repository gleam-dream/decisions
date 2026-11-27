%% Collects the reads a model received while `decisions/model.run` runs it.
%% The cell is a public table so that reads made in other processes (an
%% agent's tools) are counted. It is deleted however the model ends, and a
%% read pushed after that is ignored.
-module(decisions_model_ffi).
-export([with_cell/1, push/2]).

with_cell(Body) ->
    Cell = ets:new(decisions_model_reads, [ordered_set, public]),
    try
        Value = Body(Cell),
        Reads = [Ref || {_, Ref} <- ets:tab2list(Cell)],
        {ok, {Value, Reads}}
    catch
        Class:Reason -> {error, describe(Class, Reason)}
    after
        ets:delete(Cell)
    end.

push(Cell, Ref) ->
    try
        ets:insert(Cell, {erlang:unique_integer([monotonic]), Ref})
    catch
        error:badarg -> ok
    end,
    nil.

describe(_Class, #{message := Message}) when is_binary(Message) ->
    Message;
%% A depth of 30 keeps the rendering of a large term (a response body, a
%% state map) small; `decisions/model` cuts the text to its byte bound.
describe(Class, Reason) ->
    unicode:characters_to_binary(io_lib:format("~p: ~P", [Class, Reason, 30])).
