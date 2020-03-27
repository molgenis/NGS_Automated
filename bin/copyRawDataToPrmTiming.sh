#!/bin/bash

set -e
set -u

# module load NGS_Automated/beta-bare; copyRawDataToPrmTiming.sh -g umcg-atd -s gattaca02.gcc.rug.nl -r /groups/umcg-atd/scr01/ -l DEBUG


#
##		This script will run on chaperone or boxy. First it will pull the project files, from projects from whom the demultiplex pipeline is finished.
###		And then it will check if there is a .finished file, if there is, the copyRawDataToPrm is finished.
####	If there is no .finished file, it will check if there is a .started file and if this file is older than 6h (last time it was modified).
###		If the .started is not older than 6h, no worries the pipeline is probably still running.
##		If the .started file is older than 6h, it will generate a copyRawDataToPrmTiming.failed. 
#	
 

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi


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
	-s	Source server address from where the rawdate will be fetched
		Must be a Fully Qualified Domain Name (FQDN).
		E.g. gattaca01.gcc.rug.nl or gattaca02.gcc.rug.nl
	-r	Root dir on the server specified with -s and from where the raw data will be fetched (optional).
		By default this is the SCR_ROOT_DIR variable, which is compiled from variables specified in the
		<group>.cfg, <source_host>.cfg and sharedConfig.cfg config files (see below.)
		You need to override SCR_ROOT_DIR when the data is to be fetched from a non default path,
		which is for example the case when fetching data from another group.
Config and dependencies:

	This script needs 3 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg	for the group specified with -g
		2. <this_host>.cfg	for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
		3. <source_host>.cfg	for the source server. E.g.: "<hostname>.cfg" (Short name without domain)
		4. sharedConfig.cfg	for all groups and all servers.
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
declare group=''
declare sourceServerFQDN=''
declare sourceServerRootDir=''

while getopts "g:l:s:r:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			GROUP="${OPTARG}"
			;;
		s)
			sourceServerFQDN="${OPTARG}"
			sourceServer="${sourceServerFQDN%%.*}"
			;;
		r)
			sourceServerRootDir="${OPTARG}"
			;;
		l)
			l4b_log_level="${OPTARG^^}"
			l4b_log_level_prio="${l4b_log_levels["${l4b_log_level}"]}"
			;;
		\?)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Invalid option -${OPTARG}. Try $(basename "${0}") -h for help."
			;;
		:)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename "${0}") -h for help."
			;;
		*)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Unhandled option. Try $(basename "${0}") -h for help."
			;;	esac
done

#
# Check commandline options.
#
if [[ -z "${GROUP:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -z "${sourceServerFQDN:-}" ]]
then
log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a Fully Qualified Domain Name (FQDN) for sourceServer with -s.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${GROUP}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/${sourceServer}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
)

for configFile in "${configFiles[@]}"; do 
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile} ..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Cannot source ${configFile}."
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done

#
# Overrule group's SCR_ROOT_DIR if necessary.
#
if [[ ! -z "${sourceServerRootDir:-}" ]]
then
	SCR_ROOT_DIR="${sourceServerRootDir}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi


#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

logsDir="${PRM_ROOT_DIR}/logs/"

## check if there are any runs to process
checkProjectSheet=$(ssh ${DATA_MANAGER}@${sourceServerFQDN} "find ${SCR_ROOT_DIR}/logs/Timestamp/ -type f -iname *.csv")
if [[ -z "${checkProjectSheet}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "All runs are processed, no new project sheet available"
fi

for projectSheet in $(ssh ${DATA_MANAGER}@${sourceServerFQDN} "ls ${SCR_ROOT_DIR}/logs/Timestamp/*.csv")
do 

	project=$(basename "${projectSheet}" .csv)

	sequenceRun=$(ssh ${DATA_MANAGER}@${sourceServerFQDN} "cat ${projectSheet}")
	
	## check if the coptRawDataToPrm step started.
	if [[ ! -d "${logsDir}/${sequenceRun}" ]]
	then
		continue
	fi

	## determine run number.
	if [ -e "${logsDir}/${sequenceRun}/"*".copyRawDataToPrm.finished" ]
	then
		run=$(basename "${logsDir}/${sequenceRun}/"*".copyRawDataToPrm.finished" .copyRawDataToPrm.finished)
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "using run number: ${run}"
	elif [ -e "${logsDir}/${sequenceRun}/"*".copyRawDataToPrm.finished"  ]
	then
		run=$(basename "${logsDir}/${sequenceRun}/"*".copyRawDataToPrm.started" .copyRawDataToPrm.started)
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "using run number: ${run}"
	fi

	if [ -e "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.finished" ]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${sequenceRun}/${run}.${SCRIPT_NAME} completely done"
		continue
	fi

	touch "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"

	echo -e "moment of checking run time: $(date)\nsequenceRun: ${sequenceRun}\nproject: ${project}" > "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Using sequenceRun: ${sequenceRun}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Using project: ${project}"

	## check if the copyRawDataToPrm step is finished. If it is not finished, check how old the .started file is.
	if [ -e "${logsDir}/${sequenceRun}/${run}.copyRawDataToPrm.finished" ]
	then
		echo -e "copyRawDataToPrm for sequenceRun: ${sequenceRun} is finished" >> "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
		touch "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.finished"
		echo -e "${run}.${SCRIPT_NAME}.finished" >> "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "copyRawDataToPrm for sequenceRun: ${sequenceRun} is finished"
		continue
	else
		timeStampCopyRawDataToPrm=$(find "/${logsDir}/${sequenceRun}/" -type f -mmin +240 -iname "${run}.copyRawDataToPrm.started")
		if [[ -z "${timeStampCopyRawDataToPrm}" ]]
		then
			echo -e "copyRawDataToPrm for sequenceRun: ${sequenceRun} is still running" >> "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "copyRawDataToPrm for sequenceRun: ${sequenceRun} is still running"
		else
			echo -e "copyRawDataToPrm for sequenceRun: ${sequenceRun} is running over 4h\n" \
			"time ${run}.copyRawDataToPrm.started was last modified:" \
			$(stat -c %y "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.copyRawDataToPrm.started") \
			>> "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.log"

			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "copyRawDataToPrm for sequenceRun: ${sequenceRun} is running over 4h"
			touch "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.failed"
			echo -e "Dear HPC helpdesk,\n\nPlease check if there is something wrong with the pipeline.\nThe copyRawDataToPrm has started but is not finished after 4h for sequenceRun ${sequenceRun}.\n\nKind regards\nHPC" > "${PRM_ROOT_DIR}/logs/${sequenceRun}/${run}.${SCRIPT_NAME}.failed"
		fi
	fi
done

trap - EXIT
exit 0
