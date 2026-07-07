---@meta

---@alias MssqlActionId "create" | "alter" | "drop" | "select" | "execute"
---@alias MssqlScriptStrategy "ScriptSelect" | "ScriptCreate" | "ScriptDrop"
---@alias MssqlOpCodeInteger 0 | 1 | 2 | 3 | 4 | 5 | 6

---@alias ConnectionKey string
---@alias MssqlQueryManagerState "disconnected" | "connecting" | "connected" | "executing" | "cancelling"
---@alias StateTransitionTable table<MssqlQueryManagerState, MssqlQueryManagerState[]>
---@alias FindObjectScope "server" | "database"

---@class NodeActionConfig
---@field default MssqlActionId The default action ID (e.g. "create")
---@field actions MssqlActionEntry[]? List of available actions

---@class MssqlActionEntry
---@field action MssqlActionId The ID of the action to perform
---@field label string? Optional override for the picker label

---@class MssqlResolvedAction
---@field id MssqlActionId Action ID (e.g. "create", "drop") used for the keymap lookup
---@field label string Display label for the picker
---@field script_type MssqlScriptStrategy Strict script strategy
---@field op MssqlOpCodeInteger Strict operation code

---@class MssqlNode
---@field nodePath string
---@field label string
---@field nodeType string
---@field objectType string
---@field parentNodePath string
---@field isLeaf boolean
---@field metadata? table
---@field picker_path? string
---@field text? string

---@class MssqlSession
---@field sessionId string
---@field success boolean
---@field errorMessage? string
---@field rootNode MssqlNode
---@field target_path? string

---@class GlobalCacheEntry
---@field cache? MssqlNode[]
---@field is_initializing? boolean
---@field cancellation_token? { cancel: boolean, cleanup_callback: function }
---@field connection_options? MssqlConnectionOptions
---@field refresh_coroutine? thread
---@field scope? string

---@class MssqlIconsStatusLine
---@field enabled boolean?
---@field disconnected string?
---@field server string?
---@field database string?

---@class MssqlIconsFindObject
---@field enabled boolean?
---@field AggregateFunctionPartitionFunction string?
---@field ScalarValuedFunction string?
---@field StoredProcedure string?
---@field TableValuedFunction string?
---@field Table string?
---@field View string?

---@class MssqlIcons
---@field status_line MssqlIconsStatusLine?
---@field find_object MssqlIconsFindObject?

---@class MssqlResultsKeymaps
---@field prev_page string?
---@field first_page string?
---@field next_page string?
---@field last_page string?

---@class MssqlConfig
---@field keymap_prefix string? Set up keymaps with this prefix.
---@field open_results_in ("split"|"vsplit"|"current_window"|fun(bufnr: integer))? How to open the results buffer.
---@field view_messages_in ("notification"|"buffer"|fun(msg: string, is_error: boolean))? Where to view SQL server messages.
---@field max_rows integer? Max rows to return (default 100).
---@field max_column_width integer? Max text length before truncation.
---@field query_timeout integer? Timeout in seconds (nil or < 0 for no timeout).
---@field object_explorer_timeouts { server: integer, database: integer }?
---@field auto_connect_on_rename boolean? Automatically re-establish the connection when a buffer is renamed (default true).
---@field execute_generated_select_statements boolean? Auto-execute SELECTs from finder.
---@field lsp_settings table? Settings passed to mssql language server.
---@field sql_buffer_options table<string, any>? Vim options for SQL buffers.
---@field results_buffer_extension string? File extension for results (default "md").
---@field results_buffer_filetype string? Filetype for results (default "markdown").
---@field results_keymaps MssqlResultsKeymaps|boolean? Keymaps for results buffer (false to disable).
---@field find_object_keymaps table<string, string>? Keymaps for find_object picker (Key -> Action ID).
---@field connections_file string? Path to connections.json.
---@field enable_connection_pooling boolean? Enable connection pooling in the STS layer
---@field tools_file string? Path to existing SQL tools binary.
---@field data_dir string? Directory for tools and config.
---@field icons MssqlIcons? Icon configuration.
---@field find_object_actions table<string, NodeActionConfig>? Configuration for object actions (Table, View, etc)

