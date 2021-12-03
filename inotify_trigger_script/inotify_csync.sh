#!/bin/bash

# Watch csync directories and sync changes via csync2
#
# $1: csync2 options to passthrough

file_events="move,delete,attrib,create,close_write,modify" # File events to monitor - no spaces in this list
queue_file=/home/learn4gd/tmp/inotify_queue.log            # File used for event queue

check_interval=0.5                   # Time between queue check in seconds, fractions allowed
num_lines_until_reset=200000         # Reset queue log file after reading this many lines
num_batched_changes_threshold=15000  # Number of changes in one batch that will trigger a full sync and reset

cfg_path=/usr/local/etc
cfg_file=csync2.cfg

csync_opts="$*"

# Start csync server - use subshell so it terminates when script exits
# TODO: Separate hostname from other csync options so it can be used here exclusively
csync2 -ii $csync_opts &
csync_pid=$!

# Stop background csync server on exit
trap "kill $csync_pid" EXIT

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
echo "OPTS: $csync_opts"

if [[ ${#includes[@]} -eq 0 ]]
then
	echo "No include locations found"
	exit 1
fi

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
trap "kill $inotify_pid; kill $csync_pid;" EXIT

# Run a full check and sync operation
function csync_full_sync()
{
	echo "* FULL SYNC"
	csync2 $csync_opts -x
	echo "  - Done"
}

# Run a full check and sync before queue monitoring begins
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
			# Reset queue file
			echo "* RESET QUEUE"
			truncate -s 0 $queue_file
			queue_line_pos=1

			# Run a full sync in case inotify added after read
			csync_full_sync
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
		truncate -s 0 $queue_file
		queue_line_pos=1

		csync_full_sync

		# Jump back to sleep
		continue
	fi

	# Process queue with csync
	# Split into two stages so that outstanding dirty files can be processed regardless of when or where they were marked

	#   1. Check and possibly mark queued files as dirty
	echo "  - Checking ${#csync_files[@]} files"
	csync2 $csync_opts -c "${csync_files[@]}"

	#   2. Update outstanding dirty files on peers
	echo "  - Updating all dirty files"
	csync2 $csync_opts -u

	echo "  - Done"
done
