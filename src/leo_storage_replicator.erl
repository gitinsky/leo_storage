%%======================================================================
%%
%% LeoFS Storage
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% LeoFS - Replicator.
%% @doc
%% @end
%%======================================================================
-module(leo_storage_replicator).

-author('Yosuke Hara').

-include("leo_storage.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([replicate/5]).

-type(error_msg_type() :: ?ERR_TYPE_REPLICATE_DATA  |
                          ?ERR_TYPE_DELETE_DATA).

-record(req_params, {
          pid     :: pid(),
          addr_id :: integer(),
          key     :: binary(),
          object  :: #?OBJECT{},
          req_id  :: integer()}).

-record(state, {
          method       :: atom(),
          addr_id      :: integer(),
          key          :: binary(),
          num_of_nodes :: pos_integer(),
          callback     :: function(),
          errors = []  :: list(),
          is_reply = false ::boolean()
         }).


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Replicate an object to local-node and remote-nodes.
%%
-spec(replicate(put|delete, pos_integer(), list(), #?OBJECT{}, function()) ->
             {ok, reference()} | {error, {reference(), any()}}).
replicate(Method, Quorum, Nodes, Object, Callback) ->
    AddrId = Object#?OBJECT.addr_id,
    Key    = Object#?OBJECT.key,
    ReqId  = Object#?OBJECT.req_id,
    NumOfNodes = erlang:length(Nodes),
    From = self(),

    Pid = spawn(fun() ->
                        loop(NumOfNodes, Quorum, [],
                             From, #state{method       = Method,
                                          addr_id      = AddrId,
                                          key          = Key,
                                          num_of_nodes = NumOfNodes,
                                          callback     = Callback,
                                          errors       = [],
                                          is_reply     = false
                                         })
                end),

    ok = replicate_1(Nodes, Pid, AddrId, Key, Object, ReqId),
    receive
        Reply ->
            Callback(Reply)
    after
        ?DEF_REQ_TIMEOUT ->
            Callback({error, timeout})
    end.

%% @private
replicate_1([],_From,_AddrId,_Key,_Object,_ReqId) ->
    ok;
replicate_1([#redundant_node{node = Node,
                             available = true}|Rest],
            From, AddrId, Key, Object, ReqId) when Node == erlang:node() ->
    spawn(fun() ->
                  replicate_fun(local, #req_params{pid     = From,
                                                   addr_id = AddrId,
                                                   key     = Key,
                                                   object  = Object,
                                                   req_id  = ReqId})
          end),
    replicate_1(Rest, From, AddrId, Key, Object, ReqId);

replicate_1([#redundant_node{node = Node,
                             available = true}|Rest],
            From, AddrId, Key, Object, ReqId) ->
    true = rpc:cast(Node, leo_storage_handler_object, put, [From, Object, ReqId]),
    replicate_1(Rest, From, AddrId, Key, Object, ReqId);

replicate_1([#redundant_node{node = Node,
                             available = false}|Rest],
            From, AddrId, Key, Object, ReqId) ->
    erlang:send(From, {error, {Node, nodedown}}),
    replicate_1(Rest, From, AddrId, Key, Object, ReqId).


%% @doc Waiting for messages (replication)
%% @private
loop(0, 0,_ResL,_From, #state{is_reply = true}) ->
    ok;
loop(0, 0, ResL, From, #state{method = Method}) ->
    erlang:send(From, {ok, Method, hd(ResL)});
loop(N, 0, ResL, From, #state{method = Method} = State) ->
    erlang:send(From, {ok, Method, hd(ResL)}),
    loop(N - 1, 0, ResL, From, State#state{is_reply = true});

loop(_, W,_ResL, From, #state{num_of_nodes = N,
                              errors = E}) when (N - W) < length(E) ->
    erlang:send(From, {error, E});

loop(N, W, ResL, From, #state{addr_id = AddrId,
                              key = Key,
                              errors = E} = State) ->
    receive
        {ok, Checksum} ->
            ResL_1 = [Checksum|ResL],
            loop(N-1, W-1, ResL_1, From, State);
        {error, {Node, Cause}} ->
            ok = enqueue(?ERR_TYPE_REPLICATE_DATA, AddrId, Key),
            State_1 = State#state{errors = [{Node, Cause}|E]},
            loop(N-1, W, ResL, From, State_1)
    after
        ?DEF_REQ_TIMEOUT ->
            case (W >= 0) of
                true ->
                    erlang:send(From, {error, timeout});
                false ->
                    void
            end
    end.


%%--------------------------------------------------------------------
%% INTERNAL FUNCTIONS
%%--------------------------------------------------------------------
%% @doc Request a replication-message for local-node.
%%
-spec(replicate_fun(local | atom(), #req_params{}) ->
             {ok, atom()} | {error, atom(), any()}).
replicate_fun(local, #req_params{pid     = Pid,
                                 key     = Key,
                                 object  = Object,
                                 req_id  = ReqId}) ->
    Ref  = make_ref(),
    Ret  = case leo_storage_handler_object:put(Object, Ref) of
               {ok, Ref, Checksum} ->
                   {ok, Checksum};
               {error, Ref, Cause} ->
                   ?warn("replicate_fun/2", "key:~s, node:~w, reqid:~w, cause:~p",
                         [Key, local, ReqId, Cause]),
                   {error, {node(), Cause}}
           end,
    erlang:send(Pid, Ret).


%% @doc Input a message into the queue.
%%
-spec(enqueue(error_msg_type(), integer(), string()) ->
             ok | void).
enqueue(?ERR_TYPE_REPLICATE_DATA = Type,  AddrId, Key) ->
    leo_storage_mq_client:publish(?QUEUE_TYPE_PER_OBJECT, AddrId, Key, Type);
enqueue(?ERR_TYPE_DELETE_DATA = Type,     AddrId, Key) ->
    leo_storage_mq_client:publish(?QUEUE_TYPE_PER_OBJECT, AddrId, Key, Type);
enqueue(_,_,_) ->
    void.