---@class MssqlOptions : MssqlConfig
---@field keymap_prefix string
---@field open_results_in ("split"|"vsplit"|"current_window"|fun(bufnr: integer))
---@field view_messages_in ("notification"|"buffer"|fun(msg: string, is_error: boolean))
---@field max_rows integer
---@field max_column_width integer
---@field query_timeout integer?
---@field object_explorer_timeouts { server: integer, database: integer }
---@field auto_connect_on_rename boolean
---@field execute_generated_select_statements boolean
---@field lsp_settings table
---@field sql_buffer_options table<string, any>
---@field results_buffer_extension string
---@field results_buffer_filetype string
---@field results_keymaps MssqlResultsKeymaps|boolean
---@field find_object_keymaps table<string, string>
---@field connections_file string
---@field enable_connection_pooling boolean
---@field tools_file string
---@field data_dir string
---@field icons MssqlIcons
---@field find_object_actions table<string, NodeActionConfig>

---@class MssqlTimer
---@field handle uv_timer_t? The internal libuv handle
---@field start fun(self: MssqlTimer, interval_ms: integer, callback: function)
---@field stop fun(self: MssqlTimer)
---@field close fun(self: MssqlTimer)

---@class MssqlExecutionInfo
---@field rows_affected? number
---@field elapsed_time? number

---@class MssqlObjectFilter
---@field allow string[]? List of patterns or strings (e.g. "dbo.*", "sales.User*", "special_schema.single_table") to allow
---@field deny string[]? List of patterns to deny. Deny takes precendence.

---@class MssqlConnectionOptions
---@field server? string
---@field database? string
---@field databaseAllowList? string[]
---@field databaseDenyList? string[]
---@field object_filters table<string, MssqlObjectFilter>? Keys are 't', 'v', 'sp', 'f'
---@field user? string
---@field password? string
---@field authentication? string
---@field trustServerCertificate? boolean
---@field [string] any Allow extra fields passed by config

---@class MssqlConnectionSummary
---@field databaseName string
---@field serverName? string
---@field userName? string
---@field connectionId? string

---@class MssqlConnectionWrapper
---@field options MssqlConnectionOptions
---@field summary? MssqlConnectionSummary

---@class MssqlConnectParams
---@field ownerUri? string The URI of the buffer owning this connection.
---@field connection MssqlConnectionWrapper

---@class MssqlQueryExecuteSubsetResult
---@field ownerUri string The URI of the file that owns this query result
---@field batchSummaries MssqlBatchSummary[] A list of summaries for each batch in the script

---@class MssqlBatchSummary
---@field hasError boolean True if the batch failed
---@field id integer
---@field executionElapsed string? Time taken (e.g., "00:00:00.012")
---@field executionStart string? ISO timestamp
---@field executionEnd string? ISO timestamp
---@field resultSetSummaries MssqlResultSetSummary[]? (Optional) Summaries of result sets generated by this batch

---@class MssqlResultSetSummary
---@field id integer
---@field rowCount integer The total number of rows available in this result set
---@field columnInfo ColumnInfo[] Metadata about the columns
---@field complete boolean True if all rows have been fetched

---@class MssqlQueryMessageResult
---@field ownerUri string
---@field message MssqlQueryMessage

---@class MssqlQueryMessage
---@field message string
---@field isError? boolean
---@field batchId? integer

---@class MssqlConnectionChangedResult
---@field ownerUri string
---@field connection MssqlConnectionSummary

