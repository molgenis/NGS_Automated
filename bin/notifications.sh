#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
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
#ROLE_USER="$(whoami)"
#REAL_USER="$(logname 2>/dev/null || echo 'no login name')"

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
Script to check the status of the pipeline and emails notification
Usage:
	$(basename "${0}") OPTIONS
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
function notification() {
	#
	# Declare local vars.
	#
	local    _phase="${1%:*}"
	local    _state="${1#*:}"
	local 	 actionsVar="${2}"
	local -a _actions
	local -a _project_state_files=()
	local    _timestamp
	local    _project
	local    _run
	local    _subject
	local    _body
	local    _email_to
	local    _lfs_root_dir
	#
	# The path to phase state files must be:
	#	"${TMP_ROOT_DIR}/logs/${project}/${run}.${_phase}.${_state}"
	#	"${SCR_ROOT_DIR}/logs/${project}/${run}.${_phase}.${_state}"
	#	"${PRM_ROOT_DIR}/logs/${project}/${run}.${_phase}.${_state}"
	#
	# For 'sequence projects':
	#	${project} = the 'run' as determined by the sequencer.
	#	${run}     = the 'run' as determined by the sequencer.
	# Hence ${project} = {run} = [SequencingStartDate]_[Sequencer]_[RunNumber]_[Flowcell]
	#
	# For 'analysis projects':
	#	${project} = the 'project' name as specified in the sample sheet.
	#	${run}     = the incremental 'analysis run number'. Starts with run01 and incremented in case of re-analysis.
	#
	
	IFS='|' read -r -a _actions <<< "${actionsVar}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing projects with phase ${_phase} in state: ${_state}"
	declare -a _lfs_root_dirs=("${TMP_ROOT_DIR:-}" "${SCR_ROOT_DIR:-}" "${PRM_ROOT_DIR:-}" "${DAT_ROOT_DIR:-}")
	for _lfs_root_dir in "${_lfs_root_dirs[@]}"
	do
		
		if [[ -z "${_lfs_root_dir}" ]] || [[ ! -e "${_lfs_root_dir}" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' '%s\n' "_lfs_root_dir<${_lfs_root_dir}> is not set or does not exist "
			continue
		fi
		readarray -t _project_state_files < <(find "${_lfs_root_dir}/logs/" -maxdepth 2 -mindepth 2 -type f -name "*.${_phase}.${_state}*")
		if [[ "${#_project_state_files[@]:-0}" -eq '0' ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No *.${_phase}.${_state} files present in ${_lfs_root_dir}/logs/*/."
			continue
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found project state files: ${_project_state_files[*]}."
		fi
		#
		# Check if we have email addresses for the recipients of the notifications.
		# Must be
		#   * either a "course" grained mailinglist with the same email recipients for all states of the same phase
		#     located at: ${_lfs_root_dir}/logs/${_phase}.mailinglist
		#   * or a "fine" grained mailinglist with the email recipients for a specific state of a phase
		#     located at: ${_lfs_root_dir}/logs/${_phase}.{_state}.mailinglist
		# The latter will overrule the former when both are found.
		#
		if [[ -r "${_lfs_root_dir}/logs/${_phase}.mailinglist" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_lfs_root_dir}/logs/${_phase}.mailinglist."
			_email_to="$(< "${_lfs_root_dir}/logs/${_phase}.mailinglist" tr '\n' ' ')"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed ${_phase}.mailinglist and will send mail to: ${_email_to}."
		fi
		if [[ -r "${_lfs_root_dir}/logs/${_phase}.{_state}.mailinglist" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_lfs_root_dir}/logs/${_phase}.{_state}.mailinglist for more fine grained control over recipients for state {_state}."
			_email_to="$(< "${_lfs_root_dir}/logs/${_phase}.{_state}.mailinglist" tr '\n' ' ')"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed ${_phase}.mailinglist and will send mail to: ${_email_to}."
		fi
		if [[ -z "${_email_to:-}" ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Cannot parse recipients from ${_lfs_root_dir}/logs/${_phase}.mailinglist nor from ${_lfs_root_dir}/logs/${_phase}.${_phase}.mailinglist."
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Cannot send notifications by mail. I'm giving up, bye bye."
		fi
		#
		# Create notifications.
		#
		
		for _project_state_file in "${_project_state_files[@]}"
		do
			#
			# Get project, run and timestamp from state file name/path.
			#
			local _project
			local _project_state_file_name
			local _run
			local _timestamp
			_project="$(basename "$(dirname "${_project_state_file}")")"
			_project_state_file_name="$(basename "${_project_state_file}")"
			_logfolder_project="$(dirname "${_project_state_file}")"
			_run="${_project_state_file_name%%.*}"
			_timestamp="$(date --date="$(LC_DATE=C stat --printf='%y' "${_project_state_file}" | cut -d ' ' -f1,2)" "+%Y-%m-%dT%H:%M:%S")"
			export JOB_CONTROLE_FILE_BASE="${_lfs_root_dir}/logs/${_project}/${_run}.${_phase}"
			export TRACE_FAILED="${_lfs_root_dir}/logs/${_project}/trace.failed"
			local _tracingUploadFile
			_tracingUploadFile="${_lfs_root_dir}/logs/${_project}/${_phase}.uploadedToMolgenis"
					
			#
			# Check is we should automatically resubmit jobs for a failed analysis pipeline.
			#
			if [[ "${_phase}" == 'pipeline' && "${_state}" == 'failed' ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Pipeline has state failed; checking if we should resubmit jobs ..."
				
				if [[ ! -e "${_project_state_file%failed}resubmitted" ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Project ${_project} was not resubmitted before -> resubmitting jobs ..."
					cd "${_lfs_root_dir}/projects/${_project}/${_run}/jobs/"
					bash "submit.sh" > "${_project_state_file%failed}resubmitted"
					cd -
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Removing ${_project_state_file} and ${_project_state_file}.mailed."
					rm -f "${_project_state_file}" "${_project_state_file}.mailed"
					echo "Jobs have been resubmitted on $(date -r "${_project_state_file%failed}resubmitted")."	> "${_lfs_root_dir}/logs/${_project}/${_phase}_resubmitted.trace_putFromFile_projects.csv"
#					trackAndTracePut 'status_projects' "${_project}" 'message' "Jobs have been resubmitted on $(date -r "${_project_state_file%failed}resubmitted")."
					continue
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_project_state_file%failed}resubmitted"
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Project ${_project} failed again -> will not resubmit jobs."
					echo "Project ${_project} failed again -> will not resubmit jobs."	> "${_lfs_root_dir}/logs/${_project}/${_phase}_resubmitted.trace_putFromFile_projects.csv"
#					trackAndTracePut 'status_projects' "${_project}" 'message' "Pipeline crashed again (even after a resubmit) on ${_timestamp}"
				fi
			fi
				
			for _action in "${_actions[@]}"
			do	
				if [[ "${_action}" == *"trace"* ]]
				then	
					IFS='/' read -r -a traceArray <<< "${_action}"
					
					method="${traceArray[1]}"
					entity="status_${traceArray[2]}"
					field="${traceArray[3]}"
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "PROCESSING: ${_phase}:${_state} <${method}> <${entity}> <${field}>"
					if [ -e "${_tracingUploadFile}" ]
					then
						if grep -q "${_run}.${_phase}_${_state}" "${_tracingUploadFile}"
						then
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_run}.${_phase}.${_state} in ${_tracingUploadFile}"
							log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping: ${_project}/${_run}.${_phase}_${_state}, already uploaded to ${MOLGENISSERVER}."
							continue
						fi
					fi
					if [[ "${method}" == 'post' ]]
					then
						if trackAndTracePostFromFile "${entity}" 'add_update_existing' "${_logfolder_project}/${_run}.${_phase}.trace_${method}_${traceArray[2]}.csv"
						then
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
								"adding ${_run}.${_phase}_${_state} to ${_tracingUploadFile}"
							echo -e "${_run}.${_phase}_${_state}\t$(date +%FT%T%z)" >> "${_tracingUploadFile}"
						else
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed in uploading ${_logfolder_project}/${_run}.${_phase}.trace_${method}_${traceArray[2]}.csv to ${MOLGENISSERVER}"
						fi
					elif [[ "${method}" == 'put' ]]
					then	
						if trackAndTracePut "${entity}" "${_project}" "${field}" "${_state}"
						then
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
								"adding ${_run}.${_phase}_${_state} to ${_tracingUploadFile}"
							echo -e "${_run}.${_phase}_${_state}\t$(date +%FT%T%z)" >> "${_tracingUploadFile}"
						else
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed in updating ${_run}.${_phase}_${_state} to ${MOLGENISSERVER}"
						fi
						
					elif [[ "${method}" == 'putFromFile' ]]
					then
						if trackAndTracePutFromFile "${entity}" "${_project}" "${field}" "${_logfolder_project}/${_run}.${_phase}.trace_${method}_${traceArray[2]}.csv"
						then
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
								"adding ${_run}.${_phase}.${_state} to ${_tracingUploadFile}"
							echo -e "${_run}.${_phase}.${_state}\t$(date +%FT%T%z)" >> "${_tracingUploadFile}"
						else
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed in updating ${_run}.${_phase}.${_state} to ${MOLGENISSERVER}"
						fi
					fi		
					
				elif [ "${_action}" == 'email' ]
				then
					#
					# Check if email was already send.
					#
					if [[ -e "${_project_state_file}.mailed" ]]
					then
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_project_state_file}.mailed"
						log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping: ${_project}/${_run}. Email was already sent for state ${_state} of phase ${_phase}."
						continue
					fi
					
					if [[ "${email}" == 'true' ]]
					then
						#
						# Compile message.
						#
						_subject="Project ${_project}/${_run} has ${_state} for phase ${_phase} on ${HOSTNAME_SHORT} at ${_timestamp}."
						_body="$(cat "${_project_state_file}")"
						log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Email subject: ${_subject}"
						log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Email body   : ${_body}"
						#
						# Send message.
						#
						printf '%s\n' "${_body}" \
							| mail -s "${_subject}" "${_email_to}"
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating file: ${_project_state_file}.mailed"
						touch "${_project_state_file}.mailed"
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Email disabled and not creating file: ${_project_state_file}.mailed"
					fi
				fi
			done
		done
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
declare group=''
declare email='false'
while getopts ":g:l:he" opt; do
	case "${opt}" in
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
if [[ -z "${group:-}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -n "${email:-}" ]]; then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Email option enabled: will try to send emails.'
else
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Email option option not enabled: will log for debugging on stdout.'
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
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config file ${configFile} ..."
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
# Notify for specific colon separated combinations of "phase:state".
#
#if [[ -n "${!NOTIFY_FOR_PHASE_WITH_STATE[0]:-}" && "${#NOTIFY_FOR_PHASE_WITH_STATE[@]:-0}" -ge 1 ]]; then
	
## This array is necessary since a hashmap is unordered
	for ordered_phase_state in "${NOTIFICATION_ORDER_PHASE_WITH_STATE[@]}"
	do
		for phase_with_state in "${!NOTIFY_FOR_PHASE_WITH_STATE[@]}"
		do
			if [[ "${ordered_phase_state}" == "${phase_with_state}" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0'  "NOTIFY: <${NOTIFY_FOR_PHASE_WITH_STATE[${phase_with_state}]}>"
				notification "${phase_with_state}" "${NOTIFY_FOR_PHASE_WITH_STATE[${phase_with_state}]}"
			fi
		done
	done
	#else
#	log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '1' "Missing NOTIFY_FOR_PHASE_WITH_STATE[@] in ${CFG_DIR}/${group}.cfg"
#	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "No 'phase:state' combinations for which notifications must be sent specified."
#fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished.'

trap - EXIT
exit 0
