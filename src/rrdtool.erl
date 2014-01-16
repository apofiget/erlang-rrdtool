%%% Copyright 2009 Andrew Thompson <andrew@hijacked.us>. All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%%   1. Redistributions of source code must retain the above copyright notice,
%%%      this list of conditions and the following disclaimer.
%%%   2. Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR
%%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
%%% EVENT SHALL THE FREEBSD PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
%%% INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

% @doc An erlang module to interface with rrdtool's remote control mode as an
% erlang port.
-module(rrdtool).

-behaviour(gen_server).

% public API
-export([
		start/0,
		start/1,
		start_link/0,
		start_link/1,
		stop/1,
		create/5,
		update/3,
		update/4,
		cached_update/3,
		cached_update/4,
		cached_update/5,
		fetch/5,
		fetch/6
]).

% gen_server callbacks
-export([init/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
]).

-define(STORE_TYPES,
	['GAUGE', 'COUNTER', 'DERIVE', 'ABSOLUTE', 'COMPUTE']).

-include_lib("kernel/include/file.hrl").

% public API

start() ->
	gen_server:start(?MODULE, [os:find_executable("rrdtool")], []).

start(RRDTool) when is_list(RRDTool) ->
	gen_server:start(?MODULE, [RRDTool], []);

start({socket, SocketFile}) when is_list(SocketFile) ->
	gen_server:start(?MODULE, [{socket, SocketFile, 300}], []).

start_link() ->
	gen_server:start_link(?MODULE, [os:find_executable("rrdtool")], []).

start_link(RRDTool) when is_list(RRDTool) ->
	gen_server:start_link(?MODULE, [RRDTool], []);

start_link({socket, SocketFile}) when is_list(SocketFile) ->
	gen_server:start_link(?MODULE, [{socket, SocketFile, 300}], []).

stop(Pid) ->
	gen_server:call(Pid, stop).

create(Pid, Filename, Datastores, RRAs, Options) ->
	gen_server:call(Pid, {create, Filename, format_datastores(Datastores), format_archives(RRAs), format_create_options(Options)}, infinity).

update(Pid, Filename, DatastoreValues) ->
	gen_server:call(Pid, {update, Filename, format_datastore_values(DatastoreValues), n}, infinity).

update(Pid, Filename, DatastoreValues, Time) ->
	gen_server:call(Pid, {update, Filename, format_datastore_values(DatastoreValues), Time}, infinity).

cached_update({socket, Pid}, Filename, Values) ->
	gen_server:call(Pid, {cached_update, Filename, Values, n}, 30000).

cached_update({socket, Pid}, Filename, Values, Time) ->
	gen_server:call(Pid, {cached_update, Filename, Values, Time}, 30000);

cached_update(Pid, SockFile, Filename, Values) ->
	gen_server:call(Pid, {cached_update, SockFile, Filename, Values, n}, 30000).

cached_update(Pid, SockFile, Filename, Values, Time) ->
	gen_server:call(Pid, {cached_update, SockFile, Filename, Values, Time}, 30000).

fetch(Pid, Filename, Cf, Rz, STime) ->
	gen_server:call(Pid, {fetch, Filename, Cf, Rz, STime, "now"}, infinity).

fetch(Pid, Filename, Cf, Rz, STime, ETime) ->
	gen_server:call(Pid, {fetch, Filename, Cf, Rz, STime, ETime}, infinity).


% gen_server callbacks

%% @hidden
init([{socket, SocketFile, N}]) ->
	case file:read_file_info(SocketFile) of
		{ok, Info} when Info#file_info.access =:= read_write ->	
		    case procket:socket(local, stream, 0) of
		    	{ok, Socket} ->
		    		Sf = list_to_binary(SocketFile), 
				    Sun = <<1:16/native, Sf/binary, 0:((108-byte_size(Sf))*8)>>,
				    case procket:connect(Socket, Sun) of
				    	ok -> {ok, Socket};
				    	R -> {stop, {socket_connect, R}}
				    end;
				{error, eagain} when N =:= 0 ->
					{stop, {socket_connect,{error,eagain}}};
				{error, eagain} ->
					timer:sleep(10), 
					init([{socket, SocketFile, N - 1}]);
				R ->
				 	{error, {socket_create, R}}
			end;
		{ok, _Info} -> {stop, no_write_perms_to_unix_socket};
		{error, Reason} -> {stop, Reason}
	end;

init([RRDTool]) ->
	Port = open_port({spawn_executable, RRDTool}, [{line, 10240}, {args, ["-"]}]),
	{ok, Port}.

