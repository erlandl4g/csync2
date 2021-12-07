#!/bin/bash

# Watch csync directories and sync changes via csync2
#
# $1: csync2 options to passthrough


# --- SETTINGS ---

file_events="move,delete,attrib,create,close_write,modify" # File events to monitor - no spaces in this list
queue_file=/home/learn4gd/tmp/inotify_queue.log            # File used for event queue
csync_log=/home/learn4gd/tmp/csync_server.log              # File used for monitoring csync server timings

check_interval=0.5                   # Seconds between queue checks - fractions allowed
num_lines_until_reset=200000         # Reset queue log file after reading this many lines
num_batched_changes_threshold=15000  # Number of changes in one batch that will trigger a full sync and reset

cfg_path=/usr/local/etc
cfg_file=csync2.cfg

# Separate all passed options for csync
csync_opts=("$@")


# --- CSYNC SERVER ---

# Extract server-specific options
server_opts=()
if [[ $* =~ -N[[:space:]]?([[:alnum:]\.]+) ]]  # hostname
then
	server_opts+=(-N "${BASH_REMATCH[1]}") # added as two elements
fi
if [[ $* =~ -D[[:space:]]?([[:graph:]]+) ]]    # database path
then
	server_opts+=(-D "${BASH_REMATCH[1]}")
fi

# Start csync server outputting timings to log for monitoring activity status
csync2 -ii -t "${server_opts[@]}" &> $csync_log &
csync_pid=$!

# Wait for server startup before checking log for errors
sleep 0.5
tail --lines=1 $csync_log | grep --quiet error  # is the last line an error?
if [[ $? -eq 0 ]]
then
	echo "Failed to start csync server"
	exit 1
fi

# Stop background csync server on exit
trap "kill $csync_pid" EXIT

echo "* SERVER RUNNING"


# --- PARSE CSYNC CONFIG FILE ---

# Parse csync2 config file for included and excluded locations
while read -r key value
do
	# Ignore comments and blank lines
	if [[ ! $key =~ ^\ *# && -n $key ]]
	then
		if [[ $key == "include" ]]
		then
			includes+=("${value%;}")
		elif [[ $key == "exclude" ]]
		then
			excludes+=("${value%;}")
		fi
	fi
done < "$cfg_path/$cfg_file"

echo " INC: ${includes[*]}"
echo " EXC: ${excludes[*]}"
echo "OPTS: ${csync_opts[*]}"

if [[ ${#includes[@]} -eq 0 ]]
then
	echo "No include locations found"
	exit 1
fi


# --- INOTIFY FILE MONITOR ---

# Reset queue file
truncate -s 0 $queue_file

# Monitor for events in the background and pipe triggered files to queue file
{
	inotifywait --monitor --recursive --event $file_events --format "%w%f" "${includes[@]}" | while read -r file
	do
		# Check if excluded
		for excluded in "${excludes[@]}"
		do
			if [[ $file == $excluded* ]]
			then
				# Excluded - skip this file and return to inotifywait
				continue 2
			fi
		done

		echo "$file" >> $queue_file
	done
} &
# Stop background inotify monitor and csync server on exit
inotify_pid=$!

# Stop background inotify monitor and csync server on exit
trap "kill $inotify_pid; kill $csync_pid" EXIT

echo "* INOTIFY RUNNING"


# --- HELPERS ---

# Wait until csync server is quiet
function csync_wait()
{
	# Wait until the end timestamp record appears in the last log line or if the file is empty
	until tail --lines=1 $csync_log | grep --quiet TOTALTIME || [[ ! -s $csync_log ]]
	do
		echo "...waiting for csync server..."
		sleep $check_interval
	done
}


# Run a full check and sync operation
function csync_full_sync()
{
	echo "* FULL SYNC"

	# First wait until csync server is quiet
	csync_wait

	csync2 "${csync_opts[@]}" -x
	echo "  - Done"
}


# Reset queue
function reset_queue()
{
	echo "* RESET QUEUE LOG"

	# Reset queue log file
	truncate -s 0 $queue_file
	queue_line_pos=1

	# Run a full sync in case inotify triggered during reset
	csync_full_sync

	# Reset csync server log too
	truncate -s 0 $csync_log
}


# --- QUEUE PROCESSING ---

# First run a full check and sync before queue processing begins - after file monitor started so no changes are missed in-between
csync_full_sync


# Periodically monitor inotify queue file
queue_line_pos=1
while true
do
	# Delay between updates to allow for batches of inotify events to be gathered
	sleep $check_interval

	# Make array starting from last read position in queue file
	mapfile -t file_list < <(tail --lines=+$queue_line_pos $queue_file)

	if [[ ${#file_list[@]} -eq 0 ]]
	then
		# No new entries - time to check for reset
		if [[ $queue_line_pos -ge $num_lines_until_reset ]]
		then
			reset_queue
		fi
		# Jump back to sleep
		continue
	fi

	echo "* PROCESSING QUEUE (line $queue_line_pos)"

	# Advance queue file position
	((queue_line_pos+=${#file_list[@]}))

	# Remove duplicates
	mapfile -t csync_files < <(printf "%s\n" "${file_list[@]}" | sort -u)

	# DEBUG: Output files processed in each cycle
	# printf "%s\n" "${csync_files[@]}" >> "/tmp/csync_$(date +%s%3N).log"

	# Check number of files in this batch
	if [[ ${#csync_files[@]} -ge $num_batched_changes_threshold ]]
	then
		# Large batch - run full sync and reset
		# This is primarily to guard against missed events that can occur when the inotifywait buffer is full
		echo "* LARGE BATCH (${#csync_files[@]} files)"

		reset_queue

		# Jump back to sleep
		continue
	fi

	# Wait until csync server is quiet
	csync_wait

	# Process files by sending csync commands
	# Split into two stages so that outstanding dirty files can be processed regardless of when or where they were marked

	#   1. Check and possibly mark queued files as dirty
	echo "  - Checking ${#csync_files[@]} files"
	csync2 "${csync_opts[@]}" -c "${csync_files[@]}"

	#   2. Update outstanding dirty files on peers
	echo "  - Updating all dirty files"
	csync2 "${csync_opts[@]}" -u

	echo "  - Done"
done
