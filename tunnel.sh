#!/bin/bash

if [ "$1" = "" ]
then
	CONFIG_PATH=$HOME/conf
else
	CONFIG_PATH=$1
fi

source $CONFIG_PATH/tunnel.conf

if [ "$USER" != "$RUN_AS_USER" ]
then
	echo "Error: you must be user '$RUN_AS_USER'!"
	exit 255
fi

function debug_print()
{
	test $DEBUG -eq 1 && echo $(date) $@
}

function log_path_tag()
{
	echo $LOG_PATH/$1
function print_log()
{
	TAG=$1
	shift
	debug_print [$TAG] $@
	echo $(date) - $@ &>> $(log_path_tag $TAG)
}

function add_element()
{
        local VAR=$1; shift
        local TMP=$(eval echo \$$VAR)
        while [ "$1" != "" ]
        do
		if [ -z $TMP ]; then TMP="$1"; else; TMP+=" $1"; fi
                shift
        done
        eval export $VAR=\"$TMP\"
}

function del_element()
{
        local VAR=$1; shift
        local DEL="$*"
        local TMP=
        for i in $(eval echo \$$VAR)
        do
                local X=0 
                for d in $DEL
                do
			test "$i" = "$d" && X=1
                done
                if [ $X -eq 0 ]
                then
			if [ -z $TMP ]; then TMP="$1"; else; TMP+=" $i"; fi
                fi
        done
        eval export $VAR=\"$TMP\"
}

function cleanup()
{
	print_log general "Catched CTRL+C"
	for pid in $TUNNEL_PIDS $CHEK_PID $TUNNEL_PID $WATCHDOG_PID
	do 
		debug_print "Killing pid $pid"
		kill $pid
	done
	for pid in $(pgrep -u $ME_USER ssh) $(pgrep -u $ME_USER nc)
	do
		debug_print "Killing pid $pid"
		kill $pid
	done
	print_log general "Done killing"
}

trap cleanup SIGINT

# Start the watchdog
(PIDS_LIST=
RTT_LIST=
while true
do
	nc -ld4 $WATCHDOG_PORT | (
		read line 
		cmd=${line:0:4}
		param=${line:5}

		case $cmd in
		ADDP)
			debug_print "Received new pid: $param"
			add_element PIDS_LIST $param
			debug_print "Pids: $PIDS_LIST"
			;;

		DELP)
			debug_print "Removed pid: $param"
			del_element PIDS_LIST $param
			debug_print "Pids: $PIDS_LIST"
			;;

		CHEK)
			debug_print "Check received: $param (RTT list: $RTT_LIST)"
			# kill all pending PIDS
			for pid in $RTT_LIST
			do
				debug_print "Killing $pid due to RTTR not received"
				kill -9 $pid
			done
			RTT_LIST=$PIDS_LIST
			;;

		RTTR)
			debug_print "Received RTT from $param"
			del_element RTT_LIST $param
			debug_print "Removed $param from RTT list"
			;;

		TEST)
			debug_print "Test command: $param"
			;;

		*)
			print_log watchdog "invalid command received: $cmd"
			;;
		esac
	)
done
)&
WATCHDOG_PID=$!





TUNNELS=$(ls $TUNNELS_PATH)
TUNNEL_PIDS=
for NAME in $TUNNELS
do
	# Start tunnel
	(
	CONFIG=$TUNNELS_PATH/$NAME

	print_log $NAME "Starting operations for tunnel '$NAME'..."
	# Iterate forever
	while true
	do
		print_log $NAME "Reading configuration from '$CONFIG'..."
		REMOTE_SERVER=
		REMOTE_SERVER_SSH_PORT=
		HOME_SERVER_REMOTE_SSH_PORT=
		SSH_IDENTITY=
		REMOTE_USER=
		REMOTE_TO_HOME=
		HOME_TO_REMOTE=
		source $CONFIG
	
		print_log $NAME "Testing if remote server '$REMOTE_SERVER' is reachable..."
	        if ping -c 10 -W 5 $REMOTE_SERVER &>> $(log_path_tag $TAG)
	        then
			print_log $NAME "Remote server '$REMOTE_SERVER' is reachable!"
	
			LOGIN_IDENTITY=
			test ! -z $SSH_IDENTITY && LOGIN_IDENTITY="-i $SSH_IDENTITY"
			LOGIN_AS=
			test ! -z $REMOTE_USER  && LOGIN_AS="-l $REMOTE_USER"
	
			REMOTES="-R$LOCAL_PORT:127.0.0.1:$WATCHDOG_PORT -R0.0.0.0:$HOME_SERVER_REMOTE_SSH_PORT:127.0.0.1:22"
			LOCALS="-L$LOCAL_PORT:127.0.0.1:$LOCAL_PORT"
			for i in $REMOTE_TO_HOME; do REMOTES="$REMOTES -R$i"; done
			for i in $HOME_TO_REMOTE; do LOCALS="$LOCALS -L$i"; done
	
			COMMAND="ssh $LOCALS $REMOTES $LOGIN_IDENTITY $LOGIN_IDENTITY $LOGIN_AS -p $REMOTE_SERVER_SSH_PORT $REMOTE_SERVER -nNT"
			
			print_log $NAME "Run: '$COMMAND'..."
			$COMMAND &>> $(log_path_tag $TAG) &
			ssh_pid=$!
	
			# Wait a bit to ensure command is running...
			sleep 2
			if ps -p $ssh_pid &> /dev/null
			then
				debug_print "Sending ADDP for $ssh_pid"
				echo ADDP:$ssh_pid | nc -N 127.0.0.1 $WATCHDOG_PORT
	
				# until SSH returns, check network, because SSH might hang for a long time.
				while ps -p $ssh_pid &> /dev/null
				do
					debug_print "Sending RTTR for $ssh_pid"
					echo RTTR:$ssh_pid | nc -N 127.0.0.1 $LOCAL_PORT
					sleep 30
				done

				debug_print "Sending DELP for $ssh_pid"
				echo DELP:$ssh_pid | nc -N 127.0.0.1 $WATCHDOG_PORT
		
				# get return code
				wait $ssh_pid
				print_log $NAME "Command returned code '$?'. Retrying..."
			else
				print_log $NAME "Command failed!"
			fi
	                sleep  $(( 5 + RANDOM % 7 ))  # after disconnection, wait a random bit before retrying
	        else
			print_log $NAME "It seems that '$REMOTE_SERVER' is not reachable. Wait and retry..."
	                sleep 5 # wait a bit before retry ping
	        fi
	done
	)& # close tunnel shell in background to let other tunnels start too
	sleep $(( 1 + RANDOM % 5 )) # add small random sleep to avoid ADDP accatorcing
	TUNNEL_PIDS="$TUNNEL_PIDS "$!
	# Increment local port number for next tunnel
	(( LOCAL_PORT += 1 )) 
done # for all configs

# Periodic CHEK command
(N=0; while true; do sleep 90; debug_print "Sending check n.$N"; echo "CHEK:$N" | nc -N 127.0.0.1 $WATCHDOG_PORT; (( N=N+1 ));done)&
CHEK_PID=$!

wait

