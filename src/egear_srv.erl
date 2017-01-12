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

-record(layout,
	{
	  u :: string(),  %% unique number for the device
	  i :: integer(), %% sequential index with in current config
	  t :: integer(), %% type TYPE_x
	  c :: [null|#layout{}]  %% config
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
	  layout :: #layout{},
	  config :: {Index::integer,Type::integer,Unique::string()}
	}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start_link(Device) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [{device,Device}], []).

stop() ->
    gen_server:stop(?SERVER).

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

set_leds(Ls = [{_I,_M,_RGB}|_Leds]) ->
    json_command({struct,[{led,{array,
				[{struct,[{b,B},{g,G},{i,I},{m,M},{r,R}]} || 
				    {I,M,{R,G,B}} <- Ls]}}]}).

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
    {ok,U} = uart:open(Device, [{active,true},{packet,line},{baud, 115200}]),
    {ok, #state{ device = Device, uart = U }}.

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
    io:format("Json: ~p\n", [Command]),
    Data = exo_json:encode(Command),
    io:format("command = ~s\n", [Data]),
    Reply = uart:send(State#state.uart, Data),
    {reply, Reply, State};
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
	    io:format("handle_info: ~p\n", [Term]),
	    State1 = handle_event(Term, State),
	    {noreply, State1}
    catch
	error:Error ->
	    io:format("handle_info: error=~p, data=~p\n", [Error,Data]),
	    {noreply, State}
    end;
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

handle_event({struct,[{"in",{array,Input}}]}, State) ->
    handle_input(Input, State);
handle_event({struct,[{"l", Layout}]}, State) ->
    {L,C} = decode_layout(Layout,[]),
    io:format("Layout = ~p\n", [L]),
    io:format("config = ~p\n", [C]),
    State#state { layout = L, config = C };
handle_event(_Event, State) ->
    State.

handle_input([{struct,Input} | Is], State) ->
    State1 = handle_inp(Input, State),
    handle_input(Is,State1);
handle_input([], State) ->
    State.

handle_inp(Input, State) when State#state.config =/= undefined ->
    case Input of
	[{"i",Index},{"v",{array,[Press,Backward,Forward,Value,
				  _R1,_R2,_R3,_R4]}}] ->
	    case lists:keyfind(Index,1,State#state.config) of
		false ->
		    io:format("device not found\n", []),
		    State;
		{_,?TYPE_SLIDER,Unique} ->
		    io:format("slider[~s] value=~w\n", 
			      [Unique,Press]),
		    State;
		{_,?TYPE_BUTTON,Unique} ->
		    io:format("button[~s] state=~s\n", 
			      [Unique,if Press =:= 1 -> pressed;
					 true -> released
				      end]),
		    State;
		{_,?TYPE_DIAL,Unique} ->
		    io:format("dial[~s] value=~w, direction=~s state=~s\n", 
			      [Unique,Value,
			       if Forward =:= 1 -> forward;
				  Backward =:= 1 -> backward;
				  true -> none
			       end,
			       if Press =:= 1 -> pressed;
				  true -> released
			       end]),
		    State;
		_ ->
		    State
	    end;
	_ ->
	    State
    end;
handle_inp(_Input, State) ->
    State.


decode_layout({struct,[{"u",Unique},
		       {"i",Index},
		       {"t",Type},
		       {"c",{array,As}}]}, Conf) ->
    {Array,Conf1} = decode_layout_(As,[],Conf),
    { #layout { u = Unique,
		i = Index,
		t = Type,
		c = Array }, [{Index,Type,Unique}|Conf1]}.

decode_layout_([null | As], Acc, Conf) ->
    decode_layout_(As, [null|Acc], Conf);
decode_layout_([A | As], Acc, Conf) ->
    {L, Conf1} = decode_layout(A, Conf),
    decode_layout_(As, [L|Acc], Conf1);
decode_layout_([], Acc, Conf) ->
    {lists:reverse(Acc), Conf}.
