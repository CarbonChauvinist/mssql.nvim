![workflow status badge](https://github.com/Kurren123/mssql.nvim/actions/workflows/test.yml/badge.svg)

# mssql.nvim

<p align="center" >
<img src="./docs/Logo.png" alt="Logo" width="200" />
</p>

<p align="center" >
An SQL Server plugin for neovim. Like it? Give a ⭐️!
</p>

## Features

Completions, including TSQL keywords,

<img src="./docs/screenshots/Tsql_completion.png" alt="Tsql keywords screenshot" width="300"/>

stored procedures

<img src="./docs/screenshots/Stored_procedure_completion.png" alt="stored procedures screenshot" width="300"/>

and cross database queries

<img src="./docs/screenshots/Cross_db_completion.png" alt="Cross db completion" width="300"/>

Execute queries, with results in markdown tables for automatic colouring and
rendering

![results screenshot](./docs/screenshots/Results.png)

User commands and optional which-key integration, showing only the key
maps/commands which are possible (eg don't show `Connect` if we are already
connected)

<img src="./docs/screenshots/Which-key.png" alt="Which key screenshot" width="300"/>

<img src="./docs/screenshots/UserCommands.png" alt="User commands screenshot" width="400"/>

Lualine integration

<img src="./docs/screenshots/Lualine.png" alt="Which key screenshot" width="600"/>

Other cherries on top:

- Backup to/restore from `.bak` files

## Installation

Requires Neovim v0.11.0 or later.

<details>
<summary>lazy.nvim</summary>

```lua
{
  "Kurren123/mssql.nvim",
  opts = {},
  -- optional. You also need to call set_keymaps (see below)
  dependencies = { "folke/which-key.nvim" }
}
```

</details>

<details>
<summary>Packer</summary>

```lua
require("packer").startup(function()
  use({
    "Kurren123/mssql.nvim",
    -- optional. You also need to call set_keymaps (see below)
    requires = { 'folke/which-key.nvim' },
    config = function()
      require("mssql").setup()
    end,
  })
end)
```

</details>

<details>
<summary>Paq</summary>

```lua
require("paq")({
  { "stevearc/conform.nvim" },
  -- optional. You also need to call set_keymaps (see below)
  { "folke/which-key.nvim" }
})
```

</details>

## Setup

```lua
require("mssql").setup()
```

### Keymaps

Choose a prefix, eg `<leader>m`. Then after setup, in your `keymaps` file:

```lua
require("mssql").set_keymaps("<leader>m")
```

**Note:** Make sure your prefix doesn't clash with any existing
keymaps/which-key groups!

All mssql keymaps are set up with the prefix first. In the above example, new
query would be `<leader>mn`. If you have which-key installed, then the prefix
you provide will be a which-key group.

### Status lines

<details>
<summary>Lualine</summary>
Insert `require("mssql").lualine_component` into a lualine section (eg
`lualine_c`).

Eg lazyvim:

```lua
return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "Kurren123/mssql.nvim" },
  opts = function(_, opts)
    table.insert(opts.sections.lualine_c, require("mssql").lualine_component)
    return opts
  end,
}
```

Or Lazy.nvim (without lazyvim):

```lua
return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "Kurren123/mssql.nvim" },
  opts = {
      sections = {
        lualine_c = {
          require('mssql').lualine_component,
        },
      },
    },
}
```

</details>

<details>
<summary>Other status lines (eg heirline)</summary>
You can also use `require('mssql').lualine_component` in other status lines or
[customise your own](https://github.com/Kurren123/mssql.nvim/issues/56#issuecomment-2912516957). It's a table with the following:

```lua
{
  [1] = function()
        -- returns a string of the status
        end,
  cond = function()
         -- returns a bool, of whether to show this status line
         end
}
```

So eg a [heirline](https://github.com/rebelot/heirline.nvim) component would
look like:

```lua
local lualine_component = require("mssql").lualine_component
local mssql_heirline_component = {
 provider = lualine_component[1],
 condition = lualine_component.cond,
}
```

`mssql.nvim` calls `vim.cmd("redrawstatus")` whenever the status changes, so you
don't need to worry about refreshing

</details>

## Usage

You can call the following as key maps typing your [prefix](#setup) first, as
user commands by doing `:MSSQL <command>` or as functions on `require("mssql")`.

| Key Map | User Command          | Function                       | Description                                                                                                                                                                       |
| ------- | --------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `n`     | `NewQuery`            | `new_query()`                  | Open a new buffer for sql queries                                                                                                                                                 |
| `c`     | `Connect`             | `connect()`                    | Connect the current buffer (you'll be prompted to choose a connection)                                                                                                            |
| `x`     | `ExecuteQuery`        | `execute_query()`              | Execute the selection, or the whole buffer                                                                                                                                        |
| `q`     | `Disconnect`          | `disconnect()`                 | Disconnects the current buffer                                                                                                                                                    |
| `s`     | `SwitchDatabase`      | `switch_database()`            | Prompts, then switches to a database that is on the currently connected server                                                                                                    |
| `d`     | `NewDefaultQuery`     | `new_default_query()`          | Opens a new query and connects to the connection called `default` in your `connections.json`. Useful when combined with the `promptForDatabase` option in the `connections.json`. |
| `r`     | `RefreshIntellisense` | `refresh_intellisense_cache()` | Rebuild the intellisense cache                                                                                                                                                    |
| `e`     | `EditConnections`     | `edit_connections()`           | Open the [connections file](#connections-json-file) for editing                                                                                                                   |
|         | `BackupDatabase`      | `backup_database()`            | Inserts an SQL command to back up the currently connected database                                                                                                                |
|         | `RestoreDatabase`     | `restore_database()`           | Prompts for a `.bak` file, then inserts an SQL command to restore the database from that file                                                                                     |

## Connections json file

The format is `"connection name": connection object`. Eg:

```json
{
  "Connection A": {
    "server": "localhost",
    "database": "dbA",
    "authenticationType": "SqlLogin",
    "user": "Admin",
    "password": "Your_Password",
    "trustServerCertificate": true
  },
  "Connection B": {
    "server": "AnotherServer",
    "database": "dbB",
    "authenticationType": "Integrated",
    "promptForDatabase": true
  }
}
```

Each connection object takes
[standard connection properties](docs/Connections-Json.md). On top of those, you
can also provide these useful properties:

| Property            | Type   | Description                                                                       |
| ------------------- | ------ | --------------------------------------------------------------------------------- |
| `promptForDatabase` | `bool` | After connecting to the server, select which database to connect to.              |
| `promptForPassword` | `bool` | Ask for the password each time you connect instead of storing it in the json file |

## Options

Setup with options:

```lua
require("mssql").setup({
  max_rows = 50,
  max_column_width = 50,
  lsp_settings = {
    intelliSense = { lowerCaseSuggestions = true }
  }
})

-- With callback
require("mssql").setup({
  max_rows = 50,
  max_column_width = 50,
  lsp_settings = {
    intelliSense = { lowerCaseSuggestions = true }
  }
}, function()
  print("mssql.nvim is ready!")
end)
```

| Option                     | Type      | Description                                                                                                                                                       | Default                          |
| -------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| `max_rows`                 | `int?`    | Max rows to return for queries. Needed so that large results don't crash neovim.                                                                                  | `100`                            |
| `max_column_width`         | `int?`    | If a result row has a field text length larger than this it will be truncated when displayed                                                                      | `100`                            |
| `lsp_settings`             | `table`   | Settings passed to the mssql language server. [More info](docs/Lsp-Settings.md)                                                                                   | [See here](docs/Lsp-Settings.md) |
| `data_dir`                 | `string?` | Directory to store download tools and internal config options                                                                                                     | `vim.fn.stdpath("data")`         |
| `tools_file`               | `string?` | Path to an existing [SQL tools service](https://github.com/microsoft/sqltoolsservice/releases) binary. If `nil`, then the binary is auto downloaded to `data_dir` | `nil`                            |
| `connections_file`         | `string?` | Path to a json [connections file](#connections-json-file)                                                                                                         | `<data_dir>/connections.json`    |
| `results_buffer_extension` | `string?` | The file extension of buffers that show query results                                                                                                             | `"md"`                           |
| `results_buffer_filetype`  | `string?` | The filetype (used in neovim to determine the language) of buffers that show query results. Set this to `""` to disable markdown rendering.                       | `"markdown"`                     |

### Notes

- `setup()` runs asynchronously as it may take some time to first download and
  extract the sql tools. Pass a callback as the second argument if you need to
  run code after initialization.
