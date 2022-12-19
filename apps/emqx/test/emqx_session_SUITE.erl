%%--------------------------------------------------------------------
%% Copyright (c) 2018-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_session_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

-define(NOW, erlang:system_time(millisecond)).

-type inflight_data_phase() :: wait_ack | wait_comp.

-record(inflight_data, {
    phase :: inflight_data_phase(),
    message :: emqx_types:message(),
    timestamp :: non_neg_integer()
}).

%%--------------------------------------------------------------------
%% CT callbacks
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    emqx_channel_SUITE:set_test_listener_confs(),
    ok = meck:new(
        [emqx_hooks, emqx_metrics, emqx_broker],
        [passthrough, no_history, no_link]
    ),
    ok = meck:expect(emqx_metrics, inc, fun(_) -> ok end),
    ok = meck:expect(emqx_metrics, inc, fun(_K, _V) -> ok end),
    ok = meck:expect(emqx_hooks, run, fun(_Hook, _Args) -> ok end),
    Config.

end_per_suite(_Config) ->
    meck:unload([emqx_broker, emqx_hooks, emqx_metrics]).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% Test cases for session init
%%--------------------------------------------------------------------

t_session_init(_) ->
    Session = emqx_session:init(#{max_inflight => 64}),
    ?assertEqual(#{}, emqx_session:info(subscriptions, Session)),
    ?assertEqual(0, emqx_session:info(subscriptions_cnt, Session)),
    ?assertEqual(infinity, emqx_session:info(subscriptions_max, Session)),
    ?assertEqual(false, emqx_session:info(upgrade_qos, Session)),
    ?assertEqual(0, emqx_session:info(inflight_cnt, Session)),
    ?assertEqual(64, emqx_session:info(inflight_max, Session)),
    ?assertEqual(1, emqx_session:info(next_pkt_id, Session)),
    ?assertEqual(30000, emqx_session:info(retry_interval, Session)),
    ?assertEqual(0, emqx_mqueue:len(emqx_session:info(mqueue, Session))),
    ?assertEqual(0, emqx_session:info(awaiting_rel_cnt, Session)),
    ?assertEqual(100, emqx_session:info(awaiting_rel_max, Session)),
    ?assertEqual(300000, emqx_session:info(await_rel_timeout, Session)),
    ?assert(is_integer(emqx_session:info(created_at, Session))).

%%--------------------------------------------------------------------
%% Test cases for session info/stats
%%--------------------------------------------------------------------

t_session_info(_) ->
    ?assertMatch(
        #{
            subscriptions := #{},
            upgrade_qos := false,
            retry_interval := 30000,
            await_rel_timeout := 300000
        },
        emqx_session:info(session())
    ).

t_session_stats(_) ->
    Stats = emqx_session:stats(session()),
    ?assertMatch(
        #{
            subscriptions_max := infinity,
            inflight_max := 0,
            mqueue_len := 0,
            mqueue_max := 1000,
            mqueue_dropped := 0,
            next_pkt_id := 1,
            awaiting_rel_cnt := 0,
            awaiting_rel_max := 100
        },
        maps:from_list(Stats)
    ).

%%--------------------------------------------------------------------
%% Test cases for sub/unsub
%%--------------------------------------------------------------------

t_subscribe(_) ->
    ok = meck:expect(emqx_broker, subscribe, fun(_, _, _) -> ok end),
    {ok, Session} = emqx_session:subscribe(
        clientinfo(), <<"#">>, subopts(), session()
    ),
    ?assertEqual(1, emqx_session:info(subscriptions_cnt, Session)).