%% @hidden
handle_call({fetch, Filename, Cf, Rz, STime, ETime}, _From, Port) when is_port(Port) ->
    Command = ["fetch ", Filename, " ", Cf, " -r ", Rz, " -s ", STime, " -e ", ETime, "\n"],
	port_command(Port, Command),
	receive
		{Port, {data, {eol, "ERROR:"++Message}}} ->
			{reply, {error, Message}, Port};
		{Port, {data,{eol,Data}}} ->
			{reply, {ok, data_fetch(Port, string:tokens(Data, " "),[])}, Port}
	end;

handle_call({create, Filename, Datastores, RRAs, Options}, _From, Port) when is_port(Port) ->
	Command = ["create ", Options, Filename, " ", string:join(Datastores, " "), " ", string:join(RRAs, " "), "\n"],
	%io:format("Command: ~p~n", [lists:flatten(Command)]),
	port_command(Port, Command),
	receive
		{Port, {data, {eol, "OK"++_}}} ->
			{reply, ok, Port};
		{Port, {data, {eol, "ERROR:"++Message}}} ->
			{reply, {error, Message}, Port}
	end;
handle_call({update, Filename, {Datastores, Values}, Time}, _From, Port) when is_port(Port) ->
	Timestamp = case Time of
		n ->
			"N";
		{Megaseconds, Seconds, _Microseconds} ->
			integer_to_list(Megaseconds) ++ integer_to_list(Seconds);
		Other when is_list(Other) ->
			Other
	end,
	Command = ["update ", Filename, " -t ", string:join(Datastores, ":"), " ", Timestamp, ":", string:join(Values, ":"), "\n"],
	%%%
	%io:format("Command: ~p~n", [lists:flatten(Command)]),
	port_command(Port, Command),
	receive
		{Port, {data, {eol, "OK"++_}}} ->
			{reply, ok, Port};
		{Port, {data, {eol, "ERROR:"++Message}}} ->
			{reply, {error, Message}, Port}
	end;
handle_call({cached_update, SockFile, Filename, Values, Time}, _From, Port) when is_port(Port) ->
	Timestamp = case Time of
		n ->
			{Mega, Seconds, _} = erlang:now(),
    		integer_to_list(Mega * 1000000 + Seconds);
		{Mega, Seconds, _Micro} ->
			integer_to_list(Mega * 1000000 + Seconds);
		Other when is_list(Other) ->
			Other
	end,
	Command = ["update ", Filename, " ", Timestamp, ":", string:join(Values, ":"), "\n"],
	%%% 
	%%%io:format("Command: ~p~n", [Buf]),
	Reply = sock_send(list_to_binary(SockFile), list_to_binary(Command), 500),
	{reply, Reply, Port};
handle_call({cached_update, Filename, Values, Time}, _From, Socket)  ->
	Timestamp = case Time of
		n ->
			{Mega, Seconds, _} = erlang:now(),
    		integer_to_list(Mega * 1000000 + Seconds);
		{Mega, Seconds, _Micro} ->
			integer_to_list(Mega * 1000000 + Seconds);
		Other when is_list(Other) ->
			Other
	end,
	Command = ["update ", Filename, " ", Timestamp, ":", string:join(Values, ":"), "\n"],
	%%% 
	%%%io:format("Command: ~p~n", [Buf]),
	Reply = sock_send(Socket, list_to_binary(Command), 500),
	{reply, Reply, Socket};

handle_call(stop, _From, State) ->
	{stop, normal, ok, State};
handle_call(Request, _From, State) ->
	{reply, {unknown_call, Request}, State}.

%% @hidden
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(Msg, State) ->
    io:format("handle_info: ~p~n", [Msg]),
    {noreply, State}.

%% @hidden

terminate(_Reason, Port) when is_port(Port) ->
	port_command(Port, "quit\n"),
	ok;
terminate(_Reason, Socket) -> procket:close(Socket), ok.

%% @hidden
code_change(_OldVsn, State, _Extra) -> {ok, State}.

% internal functions
-spec data_fetch(Port :: port(), Hd :: [ds_names], Acc :: [term()]) ->
    [{ds_name ,[{timestamp, value}]}].

data_fetch(Port, Hd, Acc) ->
    	receive
		{Port, {data, {eol, "OK"++_}}} ->
			Acc;
		{Port, {data,{eol,[]}}} ->
			data_fetch(Port,Hd, Acc);
		{Port, {data,{eol,Data}}} ->
			    [H|T] = [string:strip(List,both,$:) || List <- string:tokens(Data, " ")],
			    L = [{H,List} || List <- T],
			    data_fetch(Port, Hd, data_acc(Hd, L, Acc))
	end.

data_acc([],[], List) ->
    List;

