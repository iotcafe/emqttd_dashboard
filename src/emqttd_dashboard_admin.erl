%%--------------------------------------------------------------------
%% Copyright (c) 2015-2016 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Web dashboard admin authentication with username and password.
-module(emqttd_dashboard_admin).

-behaviour(gen_server).

-include("emqttd_dashboard.hrl").

%% API Function Exports
-export([start_link/0]).

%%mqtt_admin api
-export([add_user/3, remove_user/1, update_user/3, lookup_user/1,
         all_users/0, check/2]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-spec(start_link() -> {ok, pid()} | ignore | {error, any()}).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(add_user(binary(), binary(), binary()) -> ok | {error, any()}).
add_user(Username, Password, Tags) when is_binary(Username), is_binary(Password) ->
    Admin = #mqtt_admin{username = Username, password = hash(Password), tags = Tags},
    return(mnesia:transaction(fun add_user_/1, [Admin])).

%% @private
add_user_(Admin = #mqtt_admin{username = Username}) ->
    case mnesia:wread({mqtt_admin, Username}) of
        []  -> mnesia:write(Admin);
        [_] -> mnesia:abort("username already exist")
    end.

-spec(remove_user(binary()) -> ok | {error, any()}).
remove_user(Username) when is_binary(Username) ->
    return(mnesia:transaction(fun mnesia:delete/1, [{mqtt_admin, Username}])).

-spec(update_user(binary(), binary(), binary()) -> ok | {error, any()}).
update_user(Username, Password, Tags) when is_binary(Username), is_binary(Password) ->
    Admin = #mqtt_admin{username = Username, password = hash(Password), tags = Tags},
    return(mnesia:transaction(fun update_user_/1, [Admin])).

%% @private
update_user_(Admin = #mqtt_admin{username = Username}) ->
    case mnesia:wread({mqtt_admin, Username}) of
        []  -> mnesia:abort("username not found");
        [_] -> mnesia:write(Admin)
    end.

-spec(lookup_user(binary()) -> [mqtt_admin()]).
lookup_user(Username) when is_binary(Username) -> mnesia:dirty_read(mqtt_admin, Username).

-spec(all_users() -> [binary()]).
all_users() -> mnesia:dirty_all_keys(mqtt_admin).

return({atomic, _}) ->
    ok;
return({aborted, Reason}) ->
    {error, Reason}.

check(undefined, _) ->
    {error, "Username undefined"};
check(_, undefined) ->
    {error, "Password undefined"};
check(Username, Password) ->
    case lookup_user(Username) of
        [#mqtt_admin{password = <<Salt:4/binary, Hash/binary>>}] ->
            case Hash =:= md5_hash(Salt, Password) of
                true  -> ok;
                false -> {error, "Password Error"}
            end;
        [] ->
            {error, "Username Not Found"}
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    % Create mqtt_admin table
    ok = emqttd_mnesia:create_table(mqtt_admin, [
                {type, set},
                {disc_copies, [node()]},
                {record_name, mqtt_admin},
                {attributes, record_info(fields, mqtt_admin)}]),
    ok = emqttd_mnesia:copy_table(mqtt_admin),
    %% Wait???
    %% mnesia:wait_for_tables([mqtt_admin], 5000),
    % Init mqtt_admin table
    case mnesia:table_info(mqtt_admin, size) of
        0 ->
            Admin = case application:get_env(emqttd_dashboard, default_admin) of
                {ok, Default} ->
                    #mqtt_admin{username = bin(proplists:get_value(login, Default)),
                                password = hash(bin(proplists:get_value(password, Default))),
                                tags = <<"administrator">>};
                undefined -> %% 
                    #mqtt_admin{username = <<"admin">>,
                                password = hash(<<"public">>),
                                tags = <<"administrator">>}
            end,
            mnesia:transaction(fun mnesia:write/1, [Admin]);
        _ ->
            %% Fix issue #24 
            mnesia:transaction(fun() ->
                AtomNames = [Key || Key <- mnesia:all_keys(mqtt_admin), is_atom(Key)],
                lists:foreach(fun(Name) ->
                    case mnesia:read(mqtt_admin, Name, write) of
                        [Admin] ->
                            mnesia:delete({mqtt_admin, Name}),
                            mnesia:write(Admin#mqtt_admin{username = bin(Admin)});
                        [] ->
                            ok
                    end
                end, AtomNames)
           end)
    end,
    {ok, state}.

handle_call(_Req, _From, State) ->
    {reply, error,  State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

hash(Password) ->
    SaltBin = salt(),
    <<SaltBin/binary, (md5_hash(SaltBin, Password))/binary>>.

md5_hash(SaltBin, Password) ->
    erlang:md5(<<SaltBin/binary, Password/binary>>).

salt() ->
    emqttd_time:seed(),
    Salt = random:uniform(16#ffffffff),
    <<Salt:32>>.

bin(S) when is_list(S)   -> list_to_binary(S);
bin(A) when is_atom(A)   -> bin(atom_to_list(A));
bin(B) when is_binary(B) -> B.

