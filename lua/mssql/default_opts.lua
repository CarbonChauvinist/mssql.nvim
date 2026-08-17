---@type MssqlConfig
local M = {
	-- Set up keymaps with this prefix. If which-key is found, this will be a which-key group.
	keymap_prefix = nil,

	--[[ How to open a buffer containing sql results.
  Valid options are:
  "split"                   - Open results in a horizontal split
  "vsplit"                  - Open results in a vertical split
  "current_window"          - Open results in the current window
  function (bufnr) ... end  - Function which takes the buffer number of the results buffer to open
                              (called for each results buffer if there are multiple). Use this
                              to open the buffer in a custom way
  --]]
	open_results_in = "split",

	--[[ How query outputs will be displayed.
  Valid options are:
  "markdown" - Results displayed as a formatted Markdown table
  "json"     - Results displayed as structured JSON (requires 'jq' for formatting)
  "csv"      - Results displayed as csv
  "text"     - Results displayed as unformatted plain text
	--]]
    results_output_format = "markdown",

	-- Automatically display single scalar results (1 row x 1 col) as inline virtual text (default false)
	display_scalar_as_virtual_text = false,

	--[[ Where to view messages sent from sql server (eg when executing queries)
  Valid options are:
  "notification"                        - View as a vim notification
  "buffer"                              - View in a messages buffer
  function(message, is_error) ...       - Function which takes the message string and is_error boolean
                                          (called for each message). Use this to view messages in a custom way
  --]]
	view_messages_in = "notification",

	-- Max rows to return for queries. Needed so that large results don't crash neovim.
	max_rows = 100,

	-- If a result row has a field text length larger than this it will be truncated when displayed
	max_column_width = 100,

	-- Timeout for query execution in seconds, use less than 0 or nil for no timeout
	query_timeout = nil,

	-- Timeouts for object explorer expansion in seconds (i.e. finder)
	-- server: Timeout for connecting to server/listing databases
	-- database: Timeout for expanding database tables/views/etc
	object_explorer_timeouts = {
		server = 180,
		database = 90
	},

	--[[ List of database object categories to scan in explorer.
  Valid options are:
  "stored_procedures"
  "tables"
  "views"
  "functions"
	--]]
	explorer_categories = { "stored_procedures" },

	-- Automatically initialize the Object Explorer cache on connection setup
	auto_init_explorer = false,

	-- When choosing a table/view in the finder, immediately execute the generated SELECT statement
	execute_generated_select_statements = true,

	-- Settings passed to the mssql language server. See https://github.com/Kurren123/mssql.nvim/blob/main/docs/Lsp-Settings.md
	lsp_settings = {
		format = {
			placeSelectStatementReferencesOnNewLine = true,
			keywordCasing = "Uppercase",
			datatypeCasing = "Uppercase",
			alignColumnDefinitionsInColumns = true,
		},
	},

	-- Options that will be set on buffers of sql file type (see https://neovim.io/doc/user/options.html)
	sql_buffer_options = {
		expandtab = true,
		tabstop = 4,
		shiftwidth = 4,
		softtabstop = 4,
	},

	-- Keymaps for the results buffer (set to false to disable)
	---@type MssqlResultsKeymaps
	results_keymaps = {
		prev_page = "<C-p>",
		first_page = "<C-M-p>",
		next_page = "<C-n>",
		last_page = "<C-M-n>",
		toggle_format = "gf",
	},

	-- keymaps for find_objects actions
	find_object_keymaps = {
		["<M-c>"] = "create",
		["<M-s>"] = "select",
		["<M-d>"] = "drop",
		["<M-a>"] = "alter",
		["<M-m>"] = "menu",
	},

	-- Path to a json connections file (see https://github.com/Kurren123/mssql.nvim?tab=readme-ov-file#connections-json-file)
	-- If nil, it's stored in the data_dir
	connections_file = nil,

	-- Enable/disable SQL connection pooling in the STS layer (e.g. disable for testing harness)
	enable_connection_pooling = true,

	-- Path to an existing SQL tools service binary (see https://github.com/microsoft/sqltoolsservice/releases).
	-- If nil, then the binary is auto downloaded to data_dir
	tools_file = nil,

	-- Directory to store download tools and internal config options
	data_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "/mssql.nvim"):gsub("[/\\]+$", ""),

	-- Configuration for icons
	---@type MssqlIcons
	icons = {
		status_line = {
			enabled = true,
			disconnected = "",
			server = "",
			database = "",
		},
		find_object = {
			enabled = true,
			AggregateFunctionPartitionFunction = "󰡱",
			ScalarValuedFunction = "󰡱",
			StoredProcedure = "󰯁",
			TableValuedFunction = "󰡱",
			Table = "",
			View = "󱂬",
		},
	},


	---@type table<string, NodeActionConfig[]>
	find_object_actions = {
		p = {
			default = "alter",
			actions = {
				{ action = "create", label = "Create Sproc" },
				{ action = "execute", label = "Execute Sproc" },
				{ action = "alter", label = "Alter Sproc "}
			}
		},
		t = {
			default = "select",
			actions = {
				{ action = "drop", label = "Drop Table" },
				{ action = "create", label = "Create Table" },
				{ action = "select", label = "Select Table (TOP 1000)" }
			}
		},
		v = {
			default = "select",
			actions = {
				{ action = "create", label = "Create View" },
				{ action = "alter", label = "Alter View" }
			}
		},
		f = {
			default = "execute",
			actions = {
				{ action = "create", label = "Create Function" },
				{ action = "alter", label = "Alter Function" },
				{ action = "drop", label = "Drop Function" }
			}
		},
	},

	---@type string? Custom SQL Tools Service version to download (default: "6.0.20260709.1")
	sts_version = nil,

	---@type string? Custom SQL Tools Service version SHA256 checksum to validate against
	sts_version_sha256 = nil,
}

return M
