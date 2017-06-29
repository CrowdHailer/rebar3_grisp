-module(rebar3_grisp_build).

% Callbacks
-export([init/1]).
-export([do/1]).
-export([format_error/1]).

-include_lib("kernel/include/file.hrl").

%--- Callbacks -----------------------------------------------------------------

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {namespace, grisp},
            {name, build},
            {module, ?MODULE},
            {bare, true},
            {deps, [{default, install_deps}]},
            {example, "rebar3 grisp build"},
            {opts, [
                {clean, $c, "clean", boolean, false}
            ]},
            {profiles, [default]},
            {short_desc, "Build a custom Erlang/OTP system for GRiSP"},
            {desc,
"Build a custom Erlang/OTP system for GRiSP.
"
            }
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    {Opts, _Rest} = rebar_state:command_parsed_args(State),
    Config = rebar_state:get(State, grisp, []),
    URL = "https://github.com/grisp/otp",
    Platform = "grisp_base",
    {ok, CWD} = file:get_cwd(),
    Root = filename:join(CWD, "_grisp"),
    Version = "19.3.6",
    OTPRoot = filename:join([Root, "otp", Version]),
    BuildRoot = filename:join(OTPRoot, "build"),
    InstallRoot = filename:join(OTPRoot, "install"),
    info("Checking out Erlang/OTP ~s", [Version]),
    ensure_clone(URL, BuildRoot, Version, Opts),
    Apps = apps(State),
    info("Preparing GRiSP code"),
    copy_code(Apps, Platform, BuildRoot),
    info("Building"),
    build(Config, BuildRoot, InstallRoot),
    info("Done"),
    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%--- Internal ------------------------------------------------------------------

ensure_clone(URL, Dir, Version, Opts) ->
    Branch = "grisp/OTP-" ++ Version,
    ok = filelib:ensure_dir(Dir),
    case file:read_file_info(Dir ++ "/.git") of
        {error, enoent} ->
            console(" * Cloning...  (this may take a while)"),
            sh("git clone " ++ URL ++ " " ++ Dir);
        {ok, #file_info{type = directory}} ->
            console("* Using existing checkout"),
            ok
    end,
    sh("git checkout " ++ Branch, [{cd, Dir}]),
    sh("git reset --hard", [{cd, Dir}]),
    case rebar3_grisp_util:get(clean, Opts, false) of
        true ->
            console("* Cleaning..."),
            sh("git clean -fXd", [{cd, Dir}]),
            sh("git clean -fxd", [{cd, Dir}]);
        false ->
            ok
    end,
    ok.

apps(State) ->
    Apps = rebar_state:all_deps(State) ++ rebar_state:project_apps(State),
    {Grisp, Other} = lists:splitwith(
        fun(A) -> rebar_app_info:name(A) == <<"grisp">> end,
        Apps
    ),
    Other ++ Grisp.

copy_code(Apps, Platform, OTPRoot) ->
    console("* Copying C code..."),
    Drivers = lists:foldl(
        fun(A, D) ->
            copy_app_code(A, Platform, OTPRoot, D)
        end,
        [],
         Apps
    ),
    console("* Patching OTP..."),
    patch_otp(OTPRoot, Drivers).

copy_app_code(App, Platform, OTPRoot, Drivers) ->
    Source = filename:join([rebar_app_info:dir(App), "grisp", Platform]),
    copy_sys(Source, OTPRoot),
    Drivers ++ copy_drivers(Source, OTPRoot).

copy_sys(Source, OTPRoot) ->
    copy_files(
        {Source, "sys/*.c"},
        {OTPRoot, "erts/emulator/sys/unix"}
    ).

copy_drivers(Source, OTPRoot) ->
    copy_files(
        {Source, "drivers/*.c"},
        {OTPRoot, "erts/emulator/drivers/unix"}
    ).

copy_files({SourceRoot, Pattern}, Target) ->
    Files = filelib:wildcard(filename:join(SourceRoot, Pattern)),
    [copy_file(F, Target) || F <- Files].

copy_file(Source, {TargetRoot, TargetDir}) ->
    Base = filename:basename(Source),
    TargetFile = filename:join(TargetDir, Base),
    Target = filename:join(TargetRoot, TargetFile),
    rebar_api:debug("GRiSP - Copy ~p -> ~p", [Source, Target]),
    {ok, _} = file:copy(Source, Target),
    TargetFile.

patch_otp(OTPRoot, Drivers) ->
    Template = bbmustache:parse_file(
        filename:join(code:priv_dir(rebar3_grisp), "patches/otp.patch.mustache")
    ),
    Context = [
        {erts_emulator_makefile_in, [
            {lines, 10 + length(Drivers)},
            {drivers, [[{name, filename:basename(N, ".c")}] || N <- Drivers]}
        ]}
    ],
    Patch = bbmustache:compile(Template, Context, [{key_type, atom}]),
    ok = file:write_file(filename:join(OTPRoot, "otp.patch"), Patch),
    sh("git apply otp.patch", [{cd, OTPRoot}]),
    sh("rm otp.patch", [{cd, OTPRoot}]).

build(Config, BuildRoot, InstallRoot) ->
    TcRoot = rebar3_grisp_util:get([toolchain, root], Config),
    PATH = os:getenv("PATH"),
    Opts = [{cd, BuildRoot}, {env, [
        {"GRISP_TC_ROOT", TcRoot},
        {"PATH", TcRoot ++ "/bin:" ++ PATH}
    ]}],
    rebar_api:debug("~p", [Opts]),
    console("* Running autoconf..."),
    sh("./otp_build autoconf", Opts),
    console("* Running configure...  (this may take a while)"),
    sh("./otp_build configure --xcomp-conf=xcomp/erl-xcomp-arm-rtems.conf --disable-threads --prefix=/", Opts),
    console("* Building...  (this may take a while)"),
    sh("./otp_build boot -a", Opts),
    console("* Installing..."),
    sh("make install DESTDIR=\"" ++ InstallRoot ++ "\"", Opts),
    sh("mv lib lib.old", [{cd, InstallRoot}]),
    sh("mv lib.old/erlang/* .", [{cd, InstallRoot}]),
    sh("rm -rf lib.old", [{cd, InstallRoot}]).

info(Msg) -> info(Msg, []).
info(Msg, Args) -> rebar_api:info(Msg, Args).

console(Msg) -> console(Msg, []).
console(Msg, Args) -> rebar_api:console(Msg, Args).

sh(Command) -> sh(Command, []).
sh(Command, Args) ->
    {ok, Output} = rebar_utils:sh(Command, [abort_on_error] ++ Args),
    Output.
