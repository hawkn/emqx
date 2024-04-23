%%--------------------------------------------------------------------
%% Copyright (c) 2023-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_bridge_mqtt_egress).

-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

-export([
    config/1,
    send/4,
    send_async/5
]).

-type message() :: emqx_types:message() | map().
-type callback() :: {function(), [_Arg]} | {module(), atom(), [_Arg]}.
-type remote_message() :: #mqtt_msg{}.
-type trace_rendered_func() :: {
    fun((RenderResult :: any(), CTX :: map()) -> any()), TraceCTX :: map()
}.

-type egress() :: #{
    local => #{
        topic => emqx_types:topic()
    },
    remote := emqx_bridge_mqtt_msg:msgvars()
}.

-spec config(map()) ->
    egress().
config(#{remote := RC = #{}} = Conf) ->
    Conf#{remote => emqx_bridge_mqtt_msg:parse(RC)}.

-spec send(pid(), trace_rendered_func(), message(), egress()) -> ok.
send(Pid, TraceRenderedFunc, MsgIn, Egress) ->
    try
        emqtt:publish(Pid, export_msg(MsgIn, Egress, TraceRenderedFunc))
    catch
        error:{unrecoverable_error, Reason} ->
            {unrecoverable_error, Reason}
    end.

-spec send_async(pid(), trace_rendered_func(), message(), callback(), egress()) ->
    ok | {ok, pid()}.
send_async(Pid, TraceRenderedFunc, MsgIn, Callback, Egress) ->
    try
        ok = emqtt:publish_async(
            Pid, export_msg(MsgIn, Egress, TraceRenderedFunc), _Timeout = infinity, Callback
        ),
        {ok, Pid}
    catch
        error:{unrecoverable_error, Reason} ->
            {unrecoverable_error, Reason}
    end.

export_msg(Msg, #{remote := Remote}, TraceRenderedFunc) ->
    to_remote_msg(Msg, Remote, TraceRenderedFunc).

-spec to_remote_msg(message(), emqx_bridge_mqtt_msg:msgvars(), trace_rendered_func()) ->
    remote_message().
to_remote_msg(#message{flags = Flags} = Msg, Vars, TraceRenderedFunc) ->
    {EventMsg, _} = emqx_rule_events:eventmsg_publish(Msg),
    to_remote_msg(EventMsg#{retain => maps:get(retain, Flags, false)}, Vars, TraceRenderedFunc);
to_remote_msg(Msg = #{}, Remote, {TraceRenderedFun, TraceRenderedCTX}) ->
    #{
        topic := Topic,
        payload := Payload,
        qos := QoS,
        retain := Retain
    } = emqx_bridge_mqtt_msg:render(Msg, Remote),
    PubProps = maps:get(pub_props, Msg, #{}),
    TraceRenderedFun(
        #{
            qos => QoS,
            retain => Retain,
            topic => Topic,
            props => PubProps,
            payload => Payload
        },
        TraceRenderedCTX
    ),
    #mqtt_msg{
        qos = QoS,
        retain = Retain,
        topic = Topic,
        props = emqx_utils:pub_props_to_packet(PubProps),
        payload = Payload
    }.
