%%%-------------------------------------------------------------------
%%% File    : etorrent_table.erl
%%% Author  : Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% Description : Maintenance of a set of ETS tables for etorrent.
%%%
%%% Created : 11 Nov 2010 by Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(etorrent_table).

-include("types.hrl").
-include("log.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([get_path/2, insert_path/2, delete_paths/1]).
-export([get_peer_info/1, new_peer/5, connected_peer/3,
	 foreach_peer/2, statechange_peer/2]).
-export([all_torrents/0, statechange_torrent/2, get_torrent/1, acquire_check_token/1,
	 new_torrent/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% The path map tracks file system paths and maps them to integers.
-record(path_map, {id :: {'_' | '$1' | non_neg_integer(), '_' | non_neg_integer()},
                   path :: string() | '_'}). % (IDX) File system path minus work dir

-record(peer, {pid :: pid() | '_' | '$1', % We identify each peer with it's pid.
               ip :: ip() | '_',  % Ip of peer in question
               port :: non_neg_integer() | '_', % Port of peer in question
               torrent_id :: non_neg_integer() | '_', % (IDX) Torrent Id this peer belongs to
               state :: 'seeding' | 'leeching' | '_'}).

-type(tracking_map_state() :: 'started' | 'stopped' | 'checking' | 'awaiting' | 'duplicate').

%% The tracking map tracks torrent id's to filenames, etc. It is the high-level view
-record(tracking_map, {id :: '_' | integer(), %% Unique identifier of torrent
                       filename :: '_' | string(),    %% The filename
                       supervisor_pid :: '_' | pid(), %% The Pid of who is supervising
                       info_hash :: '_' | binary() | 'unknown',
                       state :: '_' | tracking_map_state()}).



-record(state, { monitoring :: dict() }).

-ignore_xref([{start_link, 0}]).

-define(SERVER, ?MODULE).

%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% @doc Return everything we are currently tracking by their ids
% @end
-spec all_torrents() -> [term()]. % @todo: Fix as proplists
all_torrents() ->
    Objs = ets:match_object(tracking_map, '_'),
    [proplistify_tmap(O) || O <- Objs].

% @doc Alter the state of the Tracking map identified by Id
%   <p>by What (see alter_map/2).</p>
% @end
-type alteration() :: {infohash, binary()} | started | stopped.
-spec statechange_torrent(integer(), alteration()) -> ok.
statechange_torrent(Id, What) ->
    [O] = ets:lookup(tracking_map, Id),
    ets:insert(tracking_map, alter_map(O, What)),
    ok.

-spec get_torrent({infohash, binary()} | {filename, string()} | integer()) ->
			  not_found | {value, term()}. % @todo: Change term() to proplist()
get_torrent(Id) when is_integer(Id) ->
    case ets:lookup(tracking_map, Id) of
	[O] ->
	    {value, proplistify_tmap(O)};
	[] ->
	    not_found
    end;
get_torrent({infohash, IH}) ->
    case ets:match_object(tracking_map, #tracking_map { _ = '_', info_hash = IH }) of
	[O] ->
	    {value, proplistify_tmap(O)};
	[] ->
	    not_found
    end;
get_torrent({filename, FN}) ->
    case ets:match_object(tracking_map, #tracking_map { _ = '_', filename = FN }) of
	[O] ->
	    {value, proplistify_tmap(O)};
	[] ->
	    not_found
    end.

proplistify_tmap(#tracking_map { id = Id, filename = FN, supervisor_pid = SPid,
				 info_hash = IH, state = S }) ->
    [proplists:property(K,V) || {K, V} <- [{id, Id}, {filename, FN}, {supervisor, SPid},
					   {info_hash, IH}, {state, S}]].

% @doc Map a {PathId, TorrentId} pair to a Path (string()).
% @end
-spec get_path(integer(), integer()) -> {ok, string()}.
get_path(Id, TorrentId) when is_integer(Id) ->
    Pth = ets:lookup_element(path_map, {Id, TorrentId}, #path_map.path),
    {ok, Pth}.

% @doc Attempt to mark the torrent for checking.
%  <p>If this succeeds, returns true, else false</p>
% @end
-spec acquire_check_token(integer()) -> boolean().
acquire_check_token(Id) ->
    gen_server:call(?MODULE, {acquire_check_token, Id}).

% @doc Populate the #path_map table with entries. Return the Id
% <p>If the path-map entry is already there, its Id is returned straight
% away.</p>
% @end
-spec insert_path(string(), integer()) -> {value, integer()}.
insert_path(Path, TorrentId) ->
    case ets:match(path_map, #path_map { id = {'$1', '_'}, path = Path}) of
        [] ->
            Id = etorrent_counters:next(path_map),
            PM = #path_map { id = {Id, TorrentId}, path = Path},
	    true = ets:insert(path_map, PM),
            {value, Id};
	[[Id]] ->
            {value, Id}
    end.

% @doc Delete entries from the pathmap based on the TorrentId
% @end
-spec delete_paths(integer()) -> ok.
delete_paths(TorrentId) when is_integer(TorrentId) ->
    MS = [{{path_map,{'_','$1'},'_','_'},[],[{'==','$1',TorrentId}]}],
    ets:select_delete(path_map, MS),
    ok.

% @doc Find the peer matching Pid
% @todo Consider coalescing calls to this function into the select-function
% @end
-spec get_peer_info(pid()) -> not_found | {peer_info, seeding | leeching, integer()}.
get_peer_info(Pid) when is_pid(Pid) ->
    case ets:lookup(peers, Pid) of
	[] -> not_found;
	[PR] -> {peer_info, PR#peer.state, PR#peer.torrent_id}
    end.

% @doc Return all peer pids with a given torrentId
% @end
% @todo We can probably fetch this from the supervisor tree. There is
% less reason to have this then.
-spec all_peer_pids(integer()) -> {value, [pid()]}.
all_peer_pids(Id) ->
    R = ets:match(peers, #peer { torrent_id = Id, pid = '$1', _ = '_' }),
    {value, [Pid || [Pid] <- R]}.

% @doc Change the peer to a seeder
% @end
-spec statechange_peer(pid(), seeder) -> ok.
statechange_peer(Pid, seeder) ->
    [Peer] = ets:lookup(peers, Pid),
    true = ets:insert(peers, Peer#peer { state = seeding }),
    ok.

% @doc Insert a row for the peer
% @end
-spec new_peer(ip(), integer(), integer(), pid(), seeding | leeching) -> ok.
new_peer(IP, Port, TorrentId, Pid, State) ->
    true = ets:insert(peers, #peer { pid = Pid, ip = IP, port = Port,
				     torrent_id = TorrentId, state = State}),
    add_monitor(peer, Pid).

% @doc Add a new torrent
% <p>The torrent is given by File with the Supervisor pid as given to the
% database structure.</p>
% @end
-spec new_torrent(string(), pid(), integer()) -> ok.
new_torrent(File, Supervisor, Id) when is_integer(Id), is_pid(Supervisor), is_list(File) ->
    add_monitor({torrent, Id}, Supervisor),
    TM = #tracking_map { id = Id,
			 filename = File,
			 supervisor_pid = Supervisor,
			 info_hash = unknown,
			 state = awaiting},
    true = ets:insert(tracking_map, TM),
    ok.

% @doc Returns true if we are already connected to this peer.
% @end
-spec connected_peer(ip(), integer(), integer()) -> boolean().
connected_peer(IP, Port, Id) when is_integer(Id) ->
    case ets:match(peers, #peer { ip = IP, port = Port, torrent_id = Id, _ = '_'}) of
	[] -> false;
	L when is_list(L) -> true
    end.

% @doc Invoke a function on all peers matching a torrent Id
% @end
-spec foreach_peer(integer(), fun((pid()) -> term())) -> ok.
foreach_peer(Id, F) ->
    {value, Pids} = all_peer_pids(Id),
    lists:foreach(F, Pids),
    ok.

%%====================================================================

init([]) ->
    ets:new(path_map, [public, {keypos, #path_map.id}, named_table]),
    ets:new(peers, [named_table, {keypos, #peer.pid}, public]),
    ets:new(tracking_map, [named_table, {keypos, #tracking_map.id}, public]),
    {ok, #state{ monitoring = dict:new() }}.

handle_call({monitor_pid, Type, Pid}, _From, S) ->
    Ref = erlang:monitor(process, Pid),
    {reply, ok,
     S#state {
       monitoring = dict:store(Ref, {Pid, Type}, S#state.monitoring)}};
handle_call({acquire_check_token, Id}, _From, S) ->
    R = case ets:match(tracking_map, #tracking_map { _ = '_', state = checking }) of
	    [] ->
		[O] = ets:lookup(tracking_map, Id),
		ets:insert(tracking_map, O#tracking_map { state = checking }),
		true;
	    _ ->
		false
	end,
    {reply, R, S};
handle_call(Msg, _From, S) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, S}.

handle_cast(Msg, S) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, S}.

handle_info({'DOWN', Ref, _, _, _}, S) ->
    {ok, {X, Type}} = dict:find(Ref, S#state.monitoring),
    case Type of
	peer ->
	    true = ets:delete(peers, X);
	{torrent, Id} ->
	    true = ets:delete(tracking_map, Id)
    end,
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring) }};
handle_info(Msg, S) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, S}.


code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
add_monitor(Type, Pid) ->
    gen_server:call(?SERVER, {monitor_pid, Type, Pid}).

%%====================================================================
alter_map(TM, What) ->
    case What of
        {infohash, IH} ->
            TM#tracking_map { info_hash = IH };
        started ->
            TM#tracking_map { state = started };
        stopped ->
            TM#tracking_map { state = stopped }
    end.
