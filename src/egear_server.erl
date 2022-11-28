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
-export([get_info/2]).

-export([make_leds_command/1]).

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
-define(warning(Fmt,Args),  io:format((Fmt)++"\n", (Args))).
-define(info(Fmt,Args),  io:format((Fmt)++"\n", (Args))).

-record(subscription,
	{
	  pid,
	  mon,
	  pattern
	}).


-record(index,
	{
	  i :: integer(),     %% index
	  t :: item_type(),   %% type
	  u :: string(),      %% unique id
	  v :: term()         %% current value
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
	  layout = null :: null | #layout{},
	  index_list = [] :: [#index{}],
	  version_core = "" :: string(),
	  version_screen = "" :: string(),
	  config :: [{Unique::string(),color,color()}],
	  screen = undefined, %% screen to set at startup
	  xbus = false :: boolean(), %% use xbus publish or not
	  subs = [] :: [#subscription{}]
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

-spec get_info(Pid::pid(),Item::atom()) -> {ok,Layout::#layout{}}.

get_info(Pid,Item) ->
    gen_server:call(Pid,{info,Item}).
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
    ?debug("egear:init: options=~p, env=~p\n", [Options, application:get_all_env(egear)]),
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
    Screen = case application:get_env(egear, screen) of
		 undefined -> undefined;
		 {ok,Scr} -> Scr
	     end,
    Xbus = case application:get_env(egear, xbus) of
	       undefined -> (#state{})#state.xbus;
	       {ok,true} -> xbus:start(), true;
	       {ok,false} -> false
	   end,
    ?debug("egear:init: xbus = ~p\n", [Xbus]),
    S = #state { device = Device,
		 retry_interval = RetryInterval,
		 baud_rate = BaudRate,
		 config = Config,
		 screen = Screen,
		 xbus = Xbus
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
handle_call({info,Item},_From,S) ->
    Result = case Item of
		 layout -> S#state.layout;
		 list   ->
		     L = lists:keysort(#index.i, S#state.index_list),
		     [{I,T,U,V}|| #index{i=I,t=T,u=U,v=V} <-L];
		 core_version -> S#state.version_core;
		 screen_version -> S#state.version_screen;
		 _ -> undefined
	     end,
    {reply, {ok,Result}, S};
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
    try egear_json:decode_string(Data) of
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
	    S1 = disconnect_event(enxio, S),
	    {noreply, reopen(S1)};
       true ->
	    ?warning("uart error=~p", [Reason]),
	    {noreply, S}
    end;
handle_info({uart_closed,U}, S) when U =:= S#state.uart ->
    ?info("uart_closed: reopen in ~w",[S#state.retry_interval]),
    S1 = disconnect_event(closed, S),
    S2 = reopen(S1),
    {noreply, S2};
handle_info({timeout,TRef,reopen},S) 
  when TRef =:= S#state.retry_timer ->
    case open(S#state { retry_timer = undefined }) of
	{ok, S1} ->
	    {noreply, S1};
	{Error, S1} ->
	    {stop, Error, S1}
    end;
handle_info({'DOWN',Ref,process,_Pid,_Reason},S) ->
    ?debug("handle_info: subscriber ~p terminated: ~p", 
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
    CData = egear_json:encode(Command),
    Reply = uart:send(S#state.uart, CData),
    {Reply,S}.

send_command_(Command, Data, S) ->
    CData = egear_json:encode(Command),
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
    {Is1,Added,Deleted} = merge_index(Is, S#state.index_list),
    ?debug("added items = ~p\n", [Added]),
    S1 = match_layout(L, Added, S),
    ?debug("removed items = ~p\n", [Deleted]),
    lists:foreach(fun(I) -> send_connect_event(S,I,enoent) end, Deleted),
    ?debug("new items = ~p\n", [Added]),
    lists:foreach(fun(I) -> send_connect_event(S,I,ok) end, Added),
    %% if first items added, screen MUST be one of them so
    %% set the application icon at that point.
    S3 = if S#state.index_list =:= [], Is1 =/= [] ->
		 Command = {struct,[{send_version,1}]},
		 {_,S2} = send_command_(Command,S1),
		 S2;
	    true ->
		 S1
	 end,
    S3#state { layout = L, index_list = Is1 };
handle_event({struct,[{"version_core",VsnCore},
		      {"version_screen",VsnScreen}|_]}, S) ->
    S1 = S#state {  version_core = VsnCore,
		    version_screen = VsnScreen },
    ?debug("got version core=~p, screen=~p\n", [VsnCore,VsnScreen]),
    %% when version is received this is a trigger to set application screen 
    Screen = S1#state.screen,
    if is_integer(Screen), Screen >= 0, Screen =< 15 ->
	    Command = {struct,[{screen_display,Screen}]},
	    {_,Sx} = send_command_(Command,S1),
	    Sx;
       true ->
	    S1
    end;
handle_event(_Event, S) ->
    ?debug("unhandled event ~p\n", [_Event]),
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
	    case lists:keytake(Index,#index.i,S#state.index_list) of
		false ->
		    io:format("device index=~w not found\n", [Index]),
		    S;
		{value,I=#index{t=slider,u=Unique,v=V0},Is} ->
		    send_slider_event(S, Index, Unique, Press, V0),
		    S#state{index_list=[I#index{v=Press}|Is]};
		{value,I=#index{t=button,u=Unique,v=V0},Is} ->
		    send_button_event(S, Index, Unique, Press, V0),
		    S#state{index_list=[I#index{v=Press}|Is]};
		{value,I=#index{t=dial,u=Unique,v=V0},Is} ->
		    Dir = if Forward  > 0 -> Forward;
			     Backward > 0 -> -Backward;
			     true -> 0
			  end,
		    send_dial_event(S, Index, Unique, Dir, Press, Value, V0),
		    S#state{index_list=[I#index{v={Press,Dir,Value}}|Is]};
		_ ->
		    S
	    end;
	_Inp ->
	    ?debug("unhandled input ~p\n", [_Inp]),
	    S
    end;
handle_inp(_Input, S) ->
    S.


%%
%% xbus slider topic:
%%    egear.slider.<uniq>.<index>.value
%% value: Value (0|255)
%%
send_slider_event(S, Index, Unique, Value, _V0) ->
    if S#state.xbus -> %% send to xbus
	    Path = ["egear.slider",Unique,integer_to_list(Index),"value"],
	    Topic = string:join(Path,"."),
	    xbus:pub(Topic, Value);
       true -> ok
    end,
    if S#state.subs =/= [] ->
	    Props = [{type,slider},{index,Index},{id,Unique},{value,Value}],
	    send_event(S#state.subs,Props);
       true -> ok
    end.
%%
%% xbus slider topic:
%%     egear.button.<uniq>.<index>.state
%% value: State (0|1)
%%
send_button_event(S, Index, Unique, State, _V0) ->
    if S#state.xbus -> %% send to xbus
	    Path = ["egear.button",Unique,integer_to_list(Index),"state"],
	    Topic = string:join(Path,"."),
	    xbus:pub(Topic, State);
       true -> ok
    end,
    if S#state.subs =/= [] ->
	    Props = [{type,button},{index,Index},{id,Unique},{state,State}],
	    send_event(S#state.subs, Props);
       true -> ok
    end.
%%
%% xbus dial topic:
%%     egear.dial.<uniq>.<index>.state
%%     egear.dial.<uniq>.<index>.value
%%     egear.dial.<uniq>.<index>.dir
%% 
%% State = (0|1)
%% Dir   = -CounterClockWiseSteps|ClockWiseSteps
%% Value = 0..255
%%
send_dial_event(S, Index, Unique, Dir, State, Value, V0) ->
    if S#state.xbus -> %% send to xbus
	    T = xbus:timestamp(),
	    {State0,_Dir0,Value0} = 
		case V0 of
		    undefined -> {undefined,undefined,undefined};
		    _ -> V0
		end,
	    Path0 = ["egear.dial",Unique,integer_to_list(Index)],
	    if State =/= State0 ->
		    xbus:pub(string:join(Path0++["state"],"."), State, T);
	       true -> ok
	    end,
	    if Value =/= Value0 ->
		    xbus:pub(string:join(Path0++["value"],"."), Value, T);
	       true -> ok
	    end,
	    xbus:pub(string:join(Path0++["dir"],"."), Dir, T);
       true -> ok
    end,
    if S#state.subs =/= [] ->
	    Props = [{type,dial},{index,Index},{id,Unique},{direction,Dir},
		     {state,State},{value,Value}],
	    send_event(S#state.subs, Props);
       true -> ok
    end.

%%
%% Event to send when item is disconnected from the grid
%% FIXME: when using X bus clear retain for this item
%%

disconnect_event(Reason, S) ->
    lists:foreach(
      fun(I) ->
	      send_connect_event(S, I, Reason)
      end, S#state.index_list),
    S#state { index_list = [], layout = null }.

%%
%% xbus disconnect topic
%%   egear.(dial|button|slider).<uniq>.<index>.connect  value=Reason
%% Reason = ok | string (atom)
%%
send_connect_event(S, #index{t=Type, i=Index, u=Unique}, Reason) ->
    ?debug("send_connect_event: xbus=~p\n", [S#state.xbus]),
    if S#state.xbus ->
	    Path = ["egear",atom_to_list(Type),Unique,integer_to_list(Index),
		    "connect"],
	    Topic = string:join(Path,"."),
	    xbus:pub(Topic, atom_to_list(Reason));
       true -> ok
    end,
    if S#state.subs =/= [] ->
	    Props = [{type,Type},{index,Index},{id,Unique},{connect,Reason}],
	    send_event(S#state.subs, Props);
       true ->
	    ok
    end.

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

merge_index(IndexList,Old) ->
    merge_index(IndexList,[],[],Old).

merge_index([I|Is],New,Acc,Old) ->
    case lists:keytake(I#index.u, #index.u, Old) of
	false ->
	    merge_index(Is,[I|New],Acc,Old);
	{value,J,Old1} ->
	    Index = I#index.i,
	    merge_index(Is,New,[J#index{i=Index}|Acc],Old1)
    end;
merge_index([],New,Acc,Old) ->
    {Acc++New, New, Old}.

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
	    send_command_({struct,[{start,1}]}, S0#state{uart=U});

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
