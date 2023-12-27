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
===============================================================================================================
Script to calculate the checksums of the project 
Usage:
	$(basename "${0}") OPTIONS
Options:
	-h	Show this help.
	-g	Group.
	-p pipeline (which pipeline to run NGS_DNA / GAP)
	-l	Log level.
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
# Compute checksums recursively for a given project folder.
#
function calculateMd5() {
	local _project
	local _run
	local _controlFileBase
	_project="${1}"
	_run="${2}"
	_controlFileBase="${TMP_ROOT_DIR}/logs/${_project}/${_run}"
	#
	export JOB_CONTROLE_FILE_BASE="${_controlFileBase}.${SCRIPT_NAME}"
	#
	# Check if we should create checksums for this run of this project .
	#
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Found ${JOB_CONTROLE_FILE_BASE}.finished: skipping ${_project}/${_run}/ ... "
		return
	fi
	if [[ ! -e "${_controlFileBase}.pipeline.finished" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Cannot find ${_controlFileBase}.pipeline.finished: skipping ${_project}/${_run}/ ... "
		return
	fi

	#
	# zip all files in jobs folder to ${_project}_jobs.tar.gz"
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"zip all files in jobs folder to ${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/${_run}/jobs/${_project}_jobs.tar.gz and removing originals"
	tar -czvf "${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/${_run}/results/${_project}_jobs.tar.gz" -C "${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/${_run}/jobs/" .
	rm -f "${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/${_run}/jobs/"*
	mv "${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/${_run}/results/${_project}_jobs.tar.gz" "${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/${_run}/jobs/"
	#
	# All checks passed: start computing checksums.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' \
		"Creating checksums for ${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/${_run}/ ... " \
		2>&1 | tee "${JOB_CONTROLE_FILE_BASE}.started"
	cd "${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/" \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" "${?}" \
				"Cannot access ${TMP_ROOT_DIR}/projects/${pipeline}/${_project}/." \
				2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
			mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			return
		}

	md5deep -r -j0 -o f -l "${_run}/" > "${_run}.md5" 2>> "${JOB_CONTROLE_FILE_BASE}.started" \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" "${?}" \
				"Checksum verification failed. See ${JOB_CONTROLE_FILE_BASE}.failed for details." \
				2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
			mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			return
		}
	mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
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
while getopts ":g:l:p:h" opt
do
	case ${opt} in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		p)
			pipeline="${OPTARG}"
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

if [[ -z "${pipeline:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a pipeline with -p.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
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
# Execution of this script requires ateambot account.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

module load "hashdeep/${HASHDEEP_VERSION}" || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" 'Failed to load hashdeep module.'
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "$(module list)"

readarray -t projects < <(find "${TMP_ROOT_DIR}/projects/${pipeline}/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_ROOT_DIR}/projects/${pipeline}/||")
if [[ "${#projects[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_ROOT_DIR}/projects/${pipeline}/."
else
	for project in "${projects[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project} ..."
		echo "Working on ${project}" > "${lockFile}"
		readarray -t runs < <(find "${TMP_ROOT_DIR}/projects/${pipeline}/${project}/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_ROOT_DIR}/projects/${pipeline}/${project}/||")
		if [[ "${#runs[@]}" -eq '0' ]]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found for project ${project}."
		else
			for run in "${runs[@]}"
			do
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project}/${run} ..."
				calculateMd5 "${project}" "${run}"
			done
		fi
	done
fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'
echo "" > "${lockFile}"
trap - EXIT
exit 0
