-ifndef(__EGEAR__).
-define(__EGEAR__, true).

-define(SERVER, egear_server).

-type color() :: {R::byte(),G::byte(),B::byte()}.
-type index() :: integer().
-type json_key() :: atom() | string() | binary().
-type json() :: null | undefined | true | false |
		integer() | float() | atom() | string() | binary() |
		{struct,[{Key::json_key(),Value::json()}]} |
		{array,[Elem::json()]}.

-type item_type() :: screen|button|dial|slider.

-record(layout,
	{
	  u :: string(),  %% unique number for the device
	  i :: integer(), %% sequential index with in current config
	  t :: item_type(),      %% type of iterm
	  c :: [null|#layout{}]  %% config
	}).

-record(abspos,
	{
	  x :: integer(),
	  y :: integer(),
	  type :: item_type(),
	  index :: integer(),
	  orientation :: right | up | left | down
	}).
	  

-endif.
