---@class MssqlIcons
---@field enabled boolean
---@field disconnected string?
---@field server string?
---@field database string?

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
---@field connections_file string? Path to connections.json.
---@field tools_file string? Path to existing SQL tools binary.
---@field data_dir string? Directory for tools and config.
---@field icons MssqlIcons? Icon configuration.

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

	-- Automatically re-establish the connection when a buffer is renamed (e.g. :saveas)
	auto_connect_on_rename = true,

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

	-- The file extension of buffers that show query results
	results_buffer_extension = "md",

	-- The filetype (used in neovim to determine the language) of buffers that show query results. Set this to "" to disable markdown rendering.
	results_buffer_filetype = "markdown",

	-- Keymaps for the results buffer (set to false to disable)
	---@type MssqlResultsKeymaps
	results_keymaps = {
		prev_page = "<C-p>",
		first_page = "<C-M-p>",
		next_page = "<C-n>",
		last_page = "<C-M-n>",
	},

	-- Path to a json connections file (see https://github.com/Kurren123/mssql.nvim?tab=readme-ov-file#connections-json-file)
	-- If nil, it's stored in the data_dir
	connections_file = nil,

	-- Path to an existing SQL tools service binary (see https://github.com/microsoft/sqltoolsservice/releases).
	-- If nil, then the binary is auto downloaded to data_dir
	tools_file = nil,

	-- Directory to store download tools and internal config options
	data_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "/mssql.nvim"):gsub("[/\\]+$", ""),

	-- Configuration for icons in default lualine component
	---@type MssqlIcons
	icons = {
		enabled = false,
		disconnected = "",
		server = "",
		database = "",
	}
}

return M
