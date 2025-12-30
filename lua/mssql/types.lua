---@meta

---@alias ScriptStrategy "ScriptCreate" | "ScriptSelect" | "ScriptDrop" | "ScriptCreateDrop"
---@alias ConnectionKey string
---@alias MssqlQueryManagerState
---| "disconnected"
---| "connecting"
---| "connected"
---| "executing"
---| "cancelling"
---@alias StateTransitionTable table<MssqlQueryManagerState, MssqlQueryManagerState[]>


---@class NodeTypeDef
---@field scriptCreateDrop string "ScriptCreate" | "ScriptSelect"
---@field operation integer

---@class NodeTypeAction
---@field id string Action ID (e.g. "create", "drop") used for the keymap lookup
---@field label string Display label for the picker
---@field scriptCreateDrop ScriptStrategy The scripting strategy
---@field operation integer The operation code (e.g. 0=Select, 1=Create)

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
---@field cancellation_token? { cancel: boolean }
---@field refresh_coroutine? thread

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
---@field auto_connect_on_rename boolean? Automatically re-establish the connection when a buffer is renamed (default true).
---@field execute_generated_select_statements boolean? Auto-execute SELECTs from finder.
---@field lsp_settings table? Settings passed to mssql language server.
---@field sql_buffer_options table<string, any>? Vim options for SQL buffers.
---@field results_buffer_extension string? File extension for results (default "md").
---@field results_buffer_filetype string? Filetype for results (default "markdown").
---@field results_keymaps MssqlResultsKeymaps|boolean? Keymaps for results buffer (false to disable).
---@field find_object_keymaps table<string, string>? Keymaps for find_object picker (Key -> Action ID).
---@field connections_file string? Path to connections.json.
---@field tools_file string? Path to existing SQL tools binary.
---@field data_dir string? Directory for tools and config.
---@field icons MssqlIcons? Icon configuration.

---@class MssqlOptions : MssqlConfig
---@field open_results_in ("split"|"vsplit"|"current_window"|fun(bufnr: integer))
---@field view_messages_in ("notification"|"buffer"|fun(msg: string, is_error: boolean))
---@field max_rows integer
---@field max_column_width integer
---@field auto_connect_on_rename boolean
---@field execute_generated_select_statements boolean
---@field lsp_settings table
---@field sql_buffer_options table<string, any>
---@field results_buffer_extension string
---@field results_buffer_filetype string
---@field results_keymaps MssqlResultsKeymaps|boolean
---@field find_object_keymaps table<string, string>
---@field connections_file string
---@field tools_file string
---@field data_dir string
---@field icons MssqlIcons

---@class MssqlTimer
---@field handle uv_timer_t? The internal libuv handle
---@field start fun(self: MssqlTimer, interval_ms: integer, callback: function)
---@field stop fun(self: MssqlTimer)
---@field close fun(self: MssqlTimer)

---@class MssqlExecutionInfo
---@field rows_affected? number
---@field elapsed_time? number

---@class MssqlConnectionOptions
---@field server? string
---@field database? string
---@field databaseAllowList? string[]
---@field databaseDenyList? string[]
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
---@field keymaps table<string, string> Key chords mapped to Intent IDs (e.g. { ["<M-c>"] = "create" })

return {}
