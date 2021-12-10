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
echo "PASSED OPTS: ${csync_opts[*]}"


# --- CSYNC SERVER ---

# Extract server-specific options
server_opts=()
if [[ $* =~ -N[[:space:]]?([[:alnum:]\.]+) ]]  # hostname
then
	server_opts+=(-N "${BASH_REMATCH[1]}") # added as two elements
else
	echo "*** WARNING: No hostname specified ***"
	sleep 1
fi
if [[ $* =~ -D[[:space:]]?([[:graph:]]+) ]]    # database path
then
	server_opts+=(-D "${BASH_REMATCH[1]}")
fi

echo "SERVER OPTS: ${server_opts[*]}"

# Start csync server outputting timings to log for monitoring activity status
csync2 -ii -t "${server_opts[@]}" &> $csync_log &
csync_pid=$!

# Wait for server startup before checking log for errors
sleep 0.5
ps --pid $csync_pid > /dev/null
if [[ $? -ne 0 ]]
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

echo "INC: ${includes[*]}"
echo "EXC: ${excludes[*]}"

if [[ ${#includes[@]} -eq 0 ]]
then
	echo "No include locations found"
	exit 1
fi


# --- INOTIFY FILE MONITOR ---

# Reset queue file
truncate -s 0 $queue_file

# Monitor for events in the background and add altered files to queue file
while read -r file
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

	# Add file to queue
	echo "$file" >> $queue_file

done < <(inotifywait --monitor --recursive --event $file_events --format "%w%f" "${includes[@]}") &

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
	mapfile -t file_list_no_dups < <(printf "%s\n" "${file_list[@]}" | sort -u)

	# Recreate list without files in subdirectories - the csync check below is recursive so passing inner files is unnecessary

	# NOTE: Works nicely for create but not deletes because the files don't exist to check for directory status
	# Would have to bring along the ISDIR status from the inotify events to improve this
	# However, no worthwhile speed increase in csync check when passing just one path vs. all the files within so better to scrap this and keep the simplicity
	csync_paths=()
	i=0
	num_files=${#file_list_no_dups[@]}
	while [[ $i -lt $num_files ]]
	do
		pathname=${file_list_no_dups[$i]}

		# Add this entry and advance
		csync_paths+=("$pathname")
		((i++))

		if [[ -d $pathname ]]
		then
			# Directory - skip subsequent entries if they're within this directory
			while [[ $i -lt $num_files ]]
			do
				if [[ ${file_list_no_dups[$i]} != $pathname* ]]
				then
					# File entry does not begin with subdirectory - stop the check
					# The list is sorted so no match equals the end of that path in the list
					break;
				fi
				((i++))
			done
		fi
	done

	# DEBUG: Output files processed in each cycle
	# printf "%s\n" "${csync_paths[@]}" >> "/tmp/csync_$(date +%s%3N).log"

	# Check number of files in this batch
	if [[ ${#csync_paths[@]} -ge $num_batched_changes_threshold ]]
	then
		# Large batch - run full sync and reset
		# This avoids breaching any max file argument limits and also acts as a safety net if inotify misses events when there are many changing files
		echo "* LARGE BATCH (${#csync_paths[@]} files)"

		csync_full_sync

		# Jump back to sleep
		continue
	fi

	# Wait until csync server is quiet
	csync_wait

	# Process files by sending csync commands
	# Split into two stages so that outstanding dirty files can be processed regardless of when or where they were marked

	#   1. Check and possibly mark queued files as dirty - recursive so nested dirs are handled even if inotify misses them
	echo "  - Checking ${#csync_paths[@]} files"
	csync2 "${csync_opts[@]}" -cr "${csync_paths[@]}"

	#   2. Update outstanding dirty files on peers
	echo "  - Updating all dirty files"
	csync2 "${csync_opts[@]}" -u

	echo "  - Done"
done
