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
	-n   Dry-run: Do not perform actual sync, but only list changes instead.
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

	local _status="${1}"

	if [[ "${NGS_DNA_VERSION}" ]]
	then
		local pipeline="NGS_DNA"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Pipeline is ${pipeline}"

	elif [[ "${NGS_RNA_VERSION}" ]]
	then
		pipeline="NGS_RNA"
                log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Pipeline is ${pipeline}"
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "No pipeline found!"
	fi

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Notification status is: ${_status}"


	if $(ls "${TMP_ROOT_DIR}/logs/"*"/"*".pipeline.${_status}" 1> /dev/null 2>&1)
	then
		$(ls "${TMP_ROOT_DIR}/logs/"*"/"*".pipeline.${_status}" > "${TMP_ROOT_DIR}/logs/pipeline.${_status}.csv")
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No *.pipeline.${_status} present."
	fi

	while read line
	do
		local _file=$(basename "${line}")
		local _project=$(basename $(dirname "${line}"))
		local _run="${_file%%.*}"

		if [ ! -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.${_status}.mailed" ]
		then
			local _header=$(head -1 "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.${_status}")
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Email notification ${_status} to ${EMAIL_TO}"

			if [ "${_status}" == "failed" ]
			then
				local _subject="The ${pipeline} pipeline on ${HOSTNAME_SHORT} has ${_status} for project ${_project} on step ${_header}"
				local _body=$(cat "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.${_status}")
			else
				_subject="${pipeline} pipeline is finished for project ${_project} on `date +%d/%m/%Y` `date +%H:%M`"
				_body="The results can be found in: ${PRM_ROOT_DIR}/projects/${_run}/ \n\nCheers from the GCC :)"
			fi

			if [[ "${email}" == 'true' ]]
			then
				echo -e "${_body}" | mail -s "${_subject}" "${EMAIL_TO}"
                                log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating file: ${_run}.pipeline.${_status}.mailed"
                                mv "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.${_status}"{,.mailed}
			fi
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Nothing to email..."
		fi

	done<"${TMP_ROOT_DIR}/logs/pipeline.${_status}.csv"
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
while getopts "g:l:hen" opt; do
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
		n)
			dryrun='-n'
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


for i in "failed" "finished"
do
	notification "${i}"
done


log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0
