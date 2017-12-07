%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2017, Tony Rogvall
%%% @doc
%%%    Open and manage a palette gear device
%%% @end
%%% Created : 12 Jan 2017 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(egear_server).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/0, stop/0]).
-export([json_command/2]).
-export([json_command/3]).

-export([subscribe/1,subscribe/2]).
-export([unsubscribe/2]).

-export([make_leds_command/1]).
-export([get_layout/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("egear.hrl").

%% type (t) parameter
-define(TYPE_SCREEN, 0).
-define(TYPE_BUTTON, 1).
-define(TYPE_DIAL,   2).
-define(TYPE_SLIDER, 3).

%% -define(debug(Fmt,Args), io:format((Fmt)++"\n", (Args))).
-define(debug(Fmt,Args), ok).

-record(subscription,
	{
	  pid,
	  mon,
	  pattern
	}).


-record(index,
	{
	  i :: integer(),
	  t :: item_type(),
	  u :: string()
	}).
%%
%% Relative screen_orientaion = 2!
%% SCREEN array [Right,Down,Left]
%% BUTTON array [Right,Down,Left]
%% DIAL array [Right,Down,Left]
%% SLIDER array = [UpRight,Right,DownRight,DownLeft,Left]
%%

-record(state, 
	{
	  device :: string(),
	  uart   :: port(),
	  baud_rate = 115200 :: integer(),
	  retry_interval = 5000 :: integer(),
	  retry_timer :: reference(),
	  layout :: #layout{},
	  index_list :: [#index{}],
	  config :: [{Unique::string(),color,color()}],
	  screen = undefined, %% screen to set at startup
	  subs = []
	}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

stop() ->
    gen_server:stop(?SERVER).

%%--------------------------------------------------------------------
%% @doc
%% Subscribe to egear events.
%%
%% @end
%%--------------------------------------------------------------------
-spec subscribe(Pid::pid(), Pattern::[{atom(),string()}]) ->
		       {ok,reference()} | {error, Error::term()}.
subscribe(Pid, Pattern) ->
    gen_server:call(Pid, {subscribe,self(),Pattern}).

%%--------------------------------------------------------------------
%% @doc
%% Subscribe to egear events.
%%
%% @end
%%--------------------------------------------------------------------
-spec subscribe(Pid::pid()) -> {ok,reference()} | {error, Error::term()}.
subscribe(Pid) ->
    gen_server:call(Pid, {subscribe,self(),[]}).

%%--------------------------------------------------------------------
%% @doc
%% Unsubscribe from egear events.
%%
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(Pid::pid(), Ref::reference()) -> ok | {error, Error::term()}.
unsubscribe(Pid, Ref) ->
    gen_server:call(Pid, {unsubscribe,Ref}).

-spec json_command(Pid::pid(), Command::json()) -> ok | {error, Error::term()}.
json_command(Pid,Command) ->
    gen_server:call(Pid, {command, Command}).

-spec json_command(Pid::pid(), Command::json(),Data::binary()) ->
			  ok | {error, Error::term()}.
json_command(Pid,Command,Data) ->
    gen_server:call(Pid,{command, Command, Data}).

-spec get_layout(Pid::pid()) -> {ok,Layout::#layout{}}.

get_layout(Pid) ->
    gen_server:call(Pid,get_layout).
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Options) ->
    Device = case application:get_env(egear, device) of
		 undefined ->
		     proplists:get_value(device, Options);
		 {ok,D} -> D
	     end,
    DefaultBaudRate = (#state{})#state.baud_rate,
    BaudRate = case application:get_env(egear, baud_rate) of
		   undefined ->
		       proplists:get_value(baud_rate, Options, 
					   DefaultBaudRate);
		   {ok,BR} -> BR
	       end,
    DefaultRetryInterval = (#state{})#state.retry_interval,
    RetryInterval = case application:get_env(egear, retry_interval) of
			undefined ->
			    proplists:get_value(retry_interval, Options, 
						DefaultRetryInterval);
			{ok,RI} -> RI
		    end,
    Config = case application:get_env(egear, map) of
		 undefined -> [];
		 {ok,M} ->
		     [{string:trim(U),K,V}||{U,K,V}<-M]
	     end,
    Screen = case application:get_env(egeat, screen) of
		 undefined -> undefined;
		 {ok,Scr} -> Scr
	     end,
    S = #state { device = Device,
		 retry_interval = RetryInterval,
		 baud_rate = BaudRate,
		 config = Config,
		 screen = Screen
	       },
    case open(S) of
	{ok, S1} -> {ok, S1};
	{Error, _S1} -> {stop, Error}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({command, Command}, _From, S) ->
    {Reply,S1} = send_command_(Command, S),
    {reply, Reply, S1};
handle_call({command, Command,Data}, _From, S) ->
    {Reply,S1} = send_command_(Command,Data,S),
    {reply, Reply, S1};
handle_call({subscribe,Pid,Pattern},_From,S=#state { subs=Subs}) ->
    Mon = erlang:monitor(process, Pid),
    Subs1 = [#subscription { pid = Pid, mon = Mon, pattern = Pattern}|Subs],
    {reply, {ok,Mon}, S#state { subs = Subs1}};
handle_call({unsubscribe,Ref},_From,S) ->
    erlang:demonitor(Ref),
    S1 = remove_subscription(Ref,S),
    {reply, ok, S1};
handle_call(get_layout,_From,S) ->
    {reply, {ok,S#state.layout}, S};
handle_call(stop, _From, S) ->
    uart:close(S#state.uart),
    {stop, normal, ok, S#state { uart=undefined }};
handle_call(_Request, _From, S) ->
    {reply, {error,bad_request}, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({uart,U,Data}, S) when U =:= S#state.uart ->
    try exo_json:decode_string(Data) of
	{ok,Term} ->
	    S1 = handle_event(Term, S),
	    {noreply, S1}
    catch
	error:_Error ->
	    ?debug("handle_info: error=~p, data=~p", [_Error,Data]),
	    {noreply, S}
    end;
handle_info({uart_error,U,Reason}, S) when S#state.uart =:= U ->
    if Reason =:= enxio ->
	    ?debug("maybe unplugged?", []),
	    {noreply, reopen(S)};
       true ->
	    lager:warning("uart error=~p", [Reason]),
	    {noreply, S}
    end;
handle_info({uart_closed,U}, S) when U =:= S#state.uart ->
    lager:info("uart_closed: reopen in ~w",[S#state.retry_interval]),
    S1 = reopen(S),
    {noreply, S1};
handle_info({timeout,TRef,reopen},S) 
  when TRef =:= S#state.retry_timer ->
    case open(S#state { retry_timer = undefined }) of
	{ok, S1} ->
	    {noreply, S1};
	{Error, S1} ->
	    {stop, Error, S1}
    end;
handle_info({'DOWN',Ref,process,_Pid,_Reason},S) ->
    lager:debug("handle_info: subscriber ~p terminated: ~p", 
		[_Pid, _Reason]),
    S1 = remove_subscription(Ref,S),
    {noreply, S1};
handle_info(_Info, S) ->
    ?debug("handle_info: ~p", [_Info]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _S) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_command_(Command, S) ->
    CData = exo_json:encode(Command),
    Reply = uart:send(S#state.uart, CData),
    {Reply,S}.

send_command_(Command, Data, S) ->
    CData = exo_json:encode(Command),
    case uart:send(S#state.uart, CData) of
	ok ->
	    Reply = uart:send(S#state.uart, Data),
	    {Reply,S};
	Error ->
	    {Error,S}
    end.

handle_event({struct,[{"in",{array,Input}}]}, S) ->
    handle_input(Input, S);
handle_event({struct,[{"l", Layout}]}, S) ->
    {L,Is} = decode_layout(Layout,[]),
    S1 = match_layout(L, Is, S),
    emit_unit_and_index(Is),
    S1#state { layout = L, index_list = Is };
handle_event(_Event, S) ->
    S.

handle_input([{struct,Input} | Is], S) ->
    S1 = handle_inp(Input, S),
    handle_input(Is,S1);
handle_input([], S) ->
    S.

handle_inp(Input, S) when S#state.index_list =/= undefined ->
    ?debug("input ~p\n", [Input]),
    case Input of
	[{"i",Index},{"v",{array,[Press,Backward,Forward,Value,
				  _R1,_R2,_R3,_R4]}}] ->
	    case lists:keyfind(Index,#index.i,S#state.index_list) of
		false ->
		    io:format("device index=~w not found\n", [Index]),
		    S;
		#index{t=slider,u=Unique} ->
		    send_event(S#state.subs,
			       [{type,slider},
				{index,Index},
				{id,Unique},
				{value,Press}]),
		    S;
		#index{t=button,u=Unique} ->
		    send_event(S#state.subs,
			       [{type,button},
				{index,Index},
				{id,Unique},
				{state,Press}
			       ]),
		    S;
		#index{t=dial,u=Unique} ->
		    Dir = if Forward =:= 1 -> 1;
			     Backward =:= 1 -> -1;
			     true -> none
			  end,
		    send_event(S#state.subs,
			       [{type,dial},
				{index,Index},
				{id,Unique},
				{direction,Dir},
				{state,Press},
				{value,Value}]),
		    S;
		_ ->
		    S
	    end;
	_ ->
	    S
    end;
handle_inp(_Input, S) ->
    S.

send_event([#subscription{pid=Pid,mon=Ref,pattern=Pattern}|Tail], Event) ->
    case match_event(Pattern, Event) of
	true ->
	    ?debug("Send event ~p", [Event]),
	    Pid ! {egear_event,Ref,Event};
	false ->
	    ?debug("Ignore event ~p", [Event]),
	    false
    end,
    send_event(Tail,Event);
send_event([],_Event) ->
    ok.

match_event([], _) -> true;
match_event([{Key,ValuePat}|Kvs],Event) ->
    case lists:keyfind(Key, 1, Event) of
	{Key,ValuePat} -> match_event(Kvs, Event);
	_ -> false
    end.

%% emit unit/index mapping when device is attached
emit_unit_and_index([#index{i=I,u=U,t=T}|Is]) ->
    io:format("index:~w, unit=~s, type=~s\n", [I,U,T]),
    emit_unit_and_index(Is);
emit_unit_and_index([]) ->
    ok.

match_layout(_Layout,Is,S) ->
    match_index_list(Is, S).

match_index_list([#index{i=I,u=U}|Is], S) ->
    case lists:keyfind(U, 1, S#state.config) of
	{U,color,RGB} ->
	    Command = make_leds_command([{I,0,RGB}]),
	    {_Reply,S1} = send_command_(Command,S),
	    match_index_list(Is, S1);
	_ ->
	    match_index_list(Is, S)
    end;
match_index_list([],S) ->
    S.

decode_layout({struct,[{"u",Unique},
		       {"i",Index},
		       {"t",Type},
		       {"c",{array,As}}]}, Conf) ->
    {Array,Conf1} = decode_layout_(As,[],Conf),
    U = string:trim(Unique),
    T = case Type of
	    ?TYPE_SCREEN -> screen;
	    ?TYPE_BUTTON -> button;
	    ?TYPE_DIAL   -> dial;
	    ?TYPE_SLIDER -> slider
	end,
    { #layout { u = U,
		i = Index,
		t = T,
		c = Array }, [#index{i=Index,t=T,u=U}|Conf1]}.

decode_layout_([null | As], Acc, Conf) ->
    decode_layout_(As, [null|Acc], Conf);
decode_layout_([A | As], Acc, Conf) ->
    {L, Conf1} = decode_layout(A, Conf),
    decode_layout_(As, [L|Acc], Conf1);
decode_layout_([], Acc, Conf) ->
    {lists:reverse(Acc), Conf}.

remove_subscription(Ref, S=#state { subs=Subs}) ->
    Subs1 = lists:keydelete(Ref, #subscription.mon, Subs),
    S#state { subs = Subs1 }.

open(S0=#state { device = DeviceName, baud_rate = Baud }) ->
    UartOpts = [{baud, Baud}, {packet, line},
		{csize, 8}, {stopb,1}, {parity,none}, {active, true}],
    case uart:open1(DeviceName, UartOpts) of
	{ok,U} ->
	    ?debug("~s@~w", [DeviceName,Baud]),
	    {R1,S1} = send_command_({struct,[{start,1}]}, S0#state{uart=U}),
	    %% Scr = S1#state.screen,
	    %% if Scr >= 0, Scr =< 15 ->
	    %% send_command_({struct,[{screen_display,Scr}]},S1);
	    %% true ->
	    {R1,S1};
	    %% end;

	{error,E} when E =:= eaccess; E =:= enoent; E =:= ebusy ->
	    if is_integer(S0#state.retry_interval), 
	       S0#state.retry_interval > 0 ->
		    ?debug("~s@~w  error ~w, will try again in ~p msecs.", 
			   [DeviceName,Baud,E,S0#state.retry_interval]),
		    {ok, reopen(S0)};
	       true ->
		    {E, S0}
	    end;
	{error, E} ->
	    {E, S0}
    end.

reopen(S=#state {device = _DeviceName}) ->
    if S#state.uart =/= undefined ->
	    ?debug("closing device ~s", [_DeviceName]),
	    R = uart:close(S#state.uart),
	    ?debug("closed ~p", [R]),
	    R;
       true ->
	    ok
    end,
    T = erlang:max(100, S#state.retry_interval),
    Timer = start_timer(T, reopen),
    S#state { uart=undefined, retry_timer=Timer }.

start_timer(undefined, _Tag) ->
    undefined;
start_timer(infinity, _Tag) ->
    undefined;
start_timer(Time, Tag) ->
    erlang:start_timer(Time,self(),Tag).

-spec make_leds_command(Leds::[{index(),integer(),color()}]) ->
			       json().
make_leds_command(Ls = [{_I,_M,_RGB}|_Leds]) ->
    {struct,[{led,{array,
		   [{struct,[{b,B},{g,G},{i,I},{m,M},{r,R}]} ||
		       {I,M,{R,G,B}} <- Ls]}}]}.
