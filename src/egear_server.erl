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

-record(s, 
	{
	  device :: string(),
	  uart   :: port(),
	  baud_rate = 115200 :: integer(),
	  retry_interval = 5000 :: integer(),
	  retry_timer :: reference(),
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

screen_write(I, Data) when is_binary(Data), byte_size(Data) =:= 8240 ->
    json_command({struct,[{screen_write,I}]},Data).

%% construct an image of red pixels
red() ->
    plain({255,0,0},128,128).

green() ->
    plain({0,255,0},128,128).

blue() ->
    plain({0,0,255},128,128).

    


%% construct an imag with ONE palette entry
plain({R,G,B},W,H) ->
    %% 48 byte palette in BGR format
    Palette = palette([{R,G,B}]),
    Size = W*H*4,
    <<Palette/binary, 0:Size>>.


%% input a list of RGB tripple and output a palette of 48 bytes
%% padded with 0 entries if needed
palette(RGBs) ->
    RGBs1 = lists:sublist(RGBs, 16),  %% make sure max 16 entries,
    N = length(RGBs1),
    ZEntries = << <<0,0,0>> || _ <- lists:seq(1,16-N) >>,
    << << <<B,G,R>> || {R,G,B} <- RGBs1>>/binary, ZEntries/binary>>.

json_command(Command) ->
    gen_server:call(?SERVER, {command, Command}).

json_command(Command,Data) ->
    gen_server:call(?SERVER, {command, Command, Data}).

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
    BaudRate = case application:get_env(egear, baud_rate) of
		   undefined ->
		       proplists:get_value(baud_rate, Options, 
					   (#s{})#s.baud_rate);
		   {ok,BR} -> BR
	       end,
    RetryInterval = case application:get_env(egear, retry_interval) of
			undefined ->
			    proplists:get_value(retry_interval, Options, 
						(#s{})#s.retry_interval);
			{ok,RI} -> RI
		    end,
    Config = case application:get_env(egear, map) of
		 undefined -> [];
		 {ok,M} -> M
	     end,
    S = #s { device = Device,
	     retry_interval = RetryInterval,
	     baud_rate = BaudRate,
	     config=Config },
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
handle_call({subscribe,Pid,Pattern},_From,S=#s { subs=Subs}) ->
    Mon = erlang:monitor(process, Pid),
    Subs1 = [#subscription { pid = Pid, mon = Mon, pattern = Pattern}|Subs],
    {reply, {ok,Mon}, S#s { subs = Subs1}};
handle_call({unsubscribe,Ref},_From,S) ->
    erlang:demonitor(Ref),
    S1 = remove_subscription(Ref,S),
    {reply, ok, S1};
handle_call(stop, _From, S) ->
    uart:close(S#s.uart),
    {stop, normal, ok, S#s { uart=undefined }};
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
handle_info({uart,U,Data}, S) when U =:= S#s.uart ->
    try exo_json:decode_string(Data) of
	{ok,Term} ->
	    S1 = handle_event(Term, S),
	    {noreply, S1}
    catch
	error:Error ->
	    debug("handle_info: error=~p, data=~p", [Error,Data]),
	    {noreply, S}
    end;
handle_info({uart_error,U,Reason}, S) when S#s.uart =:= U ->
    if Reason =:= enxio ->
	    debug("maybe unplugged?", []),
	    {noreply, reopen(S)};
       true ->
	    debug("uart error=~p", [Reason]),
	    {noreply, S}
    end;
handle_info({uart_closed,U}, S) when U =:= S#s.uart ->
    debug("uart_closed: reopen in ~w",[S#s.retry_interval]),
    S1 = reopen(S),
    {noreply, S1};
handle_info({timeout,TRef,reopen},S) 
  when TRef =:= S#s.retry_timer ->
    case open(S#s { retry_timer = undefined }) of
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
    debug("handle_info: ~p", [_Info]),
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
    Reply = uart:send(S#s.uart, CData),
    {Reply,S}.

send_command_(Command, Data, S) ->
    CData = exo_json:encode(Command),
    case uart:send(S#s.uart, CData) of
	ok ->
	    Reply = uart:send(S#s.uart, Data),
	    {Reply,S};
	Error ->
	    {Error,S}
    end.

handle_event({struct,[{"in",{array,Input}}]}, S) ->
    handle_input(Input, S);
handle_event({struct,[{"l", Layout}]}, S) ->
    {L,Is} = decode_layout(Layout,[]),
    _Ls = format_layout(L),
    S1 = match_layout(L, Is, S),
    S1#s { layout = L, index_list = Is };
handle_event(_Event, S) ->
    S.

handle_input([{struct,Input} | Is], S) ->
    S1 = handle_inp(Input, S),
    handle_input(Is,S1);
handle_input([], S) ->
    S.

handle_inp(Input, S) when S#s.index_list =/= undefined ->
    debug("input ~p\n", [Input]),
    case Input of
	[{"i",Index},{"v",{array,[Press,Backward,Forward,Value,
				  _R1,_R2,_R3,_R4]}}] ->
	    case lists:keyfind(Index,#index.i,S#s.index_list) of
		false ->
		    io:format("device index=~w not found\n", [Index]),
		    S;
		#index{t=?TYPE_SLIDER,u=Unique} ->
		    send_event(S#s.subs,
			       [{type,slider},
				{index,Index},
				{id,Unique},
				{value,Press}]),
		    S;
		#index{t=?TYPE_BUTTON,u=Unique} ->
		    send_event(S#s.subs,
			       [{type,button},
				{index,Index},
				{id,Unique},
				{state,Press}
			       ]),
		    S;
		#index{t=?TYPE_DIAL,u=Unique} ->
		    Dir = if Forward =:= 1 -> 1;
			     Backward =:= 1 -> -1;
			     true -> none
			  end,
		    send_event(S#s.subs,
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


match_layout(_Layout,Is,S) ->
    match_index_list(Is, S).

match_index_list([#index{i=I,u=U}|Is], S) ->
    case lists:keyfind(U, 1, S#s.config) of
	{U,color,RGB} ->
	    Command = set_leds_command_([{I,0,RGB}]),
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

remove_subscription(Ref, S=#s { subs=Subs}) ->
    Subs1 = lists:keydelete(Ref, #subscription.mon, Subs),
    S#s { subs = Subs1 }.


open(S0=#s { device = DeviceName, baud_rate = Baud }) ->
    UartOpts = [{baud, Baud}, {packet, line},
		{csize, 8}, {stopb,1}, {parity,none}, {active, true}],
    case uart:open1(DeviceName, UartOpts) of
	{ok,U} ->
	    debug("~s@~w", [DeviceName,Baud]),
	    send_command_({struct,[{start,1}]}, S0#s{uart=U});

	{error,E} when E =:= eaccess; E =:= enoent; E =:= ebusy ->
	    if is_integer(S0#s.retry_interval), S0#s.retry_interval > 0 ->
		    debug("~s@~w  error ~w, will try again in ~p msecs.", 
			  [DeviceName,Baud,E,S0#s.retry_interval]),
		    {ok, reopen(S0)};
	       true ->
		    {E, S0}
	    end;
	{error, E} ->
	    {E, S0}
    end.

reopen(S=#s {device = DeviceName}) ->
    if S#s.uart =/= undefined ->
	    debug("closing device ~s", [DeviceName]),
	    R = uart:close(S#s.uart),
	    debug("closed ~p", [R]),
	    R;
       true ->
	    ok
    end,
    T = erlang:max(100, S#s.retry_interval),
    Timer = start_timer(T, reopen),
    S#s { uart=undefined, retry_timer=Timer }.

start_timer(undefined, _Tag) ->
    undefined;
start_timer(infinity, _Tag) ->
    undefined;
start_timer(Time, Tag) ->
    erlang:start_timer(Time,self(),Tag).

debug(Fmt, Args) ->
    io:format(Fmt++"\n", Args).

erlang() ->
    xpm([{$\s,0,{255,255,255}},
	 {$.,1,{16#8c,16#00,16#2f}},
	 {$+,2,{16#00,16#00,16#00}}],
[
 "                                                                                                                                ",
 " .................                                                                                             ................ ",
 " ................                                                                                               ............... ",
 " ...............                                           ...........                                           .............. ",
 " ..............                                          ................                                        .............. ",
 " ..............                                        ....................                                       ............. ",
 " .............                                        ......................                                      ............. ",
 " ............                                        ........................                                      ............ ",
 " ............                                       ..........................                                     ............ ",
 " ...........                                       ...........................                                      ........... ",
 " ...........                                      .............................                                     ........... ",
 " ..........                                       ..............................                                     .......... ",
 " ..........                                      ...............................                                     .......... ",
 " .........                                       ...............................                                     .......... ",
 " .........                                      ................................                                      ......... ",
 " .........                                      .................................                                     ......... ",
 " ........                                       .................................                                     ......... ",
 " ........                                      ..................................                                     ......... ",
 " .......                                       ..................................                                      ........ ",
 " .......                                                                                                               ........ ",
 " .......                                                                                                               ........ ",
 " ......                                                                                                                ........ ",
 " ......                                                                                                                ........ ",
 " ......                                                                                                                 ....... ",
 " ......                                                                                                                 ....... ",
 " ......                                                                                                                 ....... ",
 " .....                                                                                                                  ....... ",
 " .....                                                                                                                  ....... ",
 " .....                                                                                                                  ....... ",
 " .....                                                                                                                  ....... ",
 " .....                                                                                                                  ....... ",
 " ....                                                                                                                   ....... ",
 " ....                                                                                                                   ....... ",
 " ....                                                                                                                   ....... ",
 " ....                                                                                                                   ....... ",
 " ....                                                                                                                   ....... ",
 " ....                                                                                                                   ....... ",
 " ....                                                                                                                   ....... ",
 " ....                                         ................................................................................. ",
 " ....                                         ................................................................................. ",
 " ....                                         ................................................................................. ",
 " ....                                         ................................................................................. ",
 " ....                                         ................................................................................. ",
 " ....                                         ................................................................................. ",
 " ....                                          ................................................................................ ",
 " ....                                          ................................................................................ ",
 " ....                                          ................................................................................ ",
 " .....                                         ................................................................................ ",
 " .....                                         ................................................................................ ",
 " .....                                         ................................................................................ ",
 " .....                                         ................................................................................ ",
 " .....                                         ................................................................................ ",
 " .....                                          ............................................................................... ",
 " ......                                         ............................................................................... ",
 " ......                                         ............................................................................... ",
 " ......                                         ............................................................................... ",
 " ......                                          ......................................................  ...................... ",
 " .......                                         ......................................................    .................... ",
 " .......                                         .....................................................       .................. ",
 " .......                                          ....................................................         ................ ",
 " .......                                          ...................................................            .............. ",
 " ........                                         ..................................................               ............ ",
 " ........                                          ................................................                  .......... ",
 " .........                                         ...............................................                     ........ ",
 " .........                                          ..............................................                       ...... ",
 " .........                                           ............................................                          .... ",
 " ..........                                          ...........................................                          ..... ",
 " ..........                                           .........................................                           ..... ",
 " ...........                                           .......................................                           ...... ",
 " ...........                                            .....................................                           ....... ",
 " ............                                            ..................................                             ....... ",
 " ............                                             ................................                             ........ ",
 " .............                                             .............................                              ......... ",
 " ..............                                              ..........................                               ......... ",
 " ..............                                               .......................                                .......... ",
 " ...............                                                 .................                                  ........... ",
 " ................                                                    .........                                     ............ ",
 " ................                                                                                                  ............ ",
 " .................                                                                                                ............. ",
 " ..................                                                                                              .............. ",
 " ...................                                                                                            ............... ",
 "                                                                                                                                ",
 "                                                                                                                                ",
 "                                                                                                                                ",
 "                                                                                                                                ",
 "                                                                                                                                ",
 "                                                                                                                                ",
 "                                                                                                                   +++++        ",
 " ++++++++++          +++++++++            ++++                    ++++              ++++         +++++           ++++++++++     ",
 " ++++++++++          ++++++++++           ++++                   +++++              ++++         +++++          ++++++++++++    ",
 " ++++++++++          +++++++++++          ++++                   ++++++             +++++        +++++         ++++++++++++++   ",
 " ++++                ++++   ++++          ++++                   ++++++             ++++++       +++++        +++++      +++++  ",
 " ++++                ++++   +++++         ++++                  +++++++             +++++++      +++++       +++++        +++   ",
 " ++++                ++++    ++++         ++++                  ++++++++            ++++++++     +++++       ++++         +     ",
 " ++++                ++++    ++++         ++++                 ++++ ++++            ++++++++     +++++      +++++               ",
 " ++++                ++++   ++++          ++++                 ++++ ++++            ++++ ++++    +++++      ++++                ",
 " ++++++++++          ++++  +++++          ++++                 +++   ++++           ++++  ++++   +++++      ++++                ",
 " ++++++++++          ++++++++++           ++++                ++++   ++++           ++++   ++++  +++++      ++++      +++++++++ ",
 " ++++++++++          ++++++++++           ++++                ++++   +++++          ++++   ++++  +++++      ++++      +++++++++ ",
 " ++++                ++++++++             ++++                ++++    ++++          ++++    ++++ +++++      ++++      +++++++++ ",
 " ++++                +++++++++            ++++               +++++++++++++          ++++     +++++++++      +++++         ++++  ",
 " ++++                ++++ ++++            ++++               ++++++++++++++         ++++      ++++++++       ++++         ++++  ",
 " ++++                ++++ +++++           ++++              +++++++++++++++         ++++       +++++++       +++++        ++++  ",
 " ++++                ++++  +++++          ++++              +++++      ++++         ++++       +++++++        +++++      +++++  ",
 " ++++++++++          ++++  +++++          ++++++++++        ++++        ++++        ++++        ++++++        ++++++   ++++++   ",
 " ++++++++++          ++++   +++++         ++++++++++       ++++         ++++        ++++         +++++         +++++++++++++    ",
 " ++++++++++          ++++    +++++        ++++++++++       ++++         +++++       ++++          ++++          +++++++++++     ",
 " ++++++++++          ++++    +++++        +++++++++        +++           ++++        +++           ++             ++++++++      ",
 "                                                                                                                                "	
 ]).

xpm(XPMPalette,XPM) ->
    Palette = palette([Color||{_Char,_Index,Color} <- XPMPalette]),
    Data = xpm_rows(XPMPalette,XPM,128,[]),
    Pixmap = << <<I:4>> || I <- Data>>,
    <<Palette/binary, Pixmap/binary>>.

xpm_rows(_Palette, _, 0, Data) -> 
    lists:append(Data);
xpm_rows(Palette, [R|Rs], I, Data) ->
    D = xpm_row(Palette, R, 128, []),
    xpm_rows(Palette, Rs, I-1, [D|Data]);
xpm_rows(Palette, [], I, Data) ->
    xpm_rows(Palette, [], I-1, [lists:duplicate(128,0)|Data]).

xpm_row(_Palette,_Cs,0,Data) ->
    lists:reverse(Data);
xpm_row(Palette,[C|Cs],J,Data) ->
    {_,I,_Color} = lists:keyfind(C,1,Palette),
    xpm_row(Palette,Cs,J-1,[I|Data]);
xpm_row(Palette,[],J,Data) ->
    xpm_row(Palette,[],J-1,[0|Data]).