---@class MssqlQueryManager
---@field bufnr integer
---@field client vim.lsp.Client
---@field state MssqlQueryManagerState
---@field states MssqlQueryManagerStates
---@field last_connect_params MssqlConnectParams
---@field owner_uri string
---@field execution_timer MssqlTimer
---@field last_execution_info MssqlExecutionInfo
---@field start_time number
---@field query_timeout number?
---@field get_owner_uri fun(self: MssqlQueryManager): string
---@field get_database_name fun(self: MssqlQueryManager): string?
---@field set_state fun(self: MssqlQueryManager, new_state: MssqlQueryManagerState): boolean
---@field get_state fun(self: MssqlQueryManager): MssqlQueryManagerState
---@field cleanup_timer fun(self: MssqlQueryManager)
---@field stop_execution_timer fun(self: MssqlQueryManager)
---@field start_execution_timer fun(self: MssqlQueryManager): boolean
---@field connect_async fun(self: MssqlQueryManager, connect_params: MssqlConnectParams): boolean, string?
---@field disconnect_async fun(self: MssqlQueryManager): boolean
---@field execute_async fun(self: MssqlQueryManager, query: string): MssqlQueryExecuteSubsetResult?, string?
---@field wait_for_query_completion fun(self: MssqlQueryManager): MssqlQueryExecuteSubsetResult?, string?
---@field handle_timeout fun(self: MssqlQueryManager, timeout_ms?: integer): string
---@field cancel_async fun(self: MssqlQueryManager): boolean
---@field parse_rows_affected_message fun(self: MssqlQueryManager, message: string): integer?
---@field set_final_execution_stats fun(self: MssqlQueryManager, final_time?: number, select_row_count?:number)
---@field get_connect_params fun(self: MssqlQueryManager): MssqlConnectParams?
---@field get_connection_options fun(self: MssqlQueryManager): MssqlConnectionOptions?
---@field get_lsp_client fun(self: MssqlQueryManager): vim.lsp.Client
---@field last_execution fun(self: MssqlQueryManager): MssqlExecutionInfo
---@field update_connection_params fun(self: MssqlQueryManager, result: MssqlConnectionChangedResult): boolean
---@field connectionchanged_async fun(self: MssqlQueryManager, result: MssqlConnectionChangedResult)
---@field initialise_cache_async fun(self: MssqlQueryManager, opts?: FindObjectOpts): boolean
---@field find_async fun(self: MssqlQueryManager, scope: string?, object_type: string?): {script: string, select: boolean }?
---@field is_refreshing fun(self: MssqlQueryManager): boolean?
---@field handle_query_complete fun(self: MssqlQueryManager, result: MssqlQueryExecuteSubsetResult)
---@field handle_query_message fun(self: MssqlQueryManager, result: MssqlQueryMessageResult)
---@field cleanup fun(self: MssqlQueryManager)
---@field is_valid fun(self: MssqlQueryManager): boolean

---@class MssqlQueryManagerStates
---@field disconnected MssqlQueryManagerState
---@field connecting MssqlQueryManagerState
---@field connected MssqlQueryManagerState
---@field executing MssqlQueryManagerState
---@field cancelling MssqlQueryManagerState

---@class QueryResultInfo
---@field totalRows integer
---@field currentRowsOffset integer
---@field rowsPerQuery integer
---@field max_column_width integer
---@field ownerUri string
---@field batchIndex integer
---@field resultSetIndex integer
---@field columnInfo ColumnInfo[]

---@class ColumnInfo
---@field columnName string

---@class SubsetParams
---@field ownerUri string
---@field batchIndex integer
---@field resultSetIndex integer
---@field rowsStartIndex integer
---@field rowsCount integer

---@class PickerOptions
---@field title string The title/prompt for the picker
---@field keymaps table<string, MssqlActionId> Key chords mapped to Intent IDs (e.g. { ["<M-c>"] = "create" })

---@class FindObjectOpts
---@field scope? FindObjectScope Scope of search (defaults to "database")
---@field object_type? "t"|"v"|"p"|"f" Filter by type (table, view, proc, func)
---@field bufnr? integer Target buffer (defaults to current)
---@field callback? fun() Function to run after selection
---@field timeout_ms? integer Optional timeout in milliseconds (default: 10000)
---@field owner_uri? string Optional owner URI to execute script request context
---@field force? boolean Optional Get a new cache and overwrite
---@field connect_params? MssqlConnectParams Optional connection parameters

---@class MssqlModule
---@field setup fun(opts?: MssqlConfig) Setup the plugin
---@field connect fun() Connect to a database
---@field disconnect fun() Disconnect the current session
---@field execute_query fun() Execute the query under the cursor or selection
---@field find_object fun(opts?: FindObjectOpts) Find objects (tables, views, etc.)
---@field refresh_cache fun() Refresh the the Intellisense cache
---@field edit_connections fun() Edit the connections.json file
---@field switch_database fun() Switch to a different database
---@field new_query fun() Open a query window
---@field new_default_query fun() Open a new query window using default connection
---@field save_query_results fun() Save the results of the last query
---@field cancel_query fun() Cancel the currently running query
---@field backup_database fun() Script a database backup
---@field restore_database fun() Script a database restore

---@class MssqlExecutionOptions
---@field rerun_last? boolean If true, return the last query selection instead of getting the current selection
---@field highlight? boolean If true, re-highlight the last selection when rerunning
---@field buffer_only? boolean If true, execute entire buffer instead of current selection

---@class GetResultsBufferOpts
---@field all? boolean Return all matching buffers if true.

return {}
