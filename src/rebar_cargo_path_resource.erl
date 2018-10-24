-module(rebar_cargo_path_resource).

-export([init/2,
         lock/2,
         download/4,
         needs_update/2,
         make_vsn/2]).

-include_lib("kernel/include/file.hrl").

-include("rebar3_cargo.hrl").

init(Type, _State) ->
  Resource = rebar_resource_v2:new(Type, ?MODULE, #{}),
  {ok, Resource}.


lock(AppInfo, _) ->
  lock_(rebar_app_info:dir(AppInfo), rebar_app_info:source(AppInfo)).

lock_(Dir, {path, Path, _}) ->
  lock_(Dir, {path, Path});

lock_(_Dir, {path, Path}) ->
  Source = filename:absname(Path),
  ?DEBUG("lock ~p~n", [Source]),
  {path, Path, undefined}.


download(TmpDir, AppInfo, State, _) ->
  download_(TmpDir, rebar_app_info:source(AppInfo), State).

download_(Dir, {path, Path, _}, State) ->
  download_(Dir, {path, Path}, State);
download_(Dir, {path, Path}, _State) ->
  Dest = filename:absname(Dir),
  ok = rebar_file_utils:rm_rf(Dest),
  Source = filename:absname(Path),
  ?DEBUG("copy local path ~p to ~p", [Source, Dest]),
  rebar3_cargo_util:copy(Source, Dest).


make_vsn(_AppInfo, _State) ->
  {error, "Replacing version of type path not supported."}.

needs_update(_AppInfo, _) ->
  true.
