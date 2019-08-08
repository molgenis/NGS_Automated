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
SCRIPT_NAME="$(basename ${0})"
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
Script to calculate the checksums of the project 
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
function calculateMd5(){
	local _project="${1}"
	local _run="${2}"

	local _controlFileBase="${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}"
	local _logFile="${_controlFileBase}.log"

	if [ ! -f "${_controlFileBase}.finished" ]
	then
		local _checksumVerification='unknown'
		echo "checksum started" > "${_controlFileBase}.started"
		cd "${TMP_ROOT_DIR}/projects/${_project}/" \
			|| log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot access ${TMP_ROOT_DIR}/projects/${_project}/."
		md5deep -r -j0 -o f -l "${_run}/" > "${_run}.md5" 2>> "${_logFile}" \
			|| {
                                echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details." \
                                >> "${_controlFileBase}.failed"
				log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot compute checksums with md5deep. See ${_logFile} for details."

			}
		mv "${_controlFileBase}."{started,finished}
	fi
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

module load hashdeep/${HASHDEEP_VERSION} || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} 'Failed to load hashdeep module.'
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "$(module list)"

declare -a projects=($(find "${TMP_ROOT_DIR}/projects/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_ROOT_DIR}/projects/||"))
if [[ "${#projects[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_ROOT_DIR}/projects."
else
	for project in "${projects[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project}..."
		declare -a runs=($(find "${TMP_ROOT_DIR}/projects/${project}/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_ROOT_DIR}/projects/${project}/||"))
		if [[ "${#runs[@]:-0}" -eq '0' ]]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found for project ${project}."
		else
			for run in "${runs[@]}"
			do
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project}/${run}..."
				calculateMd5 "${project}" "${run}"
			done
		fi
	done
fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0
