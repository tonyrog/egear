%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2017, Tony Rogvall
%%% @doc
%%%    Basic interface
%%% @end
%%% Created : 12 Jan 2017 by Tony Rogvall <tony@rogvall.se>

-module(egear).

-export([start/0]).
-export([stop/0]).
-export([subscribe/0,subscribe/1]).
-export([unsubscribe/1]).
-export([screen_display/1]).
-export([screen_write/2]).
-export([screen_ready/1]).
-export([screen_string/1]).
-export([screen_orientation/1]).
-export([set_hidmap/1]).
-export([set_joymap/1]).
-export([set_midimap/1]).
-export([set_version_screen/1]).
-export([set_leds/1]).
-export([set_led/2]).
-export([set_led/3]).
-export([send_version/0]).
-export([enable/0, disable/0]).
-export([json_command/1]).
-export([get_layout/0]).
-export([abs_layout/0]).
-export([show_layout/0]).

-include("egear.hrl").

start() ->
    application:ensure_all_started(egear).

stop() ->
    application:stop(egear).

-spec subscribe(Pattern::[{atom(),string()}]) ->
		       {ok,reference()} | {error, Error::term()}.
subscribe(Pattern) ->
    egear_server:subscribe(?SERVER, Pattern).

-spec subscribe() -> {ok,reference()} | {error, Error::term()}.
subscribe() ->
    egar_server:subscribe(?SERVER).

-spec unsubscribe(Ref::reference()) -> ok | {error, Error::term()}.
unsubscribe(Ref) ->
    egar_server:usubscribe(?SERVER, Ref).

-spec enable() -> ok | {error,Reason::atom()}.
enable() ->
    json_command({struct,[{start,1}]}).

-spec disable() -> ok | {error,Reason::atom()}.
disable() ->
    json_command({struct,[{stop,1}]}).

-spec send_version() -> ok | {error,Reason::atom()}.
send_version() ->
    json_command({struct,[{send_version,1}]}).

%% set/show screen number Num
-spec screen_display(Num::0..15) -> ok | {error,Reason::atom()}.
screen_display(Num) when is_integer(Num), Num>=0, Num=<15 ->
    json_command({struct,[{screen_display,Num}]}).

-spec screen_ready(Num::0..15) -> ok | {error,Reason::atom()}.
screen_ready(Num) ->
    json_command({struct,[{screen_ready,Num}]}).

-spec screen_string(String::string()) -> ok | {error,Reason::atom()}.
screen_string(String) when is_list(String) ->
    json_command({struct,[{screen_string,String}]}).

-spec screen_orientation(Num::0..3) -> ok | {error,Reason::atom()}.
screen_orientation(Num) when is_integer(Num) ->
    json_command({struct,[{screen_orientation, Num}]}).

-spec set_leds(Ls::[{I::index(),M::integer(),
		     {R::byte(),G::byte(),B::byte()}}]) ->
		      ok | {error,Reason::atom()}.
set_leds(Ls) ->
    json_command(egear_server:make_leds_command(Ls)).

-spec set_led(I::index(),Color::color()) ->
		     ok | {error,Reason::atom()}.
set_led(I,RGB) ->
    set_leds([{I,0,RGB}]).

-spec set_led(I::index(),M::integer(),Color::color()) ->
		      ok | {error,Reason::atom()}.
set_led(I,M,RGB) ->
    set_leds([{I,M,RGB}]).

-spec set_hidmap(Map::term()) -> ok | {error,Reason::atom()}.
    
set_hidmap(Map) ->
    json_command({struct,[{set_hidmap, Map}]}).

-spec set_joymap(Map::term()) -> ok | {error,Reason::atom()}.
set_joymap(Map) ->
    json_command({struct,[{set_joymap, Map}]}).

-spec set_midimap(Map::term()) -> ok | {error,Reason::atom()}.
set_midimap(Map) ->
    json_command({struct,[{set_midimap, Map}]}).

-spec set_version_screen(Verion::integer()) -> ok | {error,Reason::atom()}.
set_version_screen(Version) ->
    json_command({struct,[{set_version_screen,Version}]}).

