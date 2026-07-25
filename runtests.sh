#!/usr/bin/env bash
set -euo pipefail

cleanup() {
	if [[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" && "$TEST_TMP_DIR" == /tmp/mssql-test-env-* ]]; then
		rm -rf "$TEST_TMP_DIR"
	fi
}
trap cleanup EXIT INT TERM

export NVIM_APPNAME="mssql-nvim-test-suite"

# persistent caching directory - persists across runs and reboots
# allows use of SKIP_DOWNLOAD env var to reuse existing SQL Tools Service binary
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share/mssql-test-data}"

# temporary directories for isolation and cleanup of config/state/backup files
# files generated during test execution
TEST_TMP_DIR=$(mktemp -d /tmp/mssql-test-env-XXXXXX)
readonly TEST_TMP_DIR
export TEST_TMP_DIR
export XDG_CONFIG_HOME="$TEST_TMP_DIR/config"
export XDG_STATE_HOME="$TEST_TMP_DIR/state"

mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

export DbServer="${DbServer:-localhost}"
export DbUser="${DbUser:-sa}"
export DbPassword="${DbPassword:-Test_Password_123}"
export DbDatabase="${DbDatabase:-tempdb}"
export SKIP_DOWNLOAD="${SKIP_DOWNLOAD-1}"

command -v nvim >/dev/null || {
	echo "nvim required" >&2
	exit 1
}

[[ -f "runtests.lua" ]] || {
	echo "runtests.lua not found" >&2
	exit 1
}
#
echo "Test directory: $TEST_TMP_DIR"
echo "Data directory: $XDG_DATA_HOME"
echo "Skip download: $SKIP_DOWNLOAD"

# first run will download the binaries to ~/.local/share/mssql-test-data/mssql-nvim-test-suite/mssql.nvim
set +e
nvim -u runtests.lua --headless "$@"
EXIT_CODE=$?
set -e

# for now move tests lsp.log into repo root before cleanup is run
if [[ -f "$XDG_STATE_HOME/${NVIM_APPNAME}/logs/lsp.log" ]]; then
	mv "$XDG_STATE_HOME/${NVIM_APPNAME}/logs/lsp.log" ./test_lsp.log
fi

exit $EXIT_CODE
