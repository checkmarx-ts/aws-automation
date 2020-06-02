# check if the $ec2_tags environment variable is set to a value
if [[ -v ec2_tags ]]; then
    # check if there are fewer than 2 arguments, and if the first argument is not "start" or "stop", if fail then exit
    if [ $# -lt 2 ] || [ "$1" != "start" ] && [ "$1" != "stop" ]; then
    
    	echo "ERROR:"
    	echo "usage: $0 Action Tag-Key:Tag-Value..."
    	echo -e "\tAction\t\t- start or stop"
    	echo -e "\tTag-Key\t\t- the desired key of the tag you want to query"
    	echo -e "\tTag-Value\t- the desired value of the tag you queried in \"Tag-key\""
    	exit 1
    
    else # otherwise continue
    	
    	input=$@		# this holds all the arguments
    	action=""		# this will hold the first argument (start/stop)
    	keyValFilters=""	# this will hold all the filters created using the supplied tag names and values
    	
    	for arg in $input; do # for each argument
    
    		if [ -z $action ]; then # if its the first argument then store it as the action
    			action=$arg
    
    		else # else its not an action argument, make a key-value filter out of it
    			arrIN=(${arg//:/ }) # split on ":" to separate the key and the value
    			
    			if [ ${#arrIN[@]} -eq 2 ]; then # if there is exactly 1 key and 1 value per argument then make filter (append to string for multiple)
    				keyValFilters="$keyValFilters Name=tag:${arrIN[0]},Values=${arrIN[1]}"
    
    			else # otherwise error
    				echo "ERROR:"
    				echo "The following tag-key and tag-value set has an incorrect format: $arg"
    				echo "The correct format is: \"tag-key:tag-value\""
    				echo "Exiting without modifying any instances"
    				exit 1
    			fi
    		fi
    	done
    
    	if [ $action == "start" ]; then # if its a start action the run start and make sure to only query stopped instances
    		echo "Using filter: $keyValFilters Name=instance-state-name,Values=stopped"
    		IDs=`aws ec2 describe-instances --filters$keyValFilters "Name=instance-state-name,Values=stopped" --query "Reservations[].Instances[].InstanceId" --output text --region $AWS_REGION`
    
    		if [ -z "$IDs" ]; then # if the above command returned no instance IDs
    			echo "ERROR:"
    			echo "No instances matching the above query were found"
    			exit 1
    
    		else
    			echo "Attempting to start the following instances: $IDs"
    			aws ec2 start-instances --instance-ids $IDs --output json --region $AWS_REGION
    		fi
    
    	else # otherwise query only running instances
    		echo "Using filter: $keyValFilters Name=instance-state-name,Values=running"
    		IDs=`aws ec2 describe-instances --filters$keyValFilters "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text --region $AWS_REGION`
    
    		if [ -z "$IDs" ]; then
    			echo "ERROR:"
    			echo "No instances matching the above query were found"
    			exit 1
    		else
    			echo "Attempting to stop the following instances: $IDs"
    			aws ec2 stop-instances --instance-ids $IDs --output json --region $AWS_REGION
    		fi
    	fi
    fi
else
    echo "The \"ec2_tags\" environment variable is not set. Skipping this scheduled task..."
fi
