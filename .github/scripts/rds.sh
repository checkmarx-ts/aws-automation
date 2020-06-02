# check if the ${DB_NAMES} environment variable is set to a value
if [[ -v DB_NAMES ]]; then
    # check if there are fewer than 2 argument, and if the first argument is not "start" or "stop", if fail then exit
    if [ $# -lt 2 ] || [ "$1" != "start" ] && [ "$1" != "stop" ]; then
    
    	echo "ERROR:"
    	echo "usage: $0 Action DB-Instance(s)..."
    	echo -e "\tAction\t\t- start or stop"
    	echo -e "\tDB-Instance(s)\t- the name(s) of the database(s) you want to query"
    	exit 1
    
    else # otherwise continue
    	input=$@		# this holds all the arguments
    	action=""		# this will hold the first argument (start/stop)
    	
    	for arg in $input; do # for each argument
    
    		if [ -z $action ]; then # if its the first argument then store it as the action
    			action=$arg
    
    		else # else its not an action argument, make a key-value filter out of it
    			echo "Querying to $action RDS Instance: $arg"
    
    			aws rds $action-db-instance --db-instance-identifier $arg --output json --region $AWS_REGION
    
    			if [ $? -eq 0 ]; then 
    				echo -e "\n$action commmand successfully executed on $arg"
    			fi
    			echo -e "\n-----------------------------------------------------------------------------\n"
    		fi
    	done
    fi
else
    echo "The \"DB_NAMES\" environment variable is not set. Skipping this scheduled task..."
fi
