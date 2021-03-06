-module(active).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, build/0, build_sync/0, rebar_log/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {last, root}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

build() ->
    gen_server:cast(?SERVER, build).

build_sync() ->
    gen_server:call(?SERVER, build).

rebar_log(Format, Message) ->
    case application:get_application(lager) of
        {ok, lager} -> lager:log(info, [{app, rebar}], Format, Message);
        undefined -> error_logger:format(Format, Message)
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
    erlfsmon:subscribe(),
    rebar_log:init(rebar_config:new()),

    erlang:process_flag(priority, low),

    {ok, #state{last=fresh, root=erlfsmon:path()}}.

handle_call(build, _From, State) ->
    run_rebar(compile, rebar_conf([])),
    {reply, State#state{last=user_sync_build}};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(build, State) ->
    run_rebar(compile, rebar_conf([])),
    {noreply, State#state{last=user_build}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({_Pid, {erlfsmon,file_event}, {Path, Flags}}, #state{root=Root} = State) ->
    Cur = path_shorten(filename:split(Root)),
    P = filename:split(Path),

    Result = case lists:prefix(Cur, P) of
        true ->
            Components = P -- Cur,
            %error_logger:info_msg("event: ~p ~p", [Components, Flags]),
            path_event(Components, Flags);
        false ->
            ok
    end,

    {noreply, State#state{last={event, Path, Flags, Result}}};
handle_info({load_ebin, Atom}, State) ->
    do_load_ebin(Atom),
    {noreply, State#state{last={do_load_ebin, Atom}}};
handle_info(Info, State) ->
    {noreply, State#state{last={unk, Info}}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

path_event(C, [E|_Events]) when
        E =:= created;
        E =:= modified;
        E =:= renamed ->
    case path_filter(C) of
        true -> path_modified_event(C);
        false -> ignore
    end;
path_event(C, [_E|Events]) ->
    path_event(C, Events);
path_event(_, []) ->
    done.

path_modified_event([P, Name|Px] = _Path) when P =:= "apps"; P =:= "deps" ->
    app_modified_event(Name, Px);

path_modified_event([D|Px] = _Path) when D =:= "src"; D =:= "priv"; D =:= "c_src"; D =:= "ebin" ->
    app_modified_event(toplevel_app(), [D|Px]);

path_modified_event(P) ->
    error_logger:warning_msg("active: unhandled path: ~p", [P]),
    dont_care.

app_modified_event(_App, ["ebin", EName|_] = _Path) ->
    load_ebin(EName);
app_modified_event(App, [D|_] = _Path) when D =:= "src"; D =:= "priv"; D =:= "c_src" ->
    run_rebar(compile, rebar_conf([{apps, App}]));
app_modified_event(App, P) ->
    error_logger:warning_msg("active: app ~p; unhandled path: ~p", [App, P]).

toplevel_app() -> lists:last(filename:split(filename:absname(""))).

rebar_default_conf() ->
    rebar_default_conf(filename:absname("")).

rebar_default_conf(RootDir) ->
    ConfFile = filename:join([RootDir, "rebar.config"]),
    C1 = case filelib:is_file(ConfFile) of
        true ->
            C = rebar_config:new(ConfFile),
            setelement(2, C, RootDir); % C#config.dir
        false ->
            rebar_config:base_config(rebar_config:new())
    end,

    %% Keep track of how many operations we do, so we can detect bad commands
    C2 = rebar_config:set_xconf(C1, operations, 0),

    %% Initialize vsn cache
    C3 = rebar_config:set_xconf(C2, vsn_cache, dict:new()),

    %%% Determine the location of the rebar executable; important for pulling
    %%% resources out of the escript
    %ScriptName = filename:absname(escript:script_name()),
    %BaseConfig1 = rebar_config:set_xconf(BaseConfig, escript, ScriptName),
    %?DEBUG("Rebar location: ~p\n", [ScriptName]),

    %% Note the top-level directory for reference
    AbsCwd = filename:absname(rebar_utils:get_cwd()),
    C4 = rebar_config:set_xconf(C3, base_dir, AbsCwd),
    C4.

rebar_conf([{Key, Value}|Args], Conf) ->
    rebar_conf(Args, rebar_config:set_global(Conf, Key, Value));
rebar_conf([], Conf) ->
    Conf.

rebar_conf(Args) -> rebar_conf(Args, rebar_default_conf()).

run_rebar(Commands, Conf) when is_list(Commands) ->
    {ok, Cwd} = file:get_cwd(),
    %%% XXX: rebar must not clobber the current directory in the future
    try rebar_core:process_commands(Commands, Conf) of
        R -> R
    catch
        Err:Reason ->
            file:set_cwd(Cwd),
            error_logger:error_msg("active: rebar failed: ~p ~p", [{Err, Reason}, erlang:get_stacktrace()]),
            {error, {Err, Reason}}
    end;
run_rebar(Command, Conf) ->
    run_rebar([Command], Conf).

%%
%% TODO: discover any compile callbacks in rebar and stop using filesystem events for beam loads
%%
load_ebin(EName) ->
    Tokens = string:tokens(EName, "."),
    case Tokens of
        [Name, "beam"] ->
            do_load_ebin(list_to_atom(Name));
        [Name, "bea#"] ->
            case monitor_handles_renames() of
                false ->
                    erlang:send_after(500, ?SERVER, {load_ebin, list_to_atom(Name)}),
                    delayed;
                true ->
                    ignored
            end;
        %[Name, Smth] -> ok;
        _ ->
            error_logger:warning_msg("load_ebin: unknown ebin file: ~p", [EName]),
            ok
    end.

do_load_ebin(Module) ->
    {Module, Binary, Filename} = code:get_object_code(Module),
    code:load_binary(Module, Filename, Binary),
    error_logger:info_msg("active: module loaded: ~p", [Module]),
    reloaded.

monitor_handles_renames([renamed|_]) -> true;
monitor_handles_renames([_|Events]) -> monitor_handles_renames(Events);
monitor_handles_renames([]) -> false.

monitor_handles_renames() ->
    case get(monitor_handles_renames) of
        undefined ->
            R = monitor_handles_renames(erlfsmon:known_events()),
            put(monitor_handles_renames, R),
            R;
        V -> V
    end.

% ["a", "b", ".."] -> ["a"]
path_shorten(Coms) ->
    path_shorten_r(lists:reverse(Coms), [], 0).

path_shorten_r([".."|Rest], Acc, Count) ->
    path_shorten_r(Rest, Acc, Count + 1);
path_shorten_r(["."|Rest], Acc, Count) ->
    path_shorten_r(Rest, Acc, Count);
path_shorten_r([_C|Rest], Acc, Count) when Count > 0 ->
    path_shorten_r(Rest, Acc, Count - 1);
path_shorten_r([C|Rest], Acc, 0) ->
    path_shorten_r(Rest, [C|Acc], 0);
path_shorten_r([], Acc, _) ->
    Acc.

%
% Filters
%

path_filter(L) ->
    not lists:any(fun(E) -> not path_filter_dir(E) end, L) andalso path_filter_last(lists:last(L)).

path_filter_dir(".git") -> false;
path_filter_dir(".hg")  -> false;
path_filter_dir(".svn") -> false;
path_filter_dir("CVS")  -> false;
path_filter_dir("log")  -> false;
path_filter_dir(_)      -> true.

path_filter_last(".rebarinfo")     -> false;   % new rebars
path_filter_last("LICENSE")        -> false;
path_filter_last("4913 (deleted)") -> false;   % vim magical file
path_filter_last("4913")           -> false;
path_filter_last(_)                -> true.
