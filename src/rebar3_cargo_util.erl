-module(rebar3_cargo_util).

-export([copy/2,
         copy_file_info/2]).

-export([write_terms/2]).

-include("rebar3_cargo.hrl").

copy(From, To) ->
  case filelib:is_dir(From) of
    false -> copy_(From, To);
    true ->
      make_dir_if_dir(To),
      copy_file_info(From, To),
      copy_subfiles(From, To)
  end.

copy_(From, To) ->
  case file:copy(From, To) of
    {ok, _} ->
      copy_file_info(From, To);
    {error, Error} ->
      {error,  {copy_failed, Error}}
  end.

copy_file_info(From, To) ->
  case file:read_file_info(From) of
    {ok, FileInfo} ->
      file:write_file_info(To, FileInfo);
    Error ->
      {error, {copy_failed, Error}}
  end.


%% Copy the subfiles of the From directory to the to directory.
copy_subfiles(From, To) ->
  Fun =
  fun(ChildFrom) ->
      ChildTo = filename:join([To, filename:basename(ChildFrom)]),
      copy(ChildFrom, ChildTo)
  end,
  lists:foreach(Fun, sub_files(From)).

-spec make_dir_if_dir(file:name()) -> ok | {error, Reason::term()}.
make_dir_if_dir(File) ->
  case filelib:is_dir(File) of
    true  -> ok;
    false ->
      ec_file:mkdir_p(File)
  end.


sub_files(From) ->
  {ok, SubFiles} = file:list_dir(From),
  [filename:join(From, SubFile) || SubFile <- SubFiles].

write_terms(Filename, List) ->
  Format = fun(Term) -> io_lib:format("~tp.~n", [Term]) end,
  Text = lists:map(Format, List),
  file:write_file(Filename, Text).
