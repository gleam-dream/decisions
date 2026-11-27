%% Test probes below Gleam: how much work and how many messages a process
%% has.
-module(probe_ffi).
-export([reductions/0, mailbox/0, suspend/1, resume/1]).

%% The reductions the calling process has run so far.
reductions() ->
    {reductions, Count} = erlang:process_info(self(), reductions),
    Count.

%% How many messages wait in the calling process's mailbox.
mailbox() ->
    {message_queue_len, Length} = erlang:process_info(self(), message_queue_len),
    Length.

%% Hold a process still, and let it go again.
suspend(Pid) -> erlang:suspend_process(Pid), nil.
resume(Pid) -> erlang:resume_process(Pid), nil.
