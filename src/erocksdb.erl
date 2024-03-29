%%======================================================================
%%
%% erocksdb: Erlang Wrapper for RocksDB (https://github.com/facebook/rocksdb)
%%
%% Copyright (c) 2012-2015 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% @doc Erlang Wrapper for RocksDB
%% @reference https://github.com/leo-project/erocksdb/blob/master/src/erocksdb.erl
%% @end
%%======================================================================
-module(erocksdb).

-export([open/2, open/3, open_with_cf/3, close/1]).
-export([list_column_families/2,create_column_family/3, drop_column_family/1]).
-export([snapshot/1, release_snapshot/1]).
-export([put/4, put/5, delete/3, delete/4, write/3, get/3, get/4]).
-export([iterator/2, iterator/3, iterators/3, iterators/4, iterator_move/2, iterator_close/1]).
-export([fold/4, fold/5, fold_keys/4, fold_keys/5]).
-export([destroy/2, repair/2, is_empty/1]).
-export([checkpoint/2]).
-export([flush/1]).
-export([count/1, count/2, status/1, status/2, status/3]).
-export([get_approximate_size/4]).
-export([get_latest_sequence_number/1]).
-export([get_updates_since/2]).
-export([next_update/1]).
-export([write_update/3]).
-export([close_updates_iterator/1]).

-export_type([db_handle/0,
              cf_handle/0,
              itr_handle/0,
              snapshot_handle/0,
              compression_type/0,
              compaction_style/0,
              access_hint/0,
              wal_recovery_mode/0]).

-on_load(init/0).

-ifdef(TEST).
-compile(export_all).
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.

%% This cannot be a separate function. Code must be inline to trigger
%% Erlang compiler's use of optimized selective receive.
-define(WAIT_FOR_REPLY(Ref),
        receive {Ref, Reply} ->
                Reply
        end).

-spec init() -> ok | {error, any()}.
init() ->
    SoName = case code:priv_dir(?MODULE) of
                 {error, bad_name} ->
                     case code:which(?MODULE) of
                         Filename when is_list(Filename) ->
                             filename:join([filename:dirname(Filename),"../priv", "erocksdb"]);
                         _ ->
                             filename:join("../priv", "erocksdb")
                     end;
                 Dir ->
                     filename:join(Dir, "erocksdb")
             end,
    erlang:load_nif(SoName, application:get_all_env(erocksdb)).

-record(db_path, {path        :: file:filename_all(),
                  target_size :: non_neg_integer()}).

-record(cf_descriptor, {name    :: string(),
                        options :: cf_options()}).

-type compression_type() :: snappy | zlib | bzip2 | lz4 | lz4h | none.
-type compaction_style() :: level | universal | fifo | none.
-type access_hint() :: normal | sequential | willneed | none.
-type wal_recovery_mode() :: tolerate_corrupted_tail_records |
                             absolute_consistency |
                             point_in_time_recovery |
                             skip_any_corrupted_records.

-opaque db_handle() :: binary().
-opaque cf_handle() :: binary().
-opaque itr_handle() :: binary().
-opaque snapshot_handle() :: binary().

-type cf_options() :: [{block_cache_size_mb_for_point_lookup, non_neg_integer()} |
                       {memtable_memory_budget, pos_integer()} |
                       {write_buffer_size,  pos_integer()} |
                       {max_write_buffer_number,  pos_integer()} |
                       {min_write_buffer_number_to_merge,  pos_integer()} |
                       {compression,  compression_type()} |
                       {num_levels,  pos_integer()} |
                       {level0_file_num_compaction_trigger,  integer()} |
                       {level0_slowdown_writes_trigger,  integer()} |
                       {level0_stop_writes_trigger,  integer()} |
                       {max_mem_compaction_level,  pos_integer()} |
                       {target_file_size_base,  pos_integer()} |
                       {target_file_size_multiplier,  pos_integer()} |
                       {max_bytes_for_level_base,  pos_integer()} |
                       {max_bytes_for_level_multiplier,  pos_integer()} |
                       {expanded_compaction_factor,  pos_integer()} |
                       {source_compaction_factor,  pos_integer()} |
                       {max_grandparent_overlap_factor,  pos_integer()} |
                       {soft_rate_limit,  float()} |
                       {hard_rate_limit,  float()} |
                       {arena_block_size,  integer()} |
                       {disable_auto_compactions,  boolean()} |
                       {purge_redundant_kvs_while_flush,  boolean()} |
                       {compaction_style,  compaction_style()} |
                       {verify_checksums_in_compaction,  boolean()} |
                       {filter_deletes,  boolean()} |
                       {max_sequential_skip_in_iterations,  pos_integer()} |
                       {inplace_update_support,  boolean()} |
                       {inplace_update_num_locks,  pos_integer()} |
                       {table_factory_block_cache_size, pos_integer()} |
                       {in_memory_mode, boolean()}].

-type db_options() :: [{total_threads, pos_integer()} |
                       {create_if_missing, boolean()} |
                       {create_missing_column_families, boolean()} |
                       {error_if_exists, boolean()} |
                       {paranoid_checks, boolean()} |
                       {max_open_files, integer()} |
                       {max_total_wal_size, non_neg_integer()} |
                       {disable_data_sync, boolean()} |
                       {use_fsync, boolean()} |
                       {db_paths, list(#db_path{})} |
                       {db_log_dir, file:filename_all()} |
                       {wal_dir, file:filename_all()} |
                       {delete_obsolete_files_period_micros, pos_integer()} |
                       {max_background_compactions, pos_integer()} |
                       {max_background_flushes, pos_integer()} |
                       {max_log_file_size, non_neg_integer()} |
                       {log_file_time_to_roll, non_neg_integer()} |
                       {keep_log_file_num, pos_integer()} |
                       {max_manifest_file_size, pos_integer()} |
                       {table_cache_numshardbits, pos_integer()} |
                       {wal_ttl_seconds, non_neg_integer()} |
                       {wal_size_limit_mb, non_neg_integer()} |
                       {manifest_preallocation_size, pos_integer()} |
                       {allow_os_buffer, boolean()} |
                       {allow_mmap_reads, boolean()} |
                       {allow_mmap_writes, boolean()} |
                       {is_fd_close_on_exec, boolean()} |
                       {skip_log_error_on_recovery, boolean()} |
                       {stats_dump_period_sec, non_neg_integer()} |
                       {advise_random_on_open, boolean()} |
                       {access_hint, access_hint()} |
                       {compaction_readahead_size, non_neg_integer()} |
                       {use_adaptive_mutex, boolean()} |
                       {bytes_per_sync, non_neg_integer()} |
                       {skip_stats_update_on_db_open, boolean()} |
                       {wal_recovery_mode, wal_recovery_mode()} |
                       {allow_concurrent_memtable_write, boolean()} |
                       {enable_write_thread_adaptive_yield, boolean()}].

-type read_options() :: [{verify_checksums, boolean()} |
                         {fill_cache, boolean()} |
                         {iterate_upper_bound, binary()} |
                         {tailing, boolean()} |
                         {total_order_seek, boolean()} |
                         {snapshot, snapshot_handle()}].

-type write_options() :: [{sync, boolean()} |
                          {disable_wal, boolean()} |
                          {timeout_hint_us, non_neg_integer()} |
                          {ignore_missing_column_families, boolean()}].

-type write_actions() :: [{put, Key::binary(), Value::binary()} |
                          {put, ColumnFamilyHandle::cf_handle(), Key::binary(), Value::binary()} |
                          {delete, Key::binary()} |
                          {delete, ColumnFamilyHandle::cf_handle(), Key::binary()} |
                          clear].

-type iterator_action() :: first | last | next | prev | binary().


%% @doc
%% Open RocksDB with the defalut column family
-spec(open(Name, DBOpts, CFOpts) ->
             {ok, db_handle()} | {error, any()} when Name::file:filename_all(),
                                                     DBOpts::db_options(),
                                                     CFOpts::cf_options()).

open(_Name, _DbOpts) ->
    erlang:nif_error({error, not_loaded}).

open(Name, DbOpts, CfDescriptors) ->
    open(Name, DbOpts ++ CfDescriptors).

open_with_cf(_Name, _DbOpts, _CfDescriptors) ->
    erlang:nif_error({error, not_loaded}).



%% @doc
%% Close RocksDB
-spec(close(DBHandle) ->
             ok | {error, any()} when DBHandle::db_handle()).
close(_DBHandle) ->
    erlang:nif_error({error, not_loaded}).

%% @doc List column families
-spec(list_column_families(Name, DBOpts) -> {ok, list(string())} | {error, any()}
        when Name::file:filename_all(),
             DBOpts::db_options()).
list_column_families(_Name, _DbOpts) ->
    erlang:nif_error({error, not_loaded}).


%% @doc
%% Create a new column family
-spec(create_column_family(DBHandle, Name, CFOpts) ->
             {ok, cf_handle()} | {error, any()} when DBHandle::db_handle(),
                                                     Name::string(),
                                                     CFOpts::cf_options()).
create_column_family(_DBHandle, _Name, _CFOpts) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Drop a column family
-spec(drop_column_family(CFHandle) ->
             ok | {error, any()} when  CFHandle::cf_handle()).
drop_column_family(_CFHandle) ->
    erlang:nif_error({error, not_loaded}).



%% @doc take a snapshot of a running RocksDB database in a separate directory
%% http://rocksdb.org/blog/2609/use-checkpoints-for-efficient-snapshots/
-spec checkpoint(DbHandle::db_handle(), Path::file:filename_all()) ->
    ok
    | {error, any()}.
checkpoint(_DbHandle, _Path) ->
    erlang:nif_error({error, not_loaded}).

%% @doc force memtable in memory to be stored on disk.
-spec flush(DbHandle::db_handle()) -> ok.
flush(_DbHandle) ->
  erlang:nif_error({error, not_loaded}).

%% @sdoc return a database snapshot
%% Snapshots provide consistent read-only views over the entire state of the key-value store
-spec(snapshot(DbHandle::db_handle()) -> {ok, snapshot_handle()} | {error, any()}).
snapshot(_DbHandle) ->
    erlang:nif_error({error, not_loaded}).


%% @doc release a snapshot
-spec(release_snapshot(SnapshotHandle::snapshot_handle()) -> ok | {error, any()}).
release_snapshot(_SnapshotHandle) ->
    erlang:nif_error({error, not_loaded}).



%% @doc
%% Put a key/value pair into the default column family
-spec(put(DBHandle, Key, Value, WriteOpts) ->
             ok | {error, any()} when DBHandle::db_handle(),
                                      Key::binary(),
                                      Value::binary(),
                                      WriteOpts::write_options()).
put(_DBHandle, _Key, _Value, _WriteOpts) ->
  erlang:nif_error({error, not_loaded}).

%% @doc
%% Put a key/value pair into the specified column family
-spec(put(DBHandle, CFHandle, Key, Value, WriteOpts) ->
             ok | {error, any()} when DBHandle::db_handle(),
                                      CFHandle::cf_handle(),
                                      Key::binary(),
                                      Value::binary(),
                                      WriteOpts::write_options()).
put(_DBHandle, _CFHandle, _Key, _Value, _WriteOpts) ->
  erlang:nif_error({error, not_loaded}).


%% @doc
%% Delete a key/value pair in the default column family
-spec(delete(DBHandle, Key, WriteOpts) ->
             ok | {error, any()} when DBHandle::db_handle(),
                                      Key::binary(),
                                      WriteOpts::write_options()).
delete(_DBHandle, _Key, _WriteOpts) ->
  erlang:nif_error({error, not_loaded}).

%% @doc
%% Delete a key/value pair in the specified column family
-spec(delete(DBHandle, CFHandle, Key, WriteOpts) ->
             ok | {error, any()} when DBHandle::db_handle(),
                                      CFHandle::cf_handle(),
                                      Key::binary(),
                                      WriteOpts::write_options()).
delete(_DBHandle, _CFHandle, _Key, _WriteOpts) ->
  erlang:nif_error({error, not_loaded}).

%% @doc
%% Apply the specified updates to the database.
-spec(write(DBHandle, WriteActions, WriteOpts) ->
             ok | {error, any()} when DBHandle::db_handle(),
                                      WriteActions::write_actions(),
                                      WriteOpts::write_options()).
write(_DBHandle, _WriteActions, _WriteOpts) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Retrieve a key/value pair in the default column family
-spec get(DBHandle, Key, ReadOpts) ->
    {ok, binary()} | not_found | {error, any()}
      when
      DBHandle::db_handle(),
      Key::binary(),
      ReadOpts::read_options().
get(_DBHandle, _Key, _ReadOpts) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Retrieve a key/value pair in the specified column family
-spec(get(DBHandle, CFHandle, Key, ReadOpts) ->
             {ok, binary()} | not_found | {error, any()} when DBHandle::db_handle(),
                                                              CFHandle::cf_handle(),
                                                              Key::binary(),
                                                              ReadOpts::read_options()).
get(_DBHandle, _CFHandle, _Key, _ReadOpts) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Return a iterator over the contents of the database.
%% The result of iterator() is initially invalid (caller must
%% call iterator_move function on the iterator before using it).
-spec(iterator(DBHandle, ReadOpts) ->
             {ok, itr_handle()} | {error, any()} when DBHandle::db_handle(),
                                                      ReadOpts::read_options()).
iterator(_DBHandle, _ReadOpts) ->
    erlang:nif_error({error, not_loaded}).

iterator(_DBHandle, _ReadOpts, keys_only) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Return a iterator over the contents of the specified column family.
-spec(iterators(DBHandle, CFHandle, ReadOpts) ->
             {ok, itr_handle()} | {error, any()} when DBHandle::db_handle(),
                                                      CFHandle::cf_handle(),
                                                      ReadOpts::read_options()).
iterators(_DBHandle, _CFHandle, _ReadOpts) ->
    erlang:nif_error({error, not_loaded}).

iterators(_DBHandle, _CFHandle, _ReadOpts, keys_only) ->
    erlang:nif_error({error, not_loaded}).



%% @doc
%% Move to the specified place
-spec(iterator_move(ITRHandle, ITRAction) ->
             {ok, Key::binary(), Value::binary()} |
             {ok, Key::binary()} |
             {error, invalid_iterator} |
             {error, iterator_closed} when ITRHandle::itr_handle(),
                                           ITRAction::iterator_action()).
iterator_move(_ITRHandle, _ITRAction) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Close a iterator
-spec(iterator_close(ITRHandle) -> ok when ITRHandle::itr_handle()).
iterator_close(_ITRHandle) ->
    erlang:nif_error({error, not_loaded}).

-type fold_fun() :: fun(({Key::binary(), Value::binary()}, any()) -> any()).

%% @doc
%% Calls Fun(Elem, AccIn) on successive elements in the default column family
%% starting with AccIn == Acc0.
%% Fun/2 must return a new accumulator which is passed to the next call.
%% The function returns the final value of the accumulator.
%% Acc0 is returned if the default column family is empty.
-spec(fold(DBHandle, Fun, Acc0, ReadOpts) ->
             any() when DBHandle::db_handle(),
                        Fun::fold_fun(),
                        Acc0::any(),
                        ReadOpts::read_options()).
fold(DBHandle, Fun, Acc0, ReadOpts) ->
    {ok, Itr} = iterator(DBHandle, ReadOpts),
    do_fold(Itr, Fun, Acc0).

%% @doc
%% Calls Fun(Elem, AccIn) on successive elements in the specified column family
%% Other specs are same with fold/4
-spec(fold(DBHandle, CFHandle, Fun, Acc0, ReadOpts) ->
             any() when DBHandle::db_handle(),
                        CFHandle::cf_handle(),
                        Fun::fold_fun(),
                        Acc0::any(),
                        ReadOpts::read_options()).
fold(_DBHandle, _CFHandle, _Fun, _Acc0, _ReadOpts) ->
    _Acc0.

-type fold_keys_fun() :: fun((Key::binary(), any()) -> any()).

%% @doc
%% Calls Fun(Elem, AccIn) on successive elements in the default column family
%% starting with AccIn == Acc0.
%% Fun/2 must return a new accumulator which is passed to the next call.
%% The function returns the final value of the accumulator.
%% Acc0 is returned if the default column family is empty.
-spec(fold_keys(DBHandle, Fun, Acc0, ReadOpts) ->
             any() when DBHandle::db_handle(),
                        Fun::fold_keys_fun(),
                        Acc0::any(),
                        ReadOpts::read_options()).
fold_keys(DBHandle, Fun, Acc0, ReadOpts) ->
    {ok, Itr} = iterator(DBHandle, ReadOpts, keys_only),
    do_fold(Itr, Fun, Acc0).

%% @doc
%% Calls Fun(Elem, AccIn) on successive elements in the specified column family
%% Other specs are same with fold_keys/4
-spec(fold_keys(DBHandle, CFHandle, Fun, Acc0, ReadOpts) ->
             any() when DBHandle::db_handle(),
                        CFHandle::cf_handle(),
                        Fun::fold_keys_fun(),
                        Acc0::any(),
                        ReadOpts::read_options()).
fold_keys(_DBHandle, _CFHandle, _Fun, _Acc0, _ReadOpts) ->
    _Acc0.

is_empty(_DBHandle) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Destroy the contents of the specified database.
%% Be very careful using this method.
-spec(destroy(Name, DBOpts) ->
             ok | {error, any()} when Name::file:filename_all(),
                                      DBOpts::db_options()).
destroy(_Name, _DBOpts) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Try to repair as much of the contents of the database as possible.
%% Some data may be lost, so be careful when calling this function
-spec(repair(Name, DBOpts) ->
             ok | {error, any()} when Name::file:filename_all(),
                                      DBOpts::db_options()).
repair(_Name, _DBOpts) ->
    erlang:nif_error({error, not_loaded}).


%% @doc for each stores retun the approximate size in a range
-spec get_approximate_size(db_handle(), binary(), binary(), boolean()) -> integer().
get_approximate_size(_DbHandle, _SKey, _EKey, _IncludeMemtable) ->
  erlang:nif_error({error, not_loaded}).

get_latest_sequence_number(_DbHandle) ->
  erlang:nif_error({error, not_loaded}).


get_updates_since(_DbHandle, _Since) ->
  erlang:nif_error({error, not_loaded}).

next_update(_Iterator) ->
  erlang:nif_error({error, not_loaded}).

close_updates_iterator(_Iterator) ->
  erlang:nif_error({error, not_loaded}).

write_update(_Iterator, _Update, _WriteOptions) ->
  erlang:nif_error({error, not_loaded}).


%% @doc
%% Return the approximate number of keys in the default column family.
%% Implemented by calling GetIntProperty with "rocksdb.estimate-num-keys"
%%
-spec(count(DBHandle) ->
             non_neg_integer() | {error, any()} when DBHandle::db_handle()).
count(DBHandle) ->
    case status(DBHandle, <<"rocksdb.estimate-num-keys">>) of
        {ok, BinCount} ->
            erlang:binary_to_integer(BinCount);
        Error ->
            Error
    end.

%% @doc
%% Return the approximate number of keys in the specified column family.
%%
-spec(count(DBHandle, CFHandle) ->
             non_neg_integer() | {error, any()} when DBHandle::db_handle(),
                                                     CFHandle::cf_handle()).
count(_DBHandle, _CFHandle) ->
    {error, not_implemeted}.

%% @doc
%% Return the current status of the default column family
%% Implemented by calling GetProperty with "rocksdb.stats"
%%
-spec(status(DBHandle) ->
             {ok, any()} | {error, any()} when DBHandle::db_handle()).
status(DBHandle) ->
    status(DBHandle, <<"rocksdb.stats">>).

%% @doc
%% Return the RocksDB internal status of the default column family specified at Property
%%
-spec(status(DBHandle, Property) ->
             {ok, any()} | {error, any()} when DBHandle::db_handle(),
                                               Property::binary()).
status(_DBHandle, _Property) ->
    erlang:nif_error({error, not_loaded}).

%% @doc
%% Return the RocksDB internal status of the specified column family specified at Property
%%
-spec(status(DBHandle, CFHandle, Property) ->
             string() | {error, any()} when DBHandle::db_handle(),
                                            CFHandle::cf_handle(),
                                            Property::binary()).
status(_DBHandle, _CFHandle, _Property) ->
    {error, not_implemeted}.

%% ===================================================================
%% Internal functions
%% ===================================================================
do_fold(Itr, Fun, Acc0) ->
    try
        fold_loop(iterator_move(Itr, first), Itr, Fun, Acc0)
    after
        iterator_close(Itr)
    end.

fold_loop({error, iterator_closed}, _Itr, _Fun, Acc0) ->
    throw({iterator_closed, Acc0});
fold_loop({error, invalid_iterator}, _Itr, _Fun, Acc0) ->
    Acc0;
fold_loop({ok, K}, Itr, Fun, Acc0) ->
    Acc = Fun(K, Acc0),
    fold_loop(iterator_move(Itr, next), Itr, Fun, Acc);
fold_loop({ok, K, V}, Itr, Fun, Acc0) ->
    Acc = Fun({K, V}, Acc0),
    fold_loop(iterator_move(Itr, next), Itr, Fun, Acc).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).
open_test() -> [{open_test_Z(), l} || l <- lists:seq(1, 20)].
open_test_Z() ->
    os:cmd("rm -rf /tmp/erocksdb.open.test"),
    {ok, Ref} = open("/tmp/erocksdb.open.test", [{create_if_missing, true}], []),
    true = ?MODULE:is_empty(Ref),
    ok = ?MODULE:put(Ref, <<"abc">>, <<"123">>, []),
    false = ?MODULE:is_empty(Ref),
    {ok, <<"123">>} = ?MODULE:get(Ref, <<"abc">>, []),
    {ok, 1} = ?MODULE:count(Ref),
    not_found = ?MODULE:get(Ref, <<"def">>, []),
    ok = ?MODULE:delete(Ref, <<"abc">>, []),
    not_found = ?MODULE:get(Ref, <<"abc">>, []),
    true = ?MODULE:is_empty(Ref).

fold_test() -> [{fold_test_Z(), l} || l <- lists:seq(1, 20)].
fold_test_Z() ->
    os:cmd("rm -rf /tmp/erocksdb.fold.test"),
    {ok, Ref} = open("/tmp/erocksdb.fold.test", [{create_if_missing, true}], []),
    ok = ?MODULE:put(Ref, <<"def">>, <<"456">>, []),
    ok = ?MODULE:put(Ref, <<"abc">>, <<"123">>, []),
    ok = ?MODULE:put(Ref, <<"hij">>, <<"789">>, []),
    [{<<"abc">>, <<"123">>},
     {<<"def">>, <<"456">>},
     {<<"hij">>, <<"789">>}] = lists:reverse(fold(Ref, fun({K, V}, Acc) -> [{K, V} | Acc] end,
                                                  [], [])).

fold_keys_test() -> [{fold_keys_test_Z(), l} || l <- lists:seq(1, 20)].
fold_keys_test_Z() ->
    os:cmd("rm -rf /tmp/erocksdb.fold.keys.test"),
    {ok, Ref} = open("/tmp/erocksdb.fold.keys.test", [{create_if_missing, true}], []),
    ok = ?MODULE:put(Ref, <<"def">>, <<"456">>, []),
    ok = ?MODULE:put(Ref, <<"abc">>, <<"123">>, []),
    ok = ?MODULE:put(Ref, <<"hij">>, <<"789">>, []),
    [<<"abc">>, <<"def">>, <<"hij">>] = lists:reverse(fold_keys(Ref,
                                                                fun(K, Acc) -> [K | Acc] end,
                                                                [], [])).

destroy_test() -> [{destroy_test_Z(), l} || l <- lists:seq(1, 20)].
destroy_test_Z() ->
    os:cmd("rm -rf /tmp/erocksdb.destroy.test"),
    {ok, Ref} = open("/tmp/erocksdb.destroy.test", [{create_if_missing, true}], []),
    ok = ?MODULE:put(Ref, <<"def">>, <<"456">>, []),
    {ok, <<"456">>} = ?MODULE:get(Ref, <<"def">>, []),
    close(Ref),
    ok = ?MODULE:destroy("/tmp/erocksdb.destroy.test", []),
    {error, {db_open, _}} = open("/tmp/erocksdb.destroy.test", [{error_if_exists, true}], []).

compression_test() -> [{compression_test_Z(), l} || l <- lists:seq(1, 20)].
compression_test_Z() ->
    CompressibleData = list_to_binary([0 || _X <- lists:seq(1,20)]),
    os:cmd("rm -rf /tmp/erocksdb.compress.0 /tmp/erocksdb.compress.1"),
    {ok, Ref0} = open("/tmp/erocksdb.compress.0", [{create_if_missing, true}],
                      [{compression, none}]),
    [ok = ?MODULE:put(Ref0, <<I:64/unsigned>>, CompressibleData, [{sync, true}]) ||
        I <- lists:seq(1,10)],
    {ok, Ref1} = open("/tmp/erocksdb.compress.1", [{create_if_missing, true}],
                      [{compression, snappy}]),
    [ok = ?MODULE:put(Ref1, <<I:64/unsigned>>, CompressibleData, [{sync, true}]) ||
        I <- lists:seq(1,10)],
    %% Check both of the LOG files created to see if the compression option was correctly
    %% passed down
    MatchCompressOption =
        fun(File, Expected) ->
                {ok, Contents} = file:read_file(File),
                case re:run(Contents, "Options.compression: " ++ Expected) of
                    {match, _} -> match;
                    nomatch -> nomatch
                end
        end,
    Log0Option = MatchCompressOption("/tmp/erocksdb.compress.0/LOG", "0"),
    Log1Option = MatchCompressOption("/tmp/erocksdb.compress.1/LOG", "1"),
    ?assert(Log0Option =:= match andalso Log1Option =:= match).

close_test() -> [{close_test_Z(), l} || l <- lists:seq(1, 20)].
close_test_Z() ->
    os:cmd("rm -rf /tmp/erocksdb.close.test"),
    {ok, Ref} = open("/tmp/erocksdb.close.test", [{create_if_missing, true}], []),
    ?assertEqual(ok, close(Ref)),
    ?assertEqual({error, einval}, close(Ref)).

close_fold_test() -> [{close_fold_test_Z(), l} || l <- lists:seq(1, 20)].
close_fold_test_Z() ->
    os:cmd("rm -rf /tmp/erocksdb.close_fold.test"),
    {ok, Ref} = open("/tmp/erocksdb.close_fold.test", [{create_if_missing, true}], []),
    ok = erocksdb:put(Ref, <<"k">>,<<"v">>,[]),
    ?assertException(throw, {iterator_closed, ok}, % ok is returned by close as the acc
                     erocksdb:fold(Ref, fun(_,_A) -> erocksdb:close(Ref) end, undefined, [])).

-ifdef(EQC).
qc(P) ->
    ?assert(eqc:quickcheck(?QC_OUT(P))).

keys() ->
    eqc_gen:non_empty(list(eqc_gen:non_empty(binary()))).

values() ->
    eqc_gen:non_empty(list(binary())).

ops(Keys, Values) ->
    {oneof([put, delete]), oneof(Keys), oneof(Values)}.

apply_kv_ops([], _Ref, Acc0) ->
    Acc0;
apply_kv_ops([{put, K, V} | Rest], Ref, Acc0) ->
    ok = erocksdb:put(Ref, K, V, []),
    apply_kv_ops(Rest, Ref, orddict:store(K, V, Acc0));
apply_kv_ops([{delete, K, _} | Rest], Ref, Acc0) ->
    ok = erocksdb:delete(Ref, K, []),
    apply_kv_ops(Rest, Ref, orddict:store(K, deleted, Acc0)).

prop_put_delete() ->
    ?LET({Keys, Values}, {keys(), values()},
         ?FORALL(Ops, eqc_gen:non_empty(list(ops(Keys, Values))),
                 begin
                     ?cmd("rm -rf /tmp/erocksdb.putdelete.qc"),
                     {ok, Ref} = erocksdb:open("/tmp/erocksdb.putdelete.qc",
                                               [{create_if_missing, true}], []),
                     Model = apply_kv_ops(Ops, Ref, []),

                     %% Valdiate that all deleted values return not_found
                     F = fun({K, deleted}) ->
                                 ?assertEqual(not_found, erocksdb:get(Ref, K, []));
                            ({K, V}) ->
                                 ?assertEqual({ok, V}, erocksdb:get(Ref, K, []))
                         end,
                     lists:map(F, Model),

                     %% Validate that a fold returns sorted values
                     Actual = lists:reverse(fold(Ref, fun({K, V}, Acc) -> [{K, V} | Acc] end,
                                                 [], [])),
                     ?assertEqual([{K, V} || {K, V} <- Model, V /= deleted],
                                  Actual),
                     ok = erocksdb:close(Ref),
                     true
                 end)).

prop_put_delete_test_() ->
    Timeout1 = 10,
    Timeout2 = 15,
    %% We use the ?ALWAYS(300, ...) wrapper around the second test as a
    %% regression test.
    [{timeout,  3 * Timeout1,
      {"No ?ALWAYS()", fun() -> qc(eqc:testing_time(Timeout1,prop_put_delete())) end}},
     {timeout, 10 * Timeout2,
      {"With ?ALWAYS()", fun() -> qc(eqc:testing_time(Timeout2,?ALWAYS(150,prop_put_delete()))) end}}].
-endif.
-endif.
