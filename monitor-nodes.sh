#!/usr/bin/env bash
#
# Open a new tmux window, split it into a left and a right
# pane, run check-node.sh in the right pane that tee its output into
# a named pipe, and follow that pipe from the left pane. See the note above
# the left-pane command below for why this doesn't just use `tail -F`.
#
# This script must be run from a shell that is already inside a tmux
# session (i.e. $TMUX must be set); it operates on that session.

set -euo pipefail

# --- Configuration ---------------------------------------------------------

WINDOW_NAME="monitor-nodes"                   # Name of the new tmux window.
PIPE="/tmp/monitor-nodes.pipe"                # Path of the named pipe.

CMD='
    RED=$'\''\033[1;31m'\''
    GRN=$'\''\033[1;32m'\''
    BLU=$'\''\033[1;34m'\''
    OFF=$'\''\e[m'\''
    ~/Code/Poetic-Poems/helper-scripts/check-nodes.sh |
    sed -uE -es"/\<(ENABLED|ok)\>/$GRN&$OFF/"  \
            -es"/\<RUNNING\>/$RED&$OFF/"       \
            -es"/\<idle\>/$BLU&$OFF/"
  '
PERIOD=300

# --- Sanity checks ----------------------------------------------------------

if [[ -z "${TMUX:-}" ]]; then
    echo "Error: this script must be run from within a tmux session." >&2
    exit 1
fi

# --- Named pipe --------------------------------------------------------------

if [[ ! -p "$PIPE" ]]; then
    mkfifo "$PIPE"
fi

# --- Window and panes ---------------------------------------------------------

# Create the new window and capture the ID of its (initially only) pane.
# Using pane IDs (e.g. %12) rather than indices avoids any assumption about
# the value of the `pane-base-index` option.
left_pane=$(tmux new-window -n "$WINDOW_NAME" -P -F '#{pane_id}')

# Split that pane horizontally, i.e. into left and right halves, and
# capture the ID of the newly created (right-hand) pane.
right_pane=$(tmux split-window -h -t "$left_pane" -P -F '#{pane_id}')

# --- Start the processes ------------------------------------------------------

# Right pane: producer, piped through tee and perl into the named pipe.
rows='$(($(tmux display-message -p "#{pane_height}") - 1))'
tmux send-keys -t "$right_pane" "
while true; do
  $CMD
  sleep \$(($PERIOD - \$(date +%s)%$PERIOD))
done |
tee >(
  perl -ne '
    BEGIN{
      $| = 1;
    }
    push @l, \$_;
    \$rows = qx'\\''echo $rows'\\'';
    print shift @l while @l > \$rows;
  ' >'$PIPE'
)
"

# Left pane: consumer.
#
# NB: `tail -F "$PIPE"` (the obvious choice) does not work reliably against a
# FIFO.  tail decides whether a file has grown by checking its size, and a FIFO
# always reports a size of 0, so tail never notices new data while the writer
# stays open; it only flushes what it has buffered once the writer closes.
# Against a producer that never closes, the left pane would sit empty forever.
# If you want literal `tail -F` anyway (e.g. your real writer does periodically
# close and reopen the pipe), swap in this line instead:
#
#   tmux send-keys -t "$left_pane" "tail -F '${PIPE}'" Enter
#
# The line below opens the pipe for reading AND writing on fd 3 first.
# That keeps a permanent reader on the pipe at all times, so `cat` sees
# new data the instant it is written, and the producer is protected from
# being killed by SIGPIPE if this pane's reader is ever restarted.
tmux send-keys -t "$left_pane" "
yes '' | head -$rows
exec 3<>'${PIPE}'
cat <&3
"

# Leave the user focused on the left (consumer) pane.
tmux select-pane -t "$left_pane"
