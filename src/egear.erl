%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2017, Tony Rogvall
%%% @doc
%%%    Basic interface
%%% @end
%%% Created : 12 Jan 2017 by Tony Rogvall <tony@rogvall.se>

-module(egear).

-export([start/0]).
-export([stop/0]).

start() ->
    application:ensure_all_started(egear).

stop() ->
    application:stop(egear).