data_acc([Hh|Ht],[H|T], List) ->
 case proplists:get_value(Hh, List) of
    undefined ->
		data_acc(Ht, T, lists:append(List,[{Hh,[H]}]));
    Values ->
		data_acc(Ht, T, lists:map(fun(El) ->
		    case proplists:get_value(Hh, [El]) of
			undefined -> El;
			Values ->
			    {Hh,lists:append(Values,[H])}
		    end
	end,List))
 end.

sock_send(Socket, Cmd, N) ->
    case procket:sendto(Socket, Cmd, 0, <<>>) of
    	ok ->
		    sock_resp(Socket, 1000);
		{error, eagain} when N =:= 0 ->
			{error, eagain};
		{error, eagain} ->
			timer:sleep(10), 
			sock_send(Socket, Cmd, N - 1);
		R ->
		 	{error, {socket_send, R}}
	end.

sock_resp(Socket, N) ->
    case procket:recvfrom(Socket, 16#FFFF) of
   		{error, eagain} when N =:= 0 ->
   			{error, {recv, eagain}};
        {error, eagain} ->
            timer:sleep(5),
            sock_resp(Socket, N - 1);
        {error, E} ->
        	{error, {recv, E}};
        {ok, Buf} ->
            {ok, Re} = re:compile("^-1."),
            case re:run(binary_to_list(Buf) , Re) of
            	nomatch -> {ok, binary_to_list(Buf)};
            	{match, _} -> {error, binary_to_list(Buf)}
            end
    end.

format_datastores(Datastores) ->
	format_datastores(Datastores, []).

format_datastores([], Acc) ->
	lists:reverse(Acc);
format_datastores([H | T], Acc) ->
	case H of
		{Name, DST, Arguments} when is_list(Name), is_atom(DST), is_list(Arguments) ->
			case re:run(Name, "^[a-zA-Z0-9_]{1,19}$", [{capture, none}]) of
				nomatch ->
					throw({error, no_match_ds_name_bad_datastore_name, Name});
				match ->
					case lists:member(DST, ?STORE_TYPES) of
						false ->
							throw({error, bad_datastore_type, DST});
						true ->
							format_datastores(T, [["DS:", Name, ":", atom_to_list(DST), ":", format_arguments(DST, Arguments)] | Acc])
					end
			end;
		_ ->
			throw({error, bad_datastore, H})
	end.

format_arguments(DST, Arguments) ->
	case DST of
		'COMPUTE' ->
			% TODO rpn expression validation
			Arguments;
		_ ->
			case Arguments of
				[Heartbeat, Min, Max] when is_integer(Heartbeat), is_integer(Min), is_integer(Max) ->
					io_lib:format("~B:~B:~B", [Heartbeat, Min, Max]);
				[Heartbeat, undefined, undefined] when is_integer(Heartbeat) ->
					io_lib:format("~B:U:U", [Heartbeat]);
				_ ->
					throw({error, bad_datastore_arguments, Arguments})
			end
	end.

format_archives(RRAs) ->
	format_archives(RRAs, []).

format_archives([], Acc) ->
	lists:reverse(Acc);
format_archives([H | T], Acc) ->
	case H of
		{CF, Xff, Steps, Rows} when CF =:= 'MAX'; CF =:= 'MIN'; CF =:= 'AVERAGE'; CF =:= 'LAST' ->
			format_archives(T, [io_lib:format("RRA:~s:~.2f:~B:~B", [CF, Xff, Steps, Rows]) | Acc]);
		_ ->
			throw({error, bad_archive, H})
	end.

format_datastore_values(DSV) ->
	format_datastore_values(DSV, [], []).

format_datastore_values([], TAcc, Acc) ->
	{lists:reverse(TAcc), lists:reverse(Acc)};
format_datastore_values([H | T], TAcc, Acc) ->
	case H of
		{Name, Value} ->
			case re:run(Name, "^[a-zA-Z0-9_]{1,19}$", [{capture, none}]) of
				nomatch ->
					throw({error, bad_datastore_name, Name});
				match ->
					format_datastore_values(T, [Name | TAcc], [value_to_list(Value) | Acc])
			end;
		_ ->
			throw({error, bad_datastore_value, H})
	end.

value_to_list(Value) when is_list(Value) ->
	Value;
value_to_list(Value) when is_integer(Value) ->
	integer_to_list(Value);
value_to_list(Value) when is_float(Value) ->
	float_to_list(Value);
value_to_list(Value) when is_binary(Value) ->
	binary_to_list(Value).

format_create_options(Options) ->
	StepOpt = case proplists:get_value(step, Options) of
		undefined ->
			[];
		Step when is_integer(Step) ->
			["-s ", integer_to_list(Step), " "]
	end,

	StartOpt = case proplists:get_value(start, Options) of
		undefined ->
			[];
		Start ->
			["-b ", value_to_list(Start), " "]
	end,

	lists:flatten([StepOpt, StartOpt]).
