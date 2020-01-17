#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename "${0}")"
SCRIPT_NAME="${SCRIPT_NAME%.*sh}"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname 2>/dev/null || echo 'no login name')"

#
##
### Functions.
##
#

if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
	# shellcheck source=lib/sharedFunctions.bash
	source "${LIB_DIR}/sharedFunctions.bash"
else
	printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
	trap - EXIT
	exit 1
fi

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
======================================================================================================================
Script to start NGS_Demultiplexing automagicly when sequencer is finished, and corresponding samplesheet is available.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g	Group.
	-l	Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

This script needs 3 config files, which must be located in ${CFG_DIR}:
 1. <group>.cfg	for the group specified with -g
 2. <host>.cfg	for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
 3. sharedConfig.cfg	for all groups and all servers.
In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.

======================================================================================================================

EOH
	trap - EXIT
	exit 0
}


#
##
### Main.
##
#

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
while getopts "g:l:h" opt
do
	case $opt in
		h)
			showHelp
			;;
		g)
			GROUP="${OPTARG}"
			;;
		l)
			l4b_log_level=${OPTARG^^}
			l4b_log_level_prio=${l4b_log_levels[${l4b_log_level}]}
			;;
		\?)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Invalid option -${OPTARG}. Try $(basename "${0}") -h for help."
			;;
		:)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename "${0}") -h for help."
			;;
	esac
done

#
# Check commandline options.
#
if [[ -z "${GROUP:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
	"${CFG_DIR}/${GROUP}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
)

for configFile in "${configFiles[@]}"
do
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config file ${configFile}..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		# Disable shellcheck code syntax checking for config files.
		# shellcheck source=/dev/null
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" "${?}" "Cannot source ${configFile}."
		# shellcheck source=/dev/null
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done

#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#

if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi




#
##	  This script will run on gattaca0[1-2]. And will check how old the run0*.demultiplexing.started is (last time it is modified). 
###	 It will make a file per project, called like the project.csv, containing the run number.
##	  LZ will pull these files, so the project can be monitored on LZ. 
# 

timeStampDir="${SCR_ROOT_DIR}/logs/Timestamp/"

## check if there are samplesheet available for run time checking.
checkSampleSheet=$(find "${SCR_ROOT_DIR}/Samplesheets/" -maxdepth 1 -type f -name "*.csv")

if [[ -z "${checkSampleSheet}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "All runs are processed, no new sample sheet available"
fi

for sampleSheet in $(ls "${SCR_ROOT_DIR}/Samplesheets/"*".csv")
do 
	sequenceRun=$(basename "${sampleSheet}" .csv)
	## check if there is a sequence run corresponding to the samplesheet.
	if [[ ! -d "${SCR_ROOT_DIR}/runs/${sequenceRun}/" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "There is no data corresponding to run:${sequenceRun}, check if the samplesheet is correct"
		continue
	fi
	## check if the sequencer is ready.
	if [[ ! -d "${SCR_ROOT_DIR}/logs/${sequenceRun}/" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sequencer is not finished yet for run ${sequenceRun}"
		continue
	fi
	
	## determine run number.
	if [ -e "${SCR_ROOT_DIR}/logs/${sequenceRun}/"*".demultiplexing.finished" ]
	then
		run=$(basename "${SCR_ROOT_DIR}/logs/${sequenceRun}/"*".demultiplexing.finished" .demultiplexing.finished)
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "using run number: ${run}"
	elif [ -e "${SCR_ROOT_DIR}/logs/${sequenceRun}/"*".demultiplexing.started" ]
	then
		run=$(basename "${SCR_ROOT_DIR}/logs/${sequenceRun}/"*".demultiplexing.started" .demultiplexing.started)
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "using run number: ${run}"
	fi

	touch "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
	echo -e "moment of checking run time: $(date)\nsamplesheet: ${sampleSheet}\n" > "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "using sampleSheet: ${sampleSheet}"

	## check if the demultiplexing is finished. If it is, make a Timestamp sheet so the pipeline and copyRawDataToPrm steps can be monitored.
	## If the demultiplexing is not finished yet, check how old the .started file is.
	if [ -e "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.demultiplexing.finished" ]
	then
		declare -a sampleSheetColumnNames=()
		declare -A sampleSheetColumnOffsets=()
		declare -a projects=()
		
		IFS="," sampleSheetColumnNames=($(head -1 "${sampleSheet}"))
		
		for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]:-0} ; offset++ ))
		do
			sampleSheetColumnOffsets["${sampleSheetColumnNames[${offset}]}"]="${offset}"
		done

		if [[ ! -z "${sampleSheetColumnOffsets['project']+isset}" ]] 
		then
			projectFieldIndex=$((${sampleSheetColumnOffsets['project']} + 1))
			IFS=$'\n' projects=($(tail -n +2 "${sampleSheet}" | cut -d "," -f "${projectFieldIndex}" | sort | uniq ))
		fi

		for project in "${projects[@]}"
		do
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "project: ${project}"
			echo -e "project: ${project}" >> "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"

			projectStampFile="${timeStampDir}/${project}.csv"
			if [[ -e "${projectStampFile}" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "projectTimeStampFile: ${projectStampFile} already exist"
			else
				echo -e "${sequenceRun}" >> "${projectStampFile}"
			fi
			touch "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.finished"
			echo -e "Demultiplexing is finished for sequence run ${sequenceRun}" >> "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing is finished for sequence run ${sequenceRun}"
		done
	else
		timeStamp=$(find "${SCR_ROOT_DIR}/logs/${sequenceRun}/" -type f -mmin +60 -iname "${run}.demultiplexing.started")
		if [[ -z "${timeStamp}" ]]
		then
			echo -e "Demultiplexing is running for sequence run ${sequenceRun}" >> "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing is running for sequence run ${sequenceRun}"
		else
			echo -e "demultiplexing.started file is OLDER than 1 hour.\ntime ${run}.demultiplexing.started was last modified:" \
			$(stat -c %y "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.demultiplexing.started") >> "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
			
			touch "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.failed"
			echo -e "Dear HPC helpdesk,\n\nPlease check if there is something wrong with the demultiplexing pipeline.\nThe demultiplexing of run ${sequenceRun} is not finished after 1h.\n\nKind regards\nHPC" > "${SCR_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.failed"
			
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing.started file is OLDER than 1 hour for sequencerun: ${sequenceRun}"
		fi 
	fi
done

trap - EXIT
exit 0