t_is_subscriptions_full_false(_) ->
    Session = session(#{max_subscriptions => infinity}),
    ?assertNot(emqx_session:is_subscriptions_full(Session)).

t_is_subscriptions_full_true(_) ->
    ok = meck:expect(emqx_broker, subscribe, fun(_, _, _) -> ok end),
    Session = session(#{max_subscriptions => 1}),
    ?assertNot(emqx_session:is_subscriptions_full(Session)),
    {ok, Session1} = emqx_session:subscribe(
        clientinfo(), <<"t1">>, subopts(), Session
    ),
    ?assert(emqx_session:is_subscriptions_full(Session1)),
    {error, ?RC_QUOTA_EXCEEDED} =
        emqx_session:subscribe(clientinfo(), <<"t2">>, subopts(), Session1).

t_unsubscribe(_) ->
    ok = meck:expect(emqx_broker, unsubscribe, fun(_) -> ok end),
    Session = session(#{subscriptions => #{<<"#">> => subopts()}}),
    {ok, Session1} = emqx_session:unsubscribe(clientinfo(), <<"#">>, #{}, Session),
    {error, ?RC_NO_SUBSCRIPTION_EXISTED} =
        emqx_session:unsubscribe(clientinfo(), <<"#">>, #{}, Session1).

t_publish_qos0(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Msg = emqx_message:make(clientid, ?QOS_0, <<"t">>, <<"payload">>),
    {ok, [], Session} = emqx_session:publish(clientinfo(), 1, Msg, Session = session()),
    {ok, [], Session} = emqx_session:publish(clientinfo(), undefined, Msg, Session).

t_publish_qos1(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Msg = emqx_message:make(clientid, ?QOS_1, <<"t">>, <<"payload">>),
    {ok, [], Session} = emqx_session:publish(clientinfo(), 1, Msg, Session = session()),
    {ok, [], Session} = emqx_session:publish(clientinfo(), 2, Msg, Session).

t_publish_qos2(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Msg = emqx_message:make(clientid, ?QOS_2, <<"t">>, <<"payload">>),
    {ok, [], Session} = emqx_session:publish(clientinfo(), 1, Msg, session()),
    ?assertEqual(1, emqx_session:info(awaiting_rel_cnt, Session)),
    {ok, Session1} = emqx_session:pubrel(clientinfo(), 1, Session),
    ?assertEqual(0, emqx_session:info(awaiting_rel_cnt, Session1)),
    {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} = emqx_session:pubrel(clientinfo(), 1, Session1).

t_publish_qos2_with_error_return(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    ok = meck:expect(emqx_hooks, run, fun
        ('message.dropped', [Msg, _By, ReasonName]) ->
            self() ! {'message.dropped', ReasonName, Msg},
            ok;
        (_Hook, _Arg) ->
            ok
    end),

    Session = session(#{max_awaiting_rel => 2, awaiting_rel => #{PacketId1 = 1 => ts(millisecond)}}),
    begin
        Msg1 = emqx_message:make(clientid, ?QOS_2, <<"t">>, <<"payload1">>),
        {error, RC1 = ?RC_PACKET_IDENTIFIER_IN_USE} = emqx_session:publish(
            clientinfo(), PacketId1, Msg1, Session
        ),
        receive
            {'message.dropped', Reason1, RecMsg1} ->
                ?assertEqual(Reason1, emqx_reason_codes:name(RC1)),
                ?assertEqual(RecMsg1, Msg1)
        after 1000 ->
            ct:fail(?FUNCTION_NAME)
        end
    end,

    begin
        Msg2 = emqx_message:make(clientid, ?QOS_2, <<"t">>, <<"payload2">>),
        {ok, [], Session1} = emqx_session:publish(clientinfo(), _PacketId2 = 2, Msg2, Session),
        ?assertEqual(2, emqx_session:info(awaiting_rel_cnt, Session1)),
        {error, RC2 = ?RC_RECEIVE_MAXIMUM_EXCEEDED} = emqx_session:publish(
            clientinfo(), _PacketId3 = 3, Msg2, Session1
        ),
        receive
            {'message.dropped', Reason2, RecMsg2} ->
                ?assertEqual(Reason2, emqx_reason_codes:name(RC2)),
                ?assertEqual(RecMsg2, Msg2)
        after 1000 ->
            ct:fail(?FUNCTION_NAME)
        end
    end,
    ok = meck:expect(emqx_hooks, run, fun(_Hook, _Args) -> ok end).

t_is_awaiting_full_false(_) ->
    Session = session(#{max_awaiting_rel => infinity}),
    ?assertNot(emqx_session:is_awaiting_full(Session)).

t_is_awaiting_full_true(_) ->
    Session = session(#{
        max_awaiting_rel => 1,
        awaiting_rel => #{1 => ts(millisecond)}
    }),
    ?assert(emqx_session:is_awaiting_full(Session)).

t_puback(_) ->
    Msg = emqx_message:make(test, ?QOS_1, <<"t">>, <<>>),
    Inflight = emqx_inflight:insert(1, with_ts(wait_ack, Msg), emqx_inflight:new()),
    Session = session(#{inflight => Inflight, mqueue => mqueue()}),
    {ok, Msg, Session1} = emqx_session:puback(clientinfo(), 1, Session),
    ?assertEqual(0, emqx_session:info(inflight_cnt, Session1)).

t_puback_with_dequeue(_) ->
    Msg1 = emqx_message:make(clientid, ?QOS_1, <<"t1">>, <<"payload1">>),
    Inflight = emqx_inflight:insert(1, with_ts(wait_ack, Msg1), emqx_inflight:new()),
    Msg2 = emqx_message:make(clientid, ?QOS_1, <<"t2">>, <<"payload2">>),
    {_, Q} = emqx_mqueue:in(Msg2, mqueue(#{max_len => 10})),
    Session = session(#{inflight => Inflight, mqueue => Q}),
    {ok, Msg1, [{_, Msg3}], Session1} = emqx_session:puback(clientinfo(), 1, Session),
    ?assertEqual(1, emqx_session:info(inflight_cnt, Session1)),
    ?assertEqual(0, emqx_session:info(mqueue_len, Session1)),
    ?assertEqual(<<"t2">>, emqx_message:topic(Msg3)).

t_puback_error_packet_id_in_use(_) ->
    Inflight = emqx_inflight:insert(1, with_ts(wait_comp, undefined), emqx_inflight:new()),
    {error, ?RC_PACKET_IDENTIFIER_IN_USE} =
        emqx_session:puback(clientinfo(), 1, session(#{inflight => Inflight})).

t_puback_error_packet_id_not_found(_) ->
    {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} = emqx_session:puback(clientinfo(), 1, session()).

t_pubrec(_) ->
    Msg = emqx_message:make(test, ?QOS_2, <<"t">>, <<>>),
    Inflight = emqx_inflight:insert(2, with_ts(wait_ack, Msg), emqx_inflight:new()),
    Session = session(#{inflight => Inflight}),
    {ok, Msg, Session1} = emqx_session:pubrec(clientinfo(), 2, Session),
    ?assertMatch(
        [#inflight_data{phase = wait_comp}],
        emqx_inflight:values(emqx_session:info(inflight, Session1))
    ).

t_pubrec_packet_id_in_use_error(_) ->
    Inflight = emqx_inflight:insert(1, with_ts(wait_comp, undefined), emqx_inflight:new()),
    {error, ?RC_PACKET_IDENTIFIER_IN_USE} =
        emqx_session:pubrec(clientinfo(), 1, session(#{inflight => Inflight})).

t_pubrec_packet_id_not_found_error(_) ->
    {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} = emqx_session:pubrec(clientinfo(), 1, session()).

t_pubrel(_) ->
    Session = session(#{awaiting_rel => #{1 => ts(millisecond)}}),
    {ok, Session1} = emqx_session:pubrel(clientinfo(), 1, Session),
    ?assertEqual(#{}, emqx_session:info(awaiting_rel, Session1)).

t_pubrel_error_packetid_not_found(_) ->
    {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} = emqx_session:pubrel(clientinfo(), 1, session()).

t_pubcomp(_) ->
    Inflight = emqx_inflight:insert(1, with_ts(wait_comp, undefined), emqx_inflight:new()),
    Session = session(#{inflight => Inflight}),
    {ok, Session1} = emqx_session:pubcomp(clientinfo(), 1, Session),
    ?assertEqual(0, emqx_session:info(inflight_cnt, Session1)).

t_pubcomp_error_packetid_in_use(_) ->
    Msg = emqx_message:make(test, ?QOS_2, <<"t">>, <<>>),
    Inflight = emqx_inflight:insert(1, {Msg, ts(millisecond)}, emqx_inflight:new()),
    Session = session(#{inflight => Inflight}),
    {error, ?RC_PACKET_IDENTIFIER_IN_USE} = emqx_session:pubcomp(clientinfo(), 1, Session).

t_pubcomp_error_packetid_not_found(_) ->
    {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND} = emqx_session:pubcomp(clientinfo(), 1, session()).

%%--------------------------------------------------------------------
%% Test cases for deliver/retry
%%--------------------------------------------------------------------

t_dequeue(_) ->
    Q = mqueue(#{store_qos0 => true}),
    {ok, Session} = emqx_session:dequeue(clientinfo(), session(#{mqueue => Q})),
    Msgs = [
        emqx_message:make(clientid, ?QOS_0, <<"t0">>, <<"payload">>),
        emqx_message:make(clientid, ?QOS_1, <<"t1">>, <<"payload">>),
        emqx_message:make(clientid, ?QOS_2, <<"t2">>, <<"payload">>)
    ],
    Session1 = lists:foldl(
        fun(Msg, S) ->
            emqx_session:enqueue(clientinfo(), Msg, S)
        end,
        Session,
        Msgs
    ),
    {ok, [{undefined, Msg0}, {1, Msg1}, {2, Msg2}], Session2} =
        emqx_session:dequeue(clientinfo(), Session1),
    ?assertEqual(0, emqx_session:info(mqueue_len, Session2)),
    ?assertEqual(2, emqx_session:info(inflight_cnt, Session2)),
    ?assertEqual(<<"t0">>, emqx_message:topic(Msg0)),
    ?assertEqual(<<"t1">>, emqx_message:topic(Msg1)),
    ?assertEqual(<<"t2">>, emqx_message:topic(Msg2)).

t_deliver_qos0(_) ->
    ok = meck:expect(emqx_broker, subscribe, fun(_, _, _) -> ok end),
    {ok, Session} = emqx_session:subscribe(
        clientinfo(), <<"t0">>, subopts(), session()
    ),
    {ok, Session1} = emqx_session:subscribe(
        clientinfo(), <<"t1">>, subopts(), Session
    ),
    Deliveries = [delivery(?QOS_0, T) || T <- [<<"t0">>, <<"t1">>]],
    {ok, [{undefined, Msg1}, {undefined, Msg2}], Session1} =
        emqx_session:deliver(clientinfo(), Deliveries, Session1),
    ?assertEqual(<<"t0">>, emqx_message:topic(Msg1)),
    ?assertEqual(<<"t1">>, emqx_message:topic(Msg2)).

t_deliver_qos1(_) ->
    ok = meck:expect(emqx_broker, subscribe, fun(_, _, _) -> ok end),
    {ok, Session} = emqx_session:subscribe(
        clientinfo(), <<"t1">>, subopts(#{qos => ?QOS_1}), session()
    ),
    Delivers = [delivery(?QOS_1, T) || T <- [<<"t1">>, <<"t2">>]],
    {ok, [{1, Msg1}, {2, Msg2}], Session1} = emqx_session:deliver(clientinfo(), Delivers, Session),
    ?assertEqual(2, emqx_session:info(inflight_cnt, Session1)),
    ?assertEqual(<<"t1">>, emqx_message:topic(Msg1)),
    ?assertEqual(<<"t2">>, emqx_message:topic(Msg2)),
    {ok, Msg1T, Session2} = emqx_session:puback(clientinfo(), 1, Session1),
    ?assertEqual(Msg1, remove_deliver_flag(Msg1T)),
    ?assertEqual(1, emqx_session:info(inflight_cnt, Session2)),
    {ok, Msg2T, Session3} = emqx_session:puback(clientinfo(), 2, Session2),
    ?assertEqual(Msg2, remove_deliver_flag(Msg2T)),
    ?assertEqual(0, emqx_session:info(inflight_cnt, Session3)).

t_deliver_qos2(_) ->
    ok = meck:expect(emqx_broker, subscribe, fun(_, _, _) -> ok end),
    Delivers = [delivery(?QOS_2, <<"t0">>), delivery(?QOS_2, <<"t1">>)],
    {ok, [{1, Msg1}, {2, Msg2}], Session} =
        emqx_session:deliver(clientinfo(), Delivers, session()),
    ?assertEqual(2, emqx_session:info(inflight_cnt, Session)),
    ?assertEqual(<<"t0">>, emqx_message:topic(Msg1)),
    ?assertEqual(<<"t1">>, emqx_message:topic(Msg2)).

t_deliver_one_msg(_) ->
    {ok, [{1, Msg}], Session} =
        emqx_session:deliver(clientinfo(), [delivery(?QOS_1, <<"t1">>)], session()),
    ?assertEqual(1, emqx_session:info(inflight_cnt, Session)),
    ?assertEqual(<<"t1">>, emqx_message:topic(Msg)).

t_deliver_when_inflight_is_full(_) ->
    Delivers = [delivery(?QOS_1, <<"t1">>), delivery(?QOS_2, <<"t2">>)],
    Session = session(#{inflight => emqx_inflight:new(1)}),
    {ok, Publishes, Session1} = emqx_session:deliver(clientinfo(), Delivers, Session),
    ?assertEqual(1, length(Publishes)),
    ?assertEqual(1, emqx_session:info(inflight_cnt, Session1)),
    ?assertEqual(1, emqx_session:info(mqueue_len, Session1)),
    {ok, Msg1, [{2, Msg2}], Session2} = emqx_session:puback(clientinfo(), 1, Session1),
    ?assertEqual(1, emqx_session:info(inflight_cnt, Session2)),
    ?assertEqual(0, emqx_session:info(mqueue_len, Session2)),
    ?assertEqual(<<"t1">>, emqx_message:topic(Msg1)),
    ?assertEqual(<<"t2">>, emqx_message:topic(Msg2)).

t_enqueue(_) ->
    %% store_qos0 = true
    Session = emqx_session:enqueue(clientinfo(), [delivery(?QOS_0, <<"t0">>)], session()),
    Session1 = emqx_session:enqueue(
        clientinfo(),
        [
            delivery(?QOS_1, <<"t1">>),
            delivery(?QOS_2, <<"t2">>)
        ],
        Session
    ),
    ?assertEqual(3, emqx_session:info(mqueue_len, Session1)).

t_retry(_) ->
    Delivers = [delivery(?QOS_1, <<"t1">>), delivery(?QOS_2, <<"t2">>)],
    %% 0.1s
    RetryIntervalMs = 100,
    Session = session(#{retry_interval => RetryIntervalMs}),
    {ok, Pubs, Session1} = emqx_session:deliver(clientinfo(), Delivers, Session),
    %% 0.2s
    ElapseMs = 200,
    ok = timer:sleep(ElapseMs),
    Msgs1 = [{I, with_ts(wait_ack, emqx_message:set_flag(dup, Msg))} || {I, Msg} <- Pubs],
    {ok, Msgs1T, 100, Session2} = emqx_session:retry(clientinfo(), Session1),
    ?assertEqual(inflight_data_to_msg(Msgs1), remove_deliver_flag(Msgs1T)),
    ?assertEqual(2, emqx_session:info(inflight_cnt, Session2)).

%%--------------------------------------------------------------------
%% Test cases for takeover/resume
%%--------------------------------------------------------------------

t_takeover(_) ->
    ok = meck:expect(emqx_broker, unsubscribe, fun(_) -> ok end),
    Session = session(#{subscriptions => #{<<"t">> => ?DEFAULT_SUBOPTS}}),
    ok = emqx_session:takeover(Session).

t_resume(_) ->
    ok = meck:expect(emqx_broker, subscribe, fun(_, _, _) -> ok end),
    Session = session(#{subscriptions => #{<<"t">> => ?DEFAULT_SUBOPTS}}),
    ok = emqx_session:resume(#{clientid => <<"clientid">>}, Session).

t_replay(_) ->
    Delivers = [delivery(?QOS_1, <<"t1">>), delivery(?QOS_2, <<"t2">>)],
    {ok, Pubs, Session1} = emqx_session:deliver(clientinfo(), Delivers, session()),
    Msg = emqx_message:make(clientid, ?QOS_1, <<"t1">>, <<"payload">>),
    Session2 = emqx_session:enqueue(clientinfo(), Msg, Session1),
    Pubs1 = [{I, emqx_message:set_flag(dup, M)} || {I, M} <- Pubs],
    {ok, ReplayPubs, Session3} = emqx_session:replay(clientinfo(), Session2),
    ?assertEqual(Pubs1 ++ [{3, Msg}], remove_deliver_flag(ReplayPubs)),
    ?assertEqual(3, emqx_session:info(inflight_cnt, Session3)).

t_expire_awaiting_rel(_) ->
    {ok, Session} = emqx_session:expire(clientinfo(), awaiting_rel, session()),
    Timeout = emqx_session:info(await_rel_timeout, Session),
    Session1 = emqx_session:set_field(awaiting_rel, #{1 => Ts = ts(millisecond)}, Session),
    {ok, Timeout, Session2} = emqx_session:expire(clientinfo(), awaiting_rel, Session1),
    ?assertEqual(#{1 => Ts}, emqx_session:info(awaiting_rel, Session2)).

t_expire_awaiting_rel_all(_) ->
    Session = session(#{awaiting_rel => #{1 => 1, 2 => 2}}),
    {ok, Session1} = emqx_session:expire(clientinfo(), awaiting_rel, Session),
    ?assertEqual(#{}, emqx_session:info(awaiting_rel, Session1)).

%%--------------------------------------------------------------------
%% CT for utility functions
%%--------------------------------------------------------------------

t_next_pakt_id(_) ->
    Session = session(#{next_pkt_id => 16#FFFF}),
    Session1 = emqx_session:next_pkt_id(Session),
    ?assertEqual(1, emqx_session:info(next_pkt_id, Session1)),
    Session2 = emqx_session:next_pkt_id(Session1),
    ?assertEqual(2, emqx_session:info(next_pkt_id, Session2)).

t_obtain_next_pkt_id(_) ->
    Session = session(#{next_pkt_id => 16#FFFF}),
    {16#FFFF, Session1} = emqx_session:obtain_next_pkt_id(Session),
    ?assertEqual(1, emqx_session:info(next_pkt_id, Session1)),
    {1, Session2} = emqx_session:obtain_next_pkt_id(Session1),
    ?assertEqual(2, emqx_session:info(next_pkt_id, Session2)).

%% Helper functions
%%--------------------------------------------------------------------

mqueue() -> mqueue(#{}).
mqueue(Opts) ->
    emqx_mqueue:init(maps:merge(#{max_len => 0, store_qos0 => false}, Opts)).

session() -> session(#{}).
session(InitFields) when is_map(InitFields) ->
    maps:fold(
        fun(Field, Value, Session) ->
            emqx_session:set_field(Field, Value, Session)
        end,
        emqx_session:init(#{max_inflight => 0}),
        InitFields
    ).

clientinfo() -> clientinfo(#{}).
clientinfo(Init) ->
    maps:merge(
        #{
            clientid => <<"clientid">>,
            username => <<"username">>
        },
        Init
    ).

subopts() -> subopts(#{}).
subopts(Init) ->
    maps:merge(?DEFAULT_SUBOPTS, Init).

delivery(QoS, Topic) ->
    {deliver, Topic, emqx_message:make(test, QoS, Topic, <<"payload">>)}.

ts(second) ->
    erlang:system_time(second);
ts(millisecond) ->
    erlang:system_time(millisecond).

with_ts(Phase, Msg) ->
    with_ts(Phase, Msg, erlang:system_time(millisecond)).

with_ts(Phase, Msg, Ts) ->
    #inflight_data{
        phase = Phase,
        message = Msg,
        timestamp = Ts
    }.

remove_deliver_flag({Id, Data}) ->
    {Id, remove_deliver_flag(Data)};
remove_deliver_flag(#inflight_data{message = Msg} = Data) ->
    Data#inflight_data{message = remove_deliver_flag(Msg)};
remove_deliver_flag(List) when is_list(List) ->
    lists:map(fun remove_deliver_flag/1, List);
remove_deliver_flag(Msg) ->
    emqx_message:remove_header(deliver_begin_at, Msg).

inflight_data_to_msg({Id, Data}) ->
    {Id, inflight_data_to_msg(Data)};
inflight_data_to_msg(#inflight_data{message = Msg}) ->
    Msg;
inflight_data_to_msg(List) when is_list(List) ->
    lists:map(fun inflight_data_to_msg/1, List).
