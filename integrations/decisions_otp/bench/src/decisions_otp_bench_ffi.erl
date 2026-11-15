%% The machine a scale run ran on, in one line.
-module(decisions_otp_bench_ffi).
-export([machine/0]).

machine() ->
    Arch = erlang:system_info(system_architecture),
    Otp = erlang:system_info(otp_release),
    Schedulers = erlang:system_info(schedulers_online),
    Cores = erlang:system_info(logical_processors_available),
    unicode:characters_to_binary(io_lib:format(
        "~s, OTP ~s, ~p schedulers online, ~p logical processors",
        [Arch, Otp, Schedulers, Cores])).
