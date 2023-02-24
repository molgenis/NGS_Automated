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
set -o pipefail # Fail when any command in series of piped commands failed as opposed to only when the last command failed.

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
	This script needs 4 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg       for the group specified with -g
		2. <this_host>.cfg   for this server. E.g.: "${HOSTNAME_SHORT}.cfg"
		3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================
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
while getopts ":g:l:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
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
			;;
	esac
done

#
# Check commandline options.
#
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
)

for configFile in "${configFiles[@]}"
do
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile} ..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		# Disable shellcheck code syntax checking for config files.
		# shellcheck source=/dev/null
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Cannot source ${configFile}."
		# shellcheck source=/dev/null
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
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
# Make sure only one copy of this script runs simultaneously per group.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
lockFile="${SCR_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${SCR_ROOT_DIR}/logs ..."

#
# Sequencer is writing to this location: ${SEQ_DIR}
# Looping through sub dirs to see if all files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "find ${SEQ_DIR}/ -mindepth 1 -maxdepth 1 -type d -o -type l"
mapfile -t runs < <(find "${SEQ_DIR}/" -mindepth 1 -maxdepth 1 -type d -o -type l)

pipeline='NGS_Demultiplexing'

for i in "${runs[@]}"
do
	run=$(basename "${i}")
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking ${run} ..."
	#export JOB_CONTROLE_FILE_BASE="${SCR_ROOT_DIR}/logs/${project}/run01.demultiplexing"
	demultiplexingJobControleFileBase="${SCR_ROOT_DIR}/logs/${run}/run01.demultiplexing"
	if [[ -f "${demultiplexingJobControleFileBase}.finished" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${demultiplexingJobControleFileBase}.finished: Skipping finished ${run}."
		continue
	elif [[ -f "${demultiplexingJobControleFileBase}.started" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${demultiplexingJobControleFileBase}.started: Skipping ${run}, which is already getting processed."
		continue
	elif [[ ! -f "${SCR_ROOT_DIR}/Samplesheets/${pipeline}/${run}.csv" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "No samplesheet found: skipping ${run}."
		continue
	fi
	export JOB_CONTROLE_FILE_BASE="${demultiplexingJobControleFileBase}"

	mkdir -p "${SCR_ROOT_DIR}/logs/${run}/"

	#
	# Check if the run has already completed.
	#
	sequencer=$(echo "${run}" | awk 'BEGIN {FS="_"} {print $2}')
	miSeqCompleted='no'
	miSeqNameRegex='^M[0-9][0-9]*$'
	if [[ -f "${SEQ_DIR}/${run}/RTAComplete.txt" ]] && [[ "${sequencer}" =~ ${miSeqNameRegex} ]]
	then
		miSeqCompleted='yes'
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Miseq run detected: miSeqCompleted=yes for ${run}."
	fi
	if [[ -f "${SEQ_DIR}/${project}/RunCompletionStatus.xml" || "${miSeqCompleted}" == 'yes' ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sequencer has completed data generation for: ${run}."
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Sequencer is busy producing data: skipping ${run}."
		continue
	fi
	#
	# All ingredients are present and the project has not been processed yet: generate FastQ files.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Generating and submitting jobs for ${project} ..." \
		2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
	echo "started: $(date +%FT%T%z)" > "${SCR_ROOT_DIR}/logs/${project}/run01.demultiplexing.totalRuntime"
	{
		mkdir -v -p "${SCR_ROOT_DIR}/generatedscripts/${pipeline}/${run}/"
		cd "${SCR_ROOT_DIR}/generatedscripts/${pipeline}/${run}/"
		cp -v "${SCR_ROOT_DIR}/Samplesheets/${pipeline}/${run}.csv" "${run}.csv"
		cp -v "${EBROOTNGS_DEMULTIPLEXING}/generate_template.sh" ./ 
		bash generate_template.sh "${run}" "${SCR_ROOT_DIR}" "${group}"
		cd "${SCR_ROOT_DIR}/runs/${pipeline}/${run}/jobs"
		bash submit.sh
	} >> "${JOB_CONTROLE_FILE_BASE}.started" 2>&1
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "jobs submitted"
	#
	# Track and Trace.
	#
	timeStamp="$(date +%FT%T%z)"
	printf '%s\n' 'run_id,group,process_raw_data,copy_raw_prm,projects,date' \
		> "${JOB_CONTROLE_FILE_BASE}.trace_post_overview.csv"
	printf '%s\n' "${run},${group},started,,,${timeStamp}" \
		>> "${JOB_CONTROLE_FILE_BASE}.trace_post_overview.csv"
done

trap - EXIT
exit 0
