#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.
set -o pipefail # Fail when any command in series of piped commands failed as opposed to only when the last command failed.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename ${0} .bash)"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname)"

#
##
### Functions.
##
#
if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]; then
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
===============================================================================================================
Script to check the status of the pipeline and emails notification
Usage:
	$(basename $0) OPTIONS
Options:
	-h   Show this help.
	-g   Group.
	-e   Enable email notification. (Disabled by default.)
	-l   Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

	This script needs 3 config files, which must be located in ${CFG_DIR}:
	1. <group>.cfg       for the group specified with -g
	2. <host>.cfg        for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
	3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================
EOH
	trap - EXIT
	exit 0
}


#
# Check for status and email notification
#
function notification(){
	
	local    _phase="${1%:*}"
	local    _state="${1#*:}"
	local -a _project_state_files=()
	local    _file
	local    _timestamp
	local    _project
	local    _run
	local    _header
	local    _subject
	local    _body
	local    _email_to
	
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Will notify about projects with phase ${_phase} in state: ${_state}."
	
	if $(ls "${TMP_ROOT_DIR}/logs/"*"/"*".${_phase}.${_state}" 1> /dev/null 2>&1)
	then
		read -r -a _project_state_files < <(ls -1 "${TMP_ROOT_DIR}/logs/"*"/"*".${_phase}.${_state}") \
			|| log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" $? "Failed to create a list of *.pipeline.${_state} files."
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No *.pipeline.${_state} present."
		return
	fi
	
	if [[ -f "${TMP_ROOT_DIR}/logs/mailinglist.txt" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${TMP_ROOT_DIR}/logs/mailinglist.txt."
		_email_to="$(cat "${TMP_ROOT_DIR}/logs/mailinglist.txt" | tr '\n' ' ')"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed mailinglist and will send mail to: ${_email_to}."
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Missing ${TMP_ROOT_DIR}/logs/mailinglist.txt."
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '0' "Cannot send notifications by mail. I'm giving up, bye bye."
	fi
	
	for _project_state_file in ${_project_state_files[@]}
	do
		_file=$(basename "${_project_state_file}")
		_project=$(basename $(dirname "${_project_state_file}"))
		_run="${_file%%.*}"
		
		if [[ -f "${_project_state_file}.mailed" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_project_state_file}.mailed"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping: ${_project}/${_run}. Email was already sent for state ${_state}."
			continue
		fi
		
		_timestamp="$(date --date="$(LC_DATE=C stat --printf='%y' "${_project_state_file}" | cut -d ' ' -f1,2)" "+%Y-%m-%dT%H:%M:%S")"
		_subject="Project ${_project}/${_run} has ${_state} for phase ${_phase} on ${HOSTNAME_SHORT} at ${_timestamp}."
		
		if [[ "${_state}" == 'failed' ]]
		then
			_body=$(cat "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.${_state}")
		else
			_body="The results can be found in: ${PRM_ROOT_DIR}/projects/${_project}/${_run}/."
		fi
		
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Email subject: ${_subject}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Email subject: ${_body}"
		
		if [[ "${email}" == 'true' ]]
		then
			printf '%s\n' "${_body}" \
				| mail -s "${_subject}" "${_email_to}"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating file: ${_project_state_file}.mailed"
			touch "${_project_state_file}.mailed"
		fi
	done
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
declare email='false'
declare dryrun=''
while getopts "g:l:he" opt; do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		e)
			email='true'
			;;
		l)
			l4b_log_level=${OPTARG^^}
			l4b_log_level_prio=${l4b_log_levels[${l4b_log_level}]}
			;;
		\?)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Invalid option -${OPTARG}. Try $(basename $0) -h for help."
			;;
		:)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename $0) -h for help."
			;;
	esac
done


#
# Check commandline options.
#
if [[ -z "${group:-}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -n "${dryrun:-}" ]]; then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Enabled dryrun option for rsync.'
fi


#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
)
for configFile in "${configFiles[@]}"; do
	if [[ -f "${configFile}" && -r "${configFile}" ]]; then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile}..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		mixed_stdouterr=$(source ${configFile} 2>&1) || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot source ${configFile}."
		source ${configFile}  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done

#
# Execution of this script requires ateambot account.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Notify for specific combinations of "script:state".
#
for script_state in 'copyRawDataToPrm:failed' 'pipeline:failed' 'copyProjectDataToPrm:failed' 'copyProjectDataToPrm:finished'
do
	notification "${script_state}"
done


log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0
