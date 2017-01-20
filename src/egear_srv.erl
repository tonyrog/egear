%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2017, Tony Rogvall
%%% @doc
%%%    Open and manage a palette gear device
%%% @end
%%% Created : 12 Jan 2017 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(egear_srv).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/0]).
-export([screen_display/1]).
-export([screen_write/2]).
-export([screen_ready/1]).
-export([screen_string/1]).
-export([screen_orientation/1]).
-export([set_hidmap/1]).
-export([set_joymap/1]).
-export([set_midimap/1]).
-exprot([set_leds/1]).
-exprot([set_led/2]).
-exprot([set_led/3]).
-export([send_version/0]).
-export([enable/0, disable/0]).
-export([json_command/1]).
-export([red/0, plain/3]).

-export([subscribe/0,subscribe/1]).
-export([unsubscribe/1]).

-compile(export_all).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% type (t) parameter
-define(TYPE_SCREEN, 0).
-define(TYPE_BUTTON, 1).
-define(TYPE_DIAL,   2).
-define(TYPE_SLIDER, 3).

-define(SERVER, ?MODULE).

-record(subscription,
	{
	  pid,
	  mon,
	  pattern
	}).

-record(layout,
	{
	  u :: string(),  %% unique number for the device
	  i :: integer(), %% sequential index with in current config
	  t :: integer(), %% type TYPE_x
	  c :: [null|#layout{}]  %% config
	}).

-record(index,
	{
	  i :: integer(),
	  t :: integer(),
	  u :: string()
	}).
%%
%% Relative screen_orientaion = 2!
%% SCREEN array [Right,Down,Left]
%% BUTTON array [Right,Down,Left]
%% DIAL array [Right,Down,Left]
%% SLIDER array = [UpRight,Right,DownRight,DownLeft,Left]
%%
-type rgb() :: {byte(),byte(),byte()}.

-record(state, 
	{
	  device :: string(),
	  uart   :: port(),
	  layout :: #layout{},
	  index_list :: [#index{}],
	  config :: [{Unique::string(),color,rgb()}],
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
-spec subscribe(Pattern::[{atom(),string()}]) ->
		       {ok,reference()} | {error, Error::term()}.
subscribe(Pattern) ->
    gen_server:call(?SERVER, {subscribe,self(),Pattern}).

%%--------------------------------------------------------------------
%% @doc
%% Subscribe to egear events.
%%
%% @end
%%--------------------------------------------------------------------
-spec subscribe() -> {ok,reference()} | {error, Error::term()}.
subscribe() ->
    gen_server:call(?SERVER, {subscribe,self(),[]}).

%%--------------------------------------------------------------------
%% @doc
%% Unsubscribe from egear events.
%%
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(Ref::reference()) -> ok | {error, Error::term()}.
unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe,Ref}).


enable() ->
    json_command({struct,[{start,1}]}).

disable() ->
    json_command({struct,[{stop,1}]}).

send_version() ->
    json_command({struct,[{send_version,1}]}).

%% set/show screen number I
screen_display(I) when is_integer(I) ->
    json_command({struct,[{screen_display,I}]}).

screen_ready(I) ->
    json_command({struct,[{screen_ready,I}]}).

screen_string(String) when is_list(String) ->
    json_command({struct,[{screen_string,String}]}).

screen_orientation(I) when is_integer(I) ->
    json_command({struct,[{screen_orientation, I}]}).

set_leds(Ls) ->
    json_command(set_leds_command_(Ls)).

set_leds_command_(Ls = [{_I,_M,_RGB}|_Leds]) ->
    {struct,[{led,{array,
		   [{struct,[{b,B},{g,G},{i,I},{m,M},{r,R}]} ||
		       {I,M,{R,G,B}} <- Ls]}}]}.

set_led(I,RGB) ->
    set_leds([{I,0,RGB}]).

set_led(I,M,RGB) ->
    set_leds([{I,M,RGB}]).

set_hidmap(Map) ->
    json_command({struct,[{set_hidmap, Map}]}).

set_joymap(Map) ->
    json_command({struct,[{set_joymap, Map}]}).

set_midimap(Map) ->
    json_command({struct,[{set_midimap, Map}]}).

set_version_screen(Version) ->
    json_command({struct,[{set_version_screen,Version}]}).

screen_write(I, Data) ->
    Data1 = base64:encode(Data),
    json_command({struct,[{screen_write,I},{data,Data1}]}).

red() ->
    plain({255,0,0},128,128).

plain({R,G,B},W,H) ->
    Row = << <<R,G,B>> || _ <- lists:seq(1,W) >>,
    Screen = << <<Row/binary>> || _ <- lists:seq(1,H) >>,
    Screen.

json_command(Command) ->
    gen_server:call(?SERVER, {command, Command}).

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
    Config = case application:get_env(egear, map) of
		 undefined -> [];
		 {ok,M} -> M
	     end,
    {ok,U} = uart:open(Device, [{active,true},{packet,line},{baud, 115200}]),
    {ok, #state{ device = Device, uart = U, config = Config }}.

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
handle_call({command, Command}, _From, State) ->
    {Reply,State1} = send_command_(Command, State),
    {reply, Reply, State1};
handle_call({subscribe,Pid,Pattern},_From,State=#state { subs=Subs}) ->
    Mon = erlang:monitor(process, Pid),
    Subs1 = [#subscription { pid = Pid, mon = Mon, pattern = Pattern}|Subs],
    {reply, {ok,Mon}, State#state { subs = Subs1}};
handle_call({unsubscribe,Ref},_From,State) ->
    erlang:demonitor(Ref),
    State1 = remove_subscription(Ref,State),
    {reply, ok, State1};
handle_call(stop, _From, State) ->
    uart:close(State#state.uart),
    {stop, normal, ok, State#state { uart=undefined }};
handle_call(_Request, _From, State) ->
    {reply, {error,bad_request}, State}.

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
handle_cast(_Msg, State) ->
    {noreply, State}.

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
handle_info({uart,U,Data}, State) when U =:= State#state.uart ->
    try exo_json:decode_string(Data) of
	{ok,Term} ->
	    %% io:format("handle_info: ~p\n", [Term]),
	    State1 = handle_event(Term, State),
	    {noreply, State1}
    catch
	error:Error ->
	    io:format("handle_info: error=~p, data=~p\n", [Error,Data]),
	    {noreply, State}
    end;
handle_info({'DOWN',Ref,process,_Pid,_Reason},State) ->
    lager:debug("handle_info: subscriber ~p terminated: ~p", 
		[_Pid, _Reason]),
    State1 = remove_subscription(Ref,State),
    {noreply, State1};
handle_info(_Info, State) ->
    io:format("handle_info: ~p\n", [_Info]),
    {noreply, State}.

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
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_command_(Command, State) ->
    %% io:format("Json: ~p\n", [Command]),
    Data = exo_json:encode(Command),
    %% io:format("command = ~s\n", [Data]),
    Reply = uart:send(State#state.uart, Data),
    {Reply,State}.

handle_event({struct,[{"in",{array,Input}}]}, State) ->
    handle_input(Input, State);
handle_event({struct,[{"l", Layout}]}, State) ->
    {L,Is} = decode_layout(Layout,[]),
    %% io:format("Layout = ~p\n", [L]),
    %% io:format("Index_list = ~p\n", [Is]),
    _Ls = format_layout(L),
    %% io:format("Layout pos = ~p\n", [Ls]),
    %% format layout positions into grid
    %% io:put_chars(render_layout(Ls)),
    State1 = match_layout(L, Is, State),
    State1#state { layout = L, index_list = Is };
handle_event(_Event, State) ->
    State.

handle_input([{struct,Input} | Is], State) ->
    State1 = handle_inp(Input, State),
    handle_input(Is,State1);
handle_input([], State) ->
    State.

handle_inp(Input, State) when State#state.index_list =/= undefined ->
    case Input of
	[{"i",Index},{"v",{array,[Press,Backward,Forward,Value,
				  _R1,_R2,_R3,_R4]}}] ->
	    case lists:keyfind(Index,#index.i,State#state.index_list) of
		false ->
		    io:format("device index=~w not found\n", [Index]),
		    State;
		#index{t=?TYPE_SLIDER,u=Unique} ->
		    send_event(State#state.subs,
			       [{type,slider},
				{index,Index},
				{id,Unique},
				{value,Press}]),
		    State;
		#index{t=?TYPE_BUTTON,u=Unique} ->
		    send_event(State#state.subs,
			       [{type,button},
				{index,Index},
				{id,Unique},
				{state,Press}
			       ]),
		    State;
		#index{t=?TYPE_DIAL,u=Unique} ->
		    Dir = if Forward =:= 1 -> 1;
			     Backward =:= 1 -> -1;
			     true -> none
			  end,
		    send_event(State#state.subs,
			       [{type,dial},
				{index,Index},
				{id,Unique},
				{direction,Dir},
				{state,Press},
				{value,Value}]),
		    State;
		_ ->
		    State
	    end;
	_ ->
	    State
    end;
handle_inp(_Input, State) ->
    State.

send_event([#subscription{pid=Pid,mon=Ref,pattern=Pattern}|Tail], Event) ->
    case match_event(Pattern, Event) of
	true -> 
	    io:format("Send event ~p\n", [Event]),
	    Pid ! {egear_event,Ref,Event};
	false -> 
	    io:format("Ignore event ~p\n", [Event]),
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


match_layout(_Layout,Is,State) ->
    match_index_list(Is, State).

match_index_list([#index{i=I,u=U}|Is], State) ->
    case lists:keyfind(U, 1, State#state.config) of
	{U,color,RGB} ->
	    Command = set_leds_command_([{I,0,RGB}]),
	    {_Reply,State1} = send_command_(Command,State),
	    match_index_list(Is, State1);
	_ ->
	    match_index_list(Is, State)
    end;
match_index_list([],State) ->
    State.

decode_layout({struct,[{"u",Unique},
		       {"i",Index},
		       {"t",Type},
		       {"c",{array,As}}]}, Conf) ->
    {Array,Conf1} = decode_layout_(As,[],Conf),
    { #layout { u = Unique,
		i = Index,
		t = Type,
		c = Array }, [#index{i=Index,t=Type,u=Unique}|Conf1]}.

decode_layout_([null | As], Acc, Conf) ->
    decode_layout_(As, [null|Acc], Conf);
decode_layout_([A | As], Acc, Conf) ->
    {L, Conf1} = decode_layout(A, Conf),
    decode_layout_(As, [L|Acc], Conf1);
decode_layout_([], Acc, Conf) ->
    {lists:reverse(Acc), Conf}.

%% format layout put the components on the grid.
%% return a list [{X,Y,Type,Index}]
multiply({A11,A12,A21,A22},{B11,B12,B21,B22}) ->
    { A11*B11 + A12*B21, A11*B12 + A12*B22,
      A21*B11 + A22*B21, A21*B12 + A22*B22 }.

rotate_90(A) -> multiply(A,{0,-1,1,0}).    %% left,ccw
rotate_270(A)  -> multiply(A,{0,1,-1,0}).  %% right,cw
rotate_180(A) -> multiply(A,{-1,0,0,-1}).  %% half turn
move({A11,A12,A21,A22},{Dx,Dy},{X,Y}) -> {Dx*A11+Dy*A12+X,Dx*A21+Dy*A22+Y}.
-define(ID, {1,0,0,1}).

format_layout(L) ->
    lists:sort(format_item(L, {0,0}, ?ID, [])).

format_item(null, _Pos, _Mx, Acc) ->
    Acc;
format_item(#layout{t=T,i=I,c=Items}, Pos={X,Y}, Mx, Acc) ->
    format_layout(T,Items,Pos,Mx,[{Y,X,T,I} | Acc]).
    
format_layout(Type, [R,D,L], Pos, Mx, Acc) when
      Type =:= ?TYPE_SCREEN; Type =:= ?TYPE_BUTTON; Type =:= ?TYPE_DIAL ->
    Acc1 = format_item(R, move(Mx,{1,0},Pos), rotate_270(Mx), Acc),
    Acc2 = format_item(D, move(Mx,{0,1},Pos), Mx, Acc1),
    Acc3 = format_item(L, move(Mx,{-1,0},Pos),rotate_90(Mx), Acc2),
    Acc3;
format_layout(Type,[UR,R,DR,DL,L],Pos,Mx,Acc=[{_,_,T,I}|_]) when
      Type =:= ?TYPE_SLIDER ->
    {X1,Y1} = move(Mx,{1,0},Pos),
    Acc0 = [{Y1,X1,T,I}|Acc],
    Acc1 = format_item(UR, move(Mx,{1,-1},Pos), rotate_180(Mx), Acc0),
    Acc2 = format_item(R,  move(Mx,{2,0},Pos), rotate_270(Mx), Acc1),
    Acc3 = format_item(DR, move(Mx,{1,1},Pos), Mx,Acc2),
    Acc4 = format_item(DL, move(Mx,{0,1},Pos), Mx, Acc3),
    Acc5 = format_item(L, move(Mx,{-1,0},Pos), rotate_90(Mx), Acc4),
    Acc5.


%% SCREEN
%% +-------+
%% |       |
%% |  Gear |
%% |       |
%% +-------+
%% +-------+
%% |  ---  |
%% | |   | |
%% |  ---  |
%% +-------+
%% +-------+
%% |  ===  |
%% | |XXX| |
%% |  ===  |
%% +-------+
%% +-------+
%% |   |   |
%% |   |   |
%% |  ===  |
%% |   |   |
%% |   |   |
%% |   |   |
%% +-------+
%% +---------------+
%% |               |
%% | ---||-------  |
%% |               |
%% +---------------+
%%
render_layout(_Ls) ->
    "".

remove_subscription(Ref, State=#state { subs=Subs}) ->
    Subs1 = lists:keydelete(Ref, #subscription.mon, Subs),
    State#state { subs = Subs1 }.
