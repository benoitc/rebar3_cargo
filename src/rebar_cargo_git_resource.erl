-module(rebar_cargo_git_resource).

-export([init/2,
         lock/2,
         download/4,
         needs_update/2,
         make_vsn/2]).

-include("rebar3_cargo.hrl").


%% Regex used for parsing scp style remote url
-define(SCP_PATTERN, "\\A(?<username>[^@]+)@(?<host>[^:]+):(?<path>.+)\\z").

-define(DEFAULT_CONFIG_FILE, "rebar.config").

-spec init(atom(), rebar_state:t()) -> {ok, rebar_resource_v2:resource()}.
init(Type, State) ->
  ResourceState = cache_dir(State, #{}),
  Resource = rebar_resource_v2:new(Type, ?MODULE, ResourceState),
  {ok, Resource}.


cache_dir(State, ResourceState) ->
  Dir = filename:join([rebar_dir:local_cache_dir(rebar_dir:root_dir(State)), "git_cache"]),
  ?DEBUG("==> init cache_dir=~p~n", [Dir]),
  ok = filelib:ensure_dir(Dir),
  ResourceState#{ cache_dir => Dir }.

cache_dir(#{ cache_dir := Dir }) -> Dir.

lock(AppInfo, ResourceState) ->
  check_type_support(),
  CacheDir = filename:join(cache_dir(ResourceState), rebar_app_info:name(AppInfo)),
  lock_(CacheDir, rebar_app_info:source(AppInfo)).

lock_(AppDir, {git, Url, _}) ->
  lock_(AppDir, {git, Url});
lock_(AppDir, {git, Url}) ->
  AbortMsg = lists:flatten(io_lib:format("Locking of git dependency failed in ~ts", [AppDir])),
  Dir = rebar_utils:escape_double_quotes(AppDir),
  {ok, VsnString} =
  case os:type() of
    {win32, _} ->
      rebar_utils:sh("git --git-dir=\"" ++ Dir ++ "/.git\" --work-tree=\"" ++ Dir ++ "\" rev-parse --verify HEAD",
                     [{use_stdout, false}, {debug_abort_on_error, AbortMsg}]);
    _ ->
      rebar_utils:sh("git --git-dir=\"" ++ Dir ++ "/.git\" rev-parse --verify HEAD",
                     [{use_stdout, false}, {debug_abort_on_error, AbortMsg}])
  end,
  Ref = rebar_string:trim(VsnString, both, "\n"),
  {git, Url, {ref, Ref}}.

%% Return true if either the git url or tag/branch/ref is not the same as the currently
%% checked out git repo for the dep
needs_update(AppInfo, ResourceState) ->
  check_type_support(),
  CacheDir = filename:join(cache_dir(ResourceState), rebar_app_info:name(AppInfo)),
  ?DEBUG("check ~p~n", [rebar_app_info:source(AppInfo)]),
  needs_update_(CacheDir, rebar_app_info:source(AppInfo)).

needs_update_(Dir, {git, Url, {tag, Tag}}) ->
  {ok, Current} = rebar_utils:sh(?FMT("git describe --tags --exact-match", []),
                                 [{cd, Dir}]),
  Current1 = rebar_string:trim(rebar_string:trim(Current, both, "\n"),
                               both, "\r"),
  ?DEBUG("Comparing git tag ~ts with ~ts", [Tag, Current1]),
  not ((Current1 =:= Tag) andalso compare_url(Dir, Url));
needs_update_(Dir, {git, Url, {branch, Branch}}) ->
  %% Fetch remote so we can check if the branch has changed
  SafeBranch = rebar_utils:escape_chars(Branch),
  {ok, _} = rebar_utils:sh(?FMT("git fetch origin ~ts", [SafeBranch]),
                           [{cd, Dir}]),
  %% Check for new commits to origin/Branch
  {ok, Current} = rebar_utils:sh(?FMT("git log HEAD..origin/~ts --oneline", [SafeBranch]),
                                 [{cd, Dir}]),
  ?DEBUG("Checking git branch ~ts for updates", [Branch]),
  not ((Current =:= []) andalso compare_url(Dir, Url));
needs_update_(Dir, {git, Url, "master"}) ->
  needs_update_(Dir, {git, Url, {branch, "master"}});
needs_update_(Dir, {git, _, Ref}) ->
  {ok, Current} = rebar_utils:sh(?FMT("git rev-parse --short=7 -q HEAD", []),
                                 [{cd, Dir}]),
  Current1 = rebar_string:trim(rebar_string:trim(Current, both, "\n"),
                               both, "\r"),
  Ref2 = case Ref of
           {ref, Ref1} ->
             Length = length(Current1),
             case Length >= 7 of
               true -> lists:sublist(Ref1, Length);
               false -> Ref1
             end;
           _ ->
             Ref
         end,

  ?DEBUG("Comparing git ref ~ts with ~ts", [Ref2, Current1]),
  (Current1 =/= Ref2).

compare_url(Dir, Url) ->
  {ok, CurrentUrl} = rebar_utils:sh(?FMT("git config --get remote.origin.url", []),
                                    [{cd, Dir}]),
  CurrentUrl1 = rebar_string:trim(rebar_string:trim(CurrentUrl, both, "\n"),
                                  both, "\r"),
  {ok, ParsedUrl} = parse_git_url(Url),
  {ok, ParsedCurrentUrl} = parse_git_url(CurrentUrl1),
  ?DEBUG("Comparing git url ~p with ~p", [ParsedUrl, ParsedCurrentUrl]),
  ParsedCurrentUrl =:= ParsedUrl.

parse_git_url(Url) ->
  %% Checks for standard scp style git remote
  case re:run(Url, ?SCP_PATTERN, [{capture, [host, path], list}, unicode]) of
    {match, [Host, Path]} ->
      {ok, {Host, filename:rootname(Path, ".git")}};
    nomatch ->
      parse_git_url(not_scp, Url)
  end.
parse_git_url(not_scp, Url) ->
  UriOpts = [{scheme_defaults, [{git, 9418} | http_uri:scheme_defaults()]}],
  case http_uri:parse(Url, UriOpts) of
    {ok, {_Scheme, _User, Host, _Port, Path, _Query}} ->
      {ok, {Host, filename:rootname(Path, ".git")}};
    {error, Reason} ->
      {error, Reason}
  end.

download(TmpDir, AppInfo, State, ResourceState) ->
  check_type_support(),
  CacheDir = filename:join(cache_dir(ResourceState), rebar_app_info:name(AppInfo)),
  ok = rebar_file_utils:rm_rf(CacheDir),
  ?DEBUG("download source=~p to=~p~n", [rebar_app_info:source(AppInfo), CacheDir]),
  case download_(CacheDir, rebar_app_info:source(AppInfo), State) of
    {ok, _} ->
      AppInfos = rebar_app_discover:find_apps([filename:join(CacheDir, "**")], invalid),
      lists:foreach(fun(Info) ->
                        Profiles = rebar_app_info:profiles(Info),
                        [?INFO("name=~p dir=~p profiles=~p deps=~p~n",
                               [rebar_app_info:name(Info),
                                rebar_app_info:dir(Info),
                                Profile,
                                rebar_app_info:get(
                                  replace_local_deps(Info, rebar_app_info:source(AppInfo)),
                                  {deps, Profile})
                               ]) || Profile <- Profiles]
                    end, AppInfos),
      case find_app(AppInfos, rebar_app_info:name(AppInfo)) of
        {ok, AppInfo1} ->
          AppInfo2 = replace_local_deps(AppInfo1, rebar_app_info:source(AppInfo)),
          ?DEBUG("copy local path ~p to ~p", [rebar_app_info:dir(AppInfo2), TmpDir]),
          ok = rebar3_cargo_util:copy(rebar_app_info:dir(AppInfo2), TmpDir),

          ok;
        error ->
          throw({error, {?MODULE, {dep_app_not_found, rebar_app_info:name(AppInfo)}}})
      end;

    {error, Reason} ->
      {error, Reason};
    Error ->
      {error, Error}
  end.

find_app([AppInfo | Rest], Name) ->
  case rebar_app_info:name(AppInfo) of
    Name -> {ok, AppInfo};
    _ -> find_app(Rest, Name)
  end;
find_app([], _Name) ->
  error.

replace_local_deps(AppInfo, Source) ->
  %Profiles = rebar_app_info:profiles(AppInfo),
  Dir = rebar_app_info:dir(AppInfo),
  Config = rebar_config:consult(Dir),
  ?INFO("config=~p~n", [Config]),
  Deps = proplists:get_value(deps, Config, []),
  Config1 = lists:keyreplace(deps, 1, Config, {deps, replace_path_dep(Deps, Source, [])}),
  Profiles = proplists:get_value(profiles, Config, []),
  Profiles2 = lists:foldl(
              fun({Name, Opts}, Profiles1) ->
                  ProfileDeps = proplists:get_value(deps, Opts, []),
                  Opts2 = lists:keyreplace(
                            deps, 1, Opts, {deps, replace_path_dep(ProfileDeps, Source, [])}
                           ),
                  [{Name, Opts2} | Profiles1]
              end, [], Profiles),
  Config2 = lists:keyreplace(profiles, 1, Config1, {profiles, Profiles2}),

  if
    Config /= Config2 ->
      ok =rebar3_cargo_util:write_terms(filename:join(Dir, ?DEFAULT_CONFIG_FILE), Config2),

      rebar_app_info:update_opts(AppInfo, rebar_app_info:opts(AppInfo), Config2);
    true ->
      AppInfo
  end.

replace_path_dep([{Name, {path, _}} | Rest], Source, Deps) ->
  replace_path_dep(Rest, Source, [{Name, Source} | Deps]);
replace_path_dep([Dep | Rest], Source, Deps) ->
  replace_path_dep(Rest, Source, [Dep | Deps]);
replace_path_dep([], _Source, Deps) ->
  lists:reverse(Deps).




download_(Dir, {git, Url}, State) ->
  ?WARN("WARNING: It is recommended to use {branch, Name}, {tag, Tag} or {ref, Ref}, otherwise updating the dep may not work as expected.", []),
  download_(Dir, {git, Url, {branch, "master"}}, State);
download_(Dir, {git, Url, ""}, State) ->
  ?WARN("WARNING: It is recommended to use {branch, Name}, {tag, Tag} or {ref, Ref}, otherwise updating the dep may not work as expected.", []),
  download_(Dir, {git, Url, {branch, "master"}}, State);
download_(Dir, {git, Url, {branch, Branch}}, _State) ->
  ok = filelib:ensure_dir(Dir),
  maybe_warn_local_url(Url),
  git_clone(branch, git_vsn(), Url, Dir, Branch);
download_(Dir, {git, Url, {tag, Tag}}, _State) ->
  ok = filelib:ensure_dir(Dir),
  maybe_warn_local_url(Url),
  git_clone(tag, git_vsn(), Url, Dir, Tag);
download_(Dir, {git, Url, {ref, Ref}}, _State) ->
  ok = filelib:ensure_dir(Dir),
  maybe_warn_local_url(Url),
  git_clone(ref, git_vsn(), Url, Dir, Ref);
download_(Dir, {git, Url, Rev}, _State) ->
  ?WARN("WARNING: It is recommended to use {branch, Name}, {tag, Tag} or {ref, Ref}, otherwise updating the dep may not work as expected.", []),
  ok = filelib:ensure_dir(Dir),
  maybe_warn_local_url(Url),
  git_clone(rev, git_vsn(), Url, Dir, Rev).

maybe_warn_local_url(Url) ->
  WarnStr = "Local git resources (~ts) are unsupported and may have odd behaviour. "
  "Use remote git resources, or a plugin for local dependencies.",
  case parse_git_url(Url) of
    {error, no_scheme} -> ?WARN(WarnStr, [Url]);
    {error, {no_default_port, _, _}} -> ?WARN(WarnStr, [Url]);
    {error, {malformed_url, _, _}} -> ?WARN(WarnStr, [Url]);
    _ -> ok
  end.

%% Use different git clone commands depending on git --version
git_clone(branch,Vsn,Url,Dir,Branch) when Vsn >= {1,7,10}; Vsn =:= undefined ->
  rebar_utils:sh(?FMT("git clone ~ts ~ts -b ~ts --single-branch",
                      [rebar_utils:escape_chars(Url),
                       rebar_utils:escape_chars(filename:basename(Dir)),
                       rebar_utils:escape_chars(Branch)]),
                 [{cd, filename:dirname(Dir)}]);
git_clone(branch,_Vsn,Url,Dir,Branch) ->
  rebar_utils:sh(?FMT("git clone ~ts ~ts -b ~ts",
                      [rebar_utils:escape_chars(Url),
                       rebar_utils:escape_chars(filename:basename(Dir)),
                       rebar_utils:escape_chars(Branch)]),
                 [{cd, filename:dirname(Dir)}]);
git_clone(tag,Vsn,Url,Dir,Tag) when Vsn >= {1,7,10}; Vsn =:= undefined ->
  rebar_utils:sh(?FMT("git clone ~ts ~ts -b ~ts --single-branch",
                      [rebar_utils:escape_chars(Url),
                       rebar_utils:escape_chars(filename:basename(Dir)),
                       rebar_utils:escape_chars(Tag)]),
                 [{cd, filename:dirname(Dir)}]);
git_clone(tag,_Vsn,Url,Dir,Tag) ->
  rebar_utils:sh(?FMT("git clone ~ts ~ts -b ~ts",
                      [rebar_utils:escape_chars(Url),
                       rebar_utils:escape_chars(filename:basename(Dir)),
                       rebar_utils:escape_chars(Tag)]),
                 [{cd, filename:dirname(Dir)}]);
git_clone(ref,_Vsn,Url,Dir,Ref) ->
  rebar_utils:sh(?FMT("git clone -n ~ts ~ts",
                      [rebar_utils:escape_chars(Url),
                       rebar_utils:escape_chars(filename:basename(Dir))]),
                 [{cd, filename:dirname(Dir)}]),
  rebar_utils:sh(?FMT("git checkout -q ~ts", [Ref]), [{cd, Dir}]);
git_clone(rev,_Vsn,Url,Dir,Rev) ->
  rebar_utils:sh(?FMT("git clone -n ~ts ~ts",
                      [rebar_utils:escape_chars(Url),
                       rebar_utils:escape_chars(filename:basename(Dir))]),
                 [{cd, filename:dirname(Dir)}]),
  rebar_utils:sh(?FMT("git checkout -q ~ts", [rebar_utils:escape_chars(Rev)]),
                 [{cd, Dir}]).

git_vsn() ->
  case application:get_env(rebar, git_vsn) of
    {ok, Vsn} -> Vsn;
    undefined ->
      Vsn = git_vsn_fetch(),
      application:set_env(rebar, git_vsn, Vsn),
      Vsn
  end.

git_vsn_fetch() ->
  case rebar_utils:sh("git --version",[]) of
    {ok, VsnStr} ->
      case re:run(VsnStr, "git version\\h+(\\d)\\.(\\d)\\.(\\d).*", [{capture,[1,2,3],list}, unicode]) of
        {match,[Maj,Min,Patch]} ->
          {list_to_integer(Maj),
           list_to_integer(Min),
           list_to_integer(Patch)};
        nomatch ->
          undefined
      end;
    {error, _} ->
      undefined
  end.

make_vsn(AppInfo, ResourceState) ->
  CacheDir = filename:join(cache_dir(ResourceState), rebar_app_info:name(AppInfo)),
  make_vsn_(CacheDir).

make_vsn_(Dir) ->
  case collect_default_refcount(Dir) of
    Vsn={plain, _} ->
      Vsn;
    {Vsn, RawRef, RawCount} ->
      {plain, build_vsn_string(Vsn, RawRef, RawCount)}
  end.

%% Internal functions

collect_default_refcount(Dir) ->
  %% Get the tag timestamp and minimal ref from the system. The
  %% timestamp is really important from an ordering perspective.
  case rebar_utils:sh("git log -n 1 --pretty=format:\"%h\n\" ",
                      [{use_stdout, false},
                       return_on_error,
                       {cd, Dir}]) of
    {error, _} ->
      ?WARN("Getting log of git dependency failed in ~ts. Falling back to version 0.0.0", [rebar_dir:get_cwd()]),
      {plain, "0.0.0"};
    {ok, String} ->
      RawRef = rebar_string:trim(String, both, "\n"),

      {Tag, TagVsn} = parse_tags(Dir),
      {ok, RawCount} =
      case Tag of
        undefined ->
          AbortMsg2 = "Getting rev-list of git depedency failed in " ++ Dir,
          {ok, PatchLines} = rebar_utils:sh("git rev-list HEAD",
                                            [{use_stdout, false},
                                             {cd, Dir},
                                             {debug_abort_on_error, AbortMsg2}]),
          rebar_utils:line_count(PatchLines);
        _ ->
          get_patch_count(Dir, Tag)
      end,
      {TagVsn, RawRef, RawCount}
  end.

build_vsn_string(Vsn, RawRef, Count) ->
  %% Cleanup the tag and the Ref information. Basically leading 'v's and
  %% whitespace needs to go away.
  RefTag = [".ref", re:replace(RawRef, "\\s", "", [global, unicode])],

  %% Create the valid [semver](http://semver.org) version from the tag
  case Count of
    0 ->
      rebar_utils:to_list(Vsn);
    _ ->
      rebar_utils:to_list([Vsn, "+build.", integer_to_list(Count), RefTag])
  end.

get_patch_count(Dir, RawRef) ->
  AbortMsg = "Getting rev-list of git dep failed in " ++ Dir,
  Ref = re:replace(RawRef, "\\s", "", [global, unicode]),
  Cmd = io_lib:format("git rev-list ~ts..HEAD",
                      [rebar_utils:escape_chars(Ref)]),
  {ok, PatchLines} = rebar_utils:sh(Cmd,
                                    [{use_stdout, false},
                                     {cd, Dir},
                                     {debug_abort_on_error, AbortMsg}]),
  rebar_utils:line_count(PatchLines).


parse_tags(Dir) ->
  %% Don't abort on error, we want the bad return to be turned into 0.0.0
  case rebar_utils:sh("git -c color.ui=false log --oneline --no-walk --tags --decorate",
                      [{use_stdout, false}, return_on_error, {cd, Dir}]) of
    {error, _} ->
      {undefined, "0.0.0"};
    {ok, Line} ->
      case re:run(Line, "(\\(|\\s)(HEAD[^,]*,\\s)tag:\\s(v?([^,\\)]+))", [{capture, [3, 4], list}, unicode]) of
        {match,[Tag, Vsn]} ->
          {Tag, Vsn};
        nomatch ->
          case rebar_utils:sh("git describe --tags --abbrev=0",
                              [{use_stdout, false}, return_on_error, {cd, Dir}]) of
            {error, _} ->
              {undefined, "0.0.0"};
            %% strip the v prefix if it exists like is done in the above match
            {ok, [$v | LatestVsn]} ->
              {undefined, rebar_string:trim(LatestVsn, both, "\n")};
            {ok, LatestVsn} ->
              {undefined, rebar_string:trim(LatestVsn,both, "\n")}
          end
      end
  end.

check_type_support() ->
  case get({is_supported, ?MODULE}) of
    true ->
      ok;
    _ ->
      case rebar_utils:sh("git --version", [{return_on_error, true},
                                            {use_stdout, false}]) of
        {error, _} ->
          ?ABORT("git not installed", []);
        _ ->
          put({is_supported, ?MODULE}, true),
          ok
      end
  end.