-spec screen_write(Num::0..15, Icon::binary()) -> 
			  ok | {error,Reason::atom()}.
screen_write(I, Data) when is_binary(Data), byte_size(Data) =:= 8240 ->
    json_command({struct,[{screen_write,I}]},Data).

-spec json_command(Command::json()) -> ok | {error,Reason::atom()}.
json_command(Command) ->
    egear_server:json_command(?SERVER, Command).

-spec json_command(Command::json(), Data::binary()) ->
			  ok | {error,Reason::atom()}.
json_command(Command,Data) ->
    egear_server:json_command(?SERVER, Command,Data).

-spec get_layout() -> {ok,Layout::#layout{}} | {error,Reason::atom()}.

get_layout() ->
    egear_server:get_layout(?SERVER).

-define(ID, {1,0,0,1}).

-spec abs_layout() -> {ok,[{Y::integer(),X::integer(),
			    Type::0..3,I::index()}]} |
		      {error,Reason::atom()}.
abs_layout() ->
    case get_layout() of
	{ok,L} ->
	    {ok,lists:sort(abs_item_(L, {0,0}, ?ID, []))};
	Err -> Err
    end.
	    

-spec show_layout() -> ok | {error,Reason::atom()}.

show_layout() ->
    case abs_layout() of
	{ok,L} ->
	    io:put_chars(render_layout(L));
	Err -> Err
    end.

%% interpret the structure to get absolute coordinates
abs_item_(null, _Pos, _Mx, Acc) ->
    Acc;
abs_item_(#layout{t=T,i=I,c=Items}, Pos={X,Y}, Mx, Acc) ->
    abs_layout_(T,Items,Pos,Mx,[#abspos{y=Y,x=X,type=T,index=I} | Acc]).
    
abs_layout_(Type, [R,D,L], Pos, Mx, Acc) when
      Type =:= screen; Type =:= button; Type =:= dial ->
    Acc1 = abs_item_(R, move(Mx,{1,0},Pos), rotate_270(Mx), Acc),
    Acc2 = abs_item_(D, move(Mx,{0,1},Pos), Mx, Acc1),
    Acc3 = abs_item_(L, move(Mx,{-1,0},Pos),rotate_90(Mx), Acc2),
    Acc3;
abs_layout_(Type,[UR,R,DR,DL,L],Pos,Mx,[A|Acc])
  when Type =:= slider ->
    {X1,Y1} = move(Mx,{1,0},Pos),
    Orientation = if A#abspos.y =:= Y1, A#abspos.x < X1 -> right;
		     A#abspos.y =:= Y1, A#abspos.x > X1 -> left;
		     A#abspos.x =:= X1, A#abspos.y < Y1 -> up;
		     A#abspos.x =:= X1, A#abspos.y > Y1 -> down
		  end,
    Acc0 = [A#abspos{orientation=Orientation}|Acc],
    Acc1 = abs_item_(UR, move(Mx,{1,-1},Pos), rotate_180(Mx), Acc0),
    Acc2 = abs_item_(R,  move(Mx,{2,0},Pos), rotate_270(Mx), Acc1),
    Acc3 = abs_item_(DR, move(Mx,{1,1},Pos), Mx,Acc2),
    Acc4 = abs_item_(DL, move(Mx,{0,1},Pos), Mx, Acc3),
    Acc5 = abs_item_(L, move(Mx,{-1,0},Pos), rotate_90(Mx), Acc4),
    Acc5.

%% format layout put the components on the grid.
%% return a list [{X,Y,Type,Index}]
multiply({A11,A12,A21,A22},{B11,B12,B21,B22}) ->
    { A11*B11 + A12*B21, A11*B12 + A12*B22,
      A21*B11 + A22*B21, A21*B12 + A22*B22 }.

rotate_90(A) -> multiply(A,{0,-1,1,0}).    %% left,ccw
rotate_270(A)  -> multiply(A,{0,1,-1,0}).  %% right,cw
rotate_180(A) -> multiply(A,{-1,0,0,-1}).  %% half turn
move({A11,A12,A21,A22},{Dx,Dy},{X,Y}) -> {Dx*A11+Dy*A12+X,Dx*A21+Dy*A22+Y}.

render_layout(Ls0) ->
    Xs0 = [X || #abspos{x=X} <- Ls0],
    Ys0 = [Y || #abspos{y=Y} <- Ls0],
    MinX = lists:min(Xs0),
    MaxX = lists:max(Xs0),
    MinY = lists:min(Ys0),
    MaxY = lists:max(Ys0),
    SizeX = (MaxX - MinX)+1,
    SizeY = (MaxY - MinY)+1,
    %% offset all points and with 0,0 as top left corner
    %% make all coordinate positive, then tilt Y axis
    Ls = [A#abspos{y=(A#abspos.y-MinY),x=(A#abspos.x-MinX)} || A <- Ls0],
    Blank = array:new(SizeX*9,[{default,$\s}]),
    Screen = array:new(SizeY*5,[{default,Blank}]),
    Screen1 = render_items(Ls, Screen),
    [[array:to_list(R),"\n"] || R <- array:to_list(Screen1)].

render_items([#abspos{y=Y,x=X,type=T,orientation=R}|L],Screen) ->
    case T of
	screen ->
	    render_items(L,render_screen(X*9,Y*5,R,Screen));
	button ->
	    render_items(L,render_button(X*9,Y*5,R,Screen));
	dial ->
	    render_items(L,render_dial(X*9,Y*5,R,Screen));
	slider ->
	    render_items(L,render_slider(X*9,Y*5,R,Screen))
    end;
render_items([], Screen) ->
    Screen.


render_screen(X,Y,_VH,Screen) ->
    draw_lines(X,Y,Screen,
	       ["+-------+",
		"|       |",
		"|  Gear |",
		"|       |",
		"+-------+"]).

render_button(X,Y,_VH,Screen) ->
    draw_lines(X,Y,Screen,
	       ["+-------+",
		"|  ---  |",
		"| |   | |",
		"|  ---  |",
		"+-------+"]).

render_dial(X,Y,_VH,Screen) ->
    draw_lines(X,Y,Screen,
	       ["+-------+",
		"|  ===  |",
		"| |XXX| |",
		"|  ===  |",
		"+-------+"]).

render_slider(X,Y,down,Screen) ->
    draw_lines(X,Y,Screen,
	       [
		"+-------+",
		"|   |   |",
		"|   |   |",
		"|   |   |",
		"|  ===  |",
		"|   |   |",
		"|   |   |",
		"|   |   |",
		"|   |   |",
		"+-------+"]);
render_slider(X,Y,up,Screen) ->
    draw_lines(X,Y-9,Screen,
	       [
		"+-------+",
		"|   |   |",
		"|   |   |",
		"|   |   |",
		"|  ===  |",
		"|   |   |",
		"|   |   |",
		"|   |   |",
		"|   |   |",
		"+-------+"]);
render_slider(X,Y,right,Screen) ->
    draw_lines(X,Y,Screen,
	       ["+----------------+",
		"|                |",
		"| ---||--------- |",
		"|                |",
		"+----------------+"]);
render_slider(X,Y,left,Screen) ->
    draw_lines(X-5,Y,Screen,
	       ["+----------------+",
		"|                |",
		"| ---||--------- |",
		"|                |",
		"+----------------+"]).

draw_lines(X,Y,Screen,[L|Ls]) ->
    draw_lines(X,Y+1,draw_line(X,Y,Screen,L),Ls);
draw_lines(_X,_Y,Screen,[]) ->
    Screen.

draw_line(X,Y,Screen,L) ->
    io:format("draw line x=~w,y=~w [~s]\n", [X,Y,L]),
    A0 = array:get(Y,Screen),
    A1 = lists:foldl(
	   fun({Xi,Char},Ai) ->
		   io:format("draw char x=~w [~s]\n", [Xi,[Char]]),
		   array:set(Xi,Char,Ai)
	   end, A0, lists:zip(lists:seq(X,X+length(L)-1), L)),
    array:set(Y,A1,Screen).
