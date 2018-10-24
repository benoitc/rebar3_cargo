-module(rebar3_cargo).

-export([init/1]).

-include("rebar3_cargo.hrl").


-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
  State1 = rebar_state:add_resource(State, {path, rebar_cargo_path_resource}),
  State2 = rebar_state:add_resource(State1, {git, rebar_cargo_git_resource}),
  {ok, State2}.
