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
	local    _lfs_root_dir="${3}"
	local -a _actions
	#
	# This will only work with Bash 4.4 and up, 
	# which introduced the -d argument to specify a delimitor for readarray.
	#
	#readarray -t -d '|' _actions <<< "${2}"
	readarray -t _actions <<< "${2//|/$'\n'}"
	local -a _project_state_files=()

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
	
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing projects with phase ${_phase} in state: ${_state}."

	readarray -t _project_state_files < <(find "${_lfs_root_dir}/logs/" -maxdepth 2 -mindepth 2 -type f -name "*.${_phase}.${_state}*" -not -name "*.mailed")
	if [[ "${#_project_state_files[@]:-0}" -eq '0' ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No *.${_phase}.${_state} files present in ${_lfs_root_dir}/logs/*/."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found project state files: ${_project_state_files[*]}."
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
		_run="${_project_state_file_name%%.*}"
		_timestamp="$(date --date="$(LC_DATE=C stat --printf='%y' "${_project_state_file}" | cut -d ' ' -f1,2)" "+%Y-%m-%dT%H:%M:%S")"
		#
		# Configure logging for this notification script.
		# We use the same logic with exported JOB_CONTROLE_FILE_BASE as for the other scripts from NGS_Automated,
		# but obviously we can only use them for manual inspection if something goes wrong
		# and not for automated notifications as that would result in a "chicken versus the egg; which came first?" problem.
		#
		# Note that currently we cannot no if a new ${_project_state_file} will appear later on.
		# Hence logs for a project will always be parsed and as the logs dir grows,
		# this may become problematic at some point and require cleanup of the logs.
		#
		# ${_controlFileBase}       is used for tracking the succes of specific notifiction per run per project
		#                           and therefore passed to the notification functions "trackAndTrace" and "sendEmail"
		# ${JOB_CONTROLE_FILE_BASE} is is used for tracking the overall succes of this notifiction script as a whole.
		#
		local _controlFileBase="${_lfs_root_dir}/logs/${_project}/${_run}"

		#
		# In case a pipeline failed check if jobs were already resubmitted
		# and only notify if the failure was reproducible and the pipeline failed again.
		#
		if [[ "${_phase}" == 'pipeline' && "${_state}" == 'failed' ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Pipeline has state failed; checking if jobs were already resubmitted ..."
			if [[ ! -e "${_project_state_file%.pipeline.failed}.startPipeline.resubmitted" ]]
			then
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Jobs for project ${_project} were not resubmitted yet -> skip notification for state failed of phase pipeline."
				continue
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_project_state_file%.pipeline.failed}.startPipeline.resubmitted"
				if [[ "${_project_state_file}" -nt "${_project_state_file%.pipeline.failed}.startPipeline.resubmitted" ]]
				then
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Pipeline for project ${_project} failed again -> notify for state failed of phase pipeline."
				else
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Jobs for project ${_project} were resubmitted and pipeline did not fail again yet -> skip notification for state failed of phase pipeline."
					continue
				fi
			fi
		fi
		#
		# Perform notification action for this state of this phase in the workflow.
		#
		local _action
		for _action in "${_actions[@]}"
		do
			if [[ "${_action}" == *"trace"* ]]
			then
				#
				# Notify Track and Trace MOLGENIS Database.
				#
				trackAndTrace "${_project_state_file}" "${_project}" "${_run}" "${_phase}" "${_state}" "${_action}" "${_controlFileBase}"
			elif [[ "${_action}" == 'email' ]]
			then
				#
				# Check if email notifications were explicitly enabled on the commandline.
				#
				if [[ "${email}" != 'true' ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Email disabled and not creating file: ${_project_state_file}.mailed"
					continue
				else
					sendEmail "${_project_state_file}" "${_project}" "${_run}" "${_phase}" "${_state}" "${_lfs_root_dir}" "${_controlFileBase}"
				fi
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Found unhandled action ${_action} for ${_run}.${_phase}.${_state} of ${_project}."
			fi
		done
		#
		# Signal succes.
		#
		if [[ ! -e "${_controlFileBase}.trackAndTrace.failed" && ! -e "${_controlFileBase}.sendEmail.failed" ]]
		then 
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${SCRIPT_NAME} succeeded for the last processed phase:state combination (for which notifications were configured) of ${_project}/${_run}." \
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "               Beware that notifications for previously processed phase:state combinations may have failed."

			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${JOB_CONTROLE_FILE_BASE}.finished."
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to handle notifications for at least one phase:state combination of ${_project}/${_run}."
			status_notifications="failed"
		fi
	done
}

function trackAndTrace() {
	local    _project_state_file="${1}"
	local    _project="${2}"
	local    _run="${3}"
	local    _phase="${4}"
	local    _state="${5}"
	local    _action="${6}"
	local    _controlFileBase="${7}"
	local    _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	local    _traceSucceededLog
	local -a _traceSpecifications
	local    _method
	local    _entity
	local    _field
	_traceSucceededLog="${_controlFileBaseForFunction}.succeeded"
	IFS='/' read -r -a _traceSpecifications <<< "${_action}"
	_method="${_traceSpecifications[1]}"
	# ToDo: remove hard-coded 'status_' from ${_entity}.
	_entity="status_${_traceSpecifications[2]}"
	_field="${_traceSpecifications[3]}"
	if [[ -e "${_traceSucceededLog}" ]]
	then
		if grep -q "${_run}.${_phase}.${_state}" "${_traceSucceededLog}"
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_run}.${_phase}.${_state} in ${_traceSucceededLog}"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping: ${_project}/${_run}.${_phase}_${_state}, because it was already uploaded to ${MOLGENISSERVER}."
			return
		fi
	fi
	printf '' > "${_controlFileBaseForFunction}.started"
	if [[ "${_method}" == 'post' ]]
	then
		if trackAndTracePostFromFile "${_entity}" 'add_update_existing' "${_project_state_file}"
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Adding ${_run}.${_phase}.${_state} to ${_traceSucceededLog} ..."
			echo -e "${_run}.${_phase}.${_state}\t$(date +%FT%T%z)" >> "${_traceSucceededLog}"
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to record ${_run}.${_phase}.${_state} for ${_project} at ${MOLGENISSERVER} using method ${_method}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
	elif [[ "${_method}" == 'put' ]]
	then	
		if trackAndTracePut "${_entity}" "${_project}" "${_field}" "${_state}"
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Adding ${_run}.${_phase}.${_state} to ${_traceSucceededLog} ..."
			echo -e "${_run}.${_phase}.${_state}\t$(date +%FT%T%z)" >> "${_traceSucceededLog}"
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to record ${_run}.${_phase}.${_state} for ${_project} at ${MOLGENISSERVER} using method ${_method}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
		
	elif [[ "${_method}" == 'putFromFile' ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "RUN=${_run}"
		if trackAndTracePutFromFile "${_entity}" "${_project}" "${_field}" "${_project_state_file}"
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Adding ${_run}.${_phase}.${_state} to ${_traceSucceededLog}"
			echo -e "${_run}.${_phase}.${_state}\t$(date +%FT%T%z)" >> "${_traceSucceededLog}"
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to record ${_run}.${_phase}.${_state} for ${_project} at ${MOLGENISSERVER} using method ${_method}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Found unhandled method ${_method} for ${_run}.${_phase}.${_state} of project ${_project}."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Signal succes.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for ${_project}/${_run}.${_phase}.${_state}. See ${_controlFileBaseForFunction}.finished for details." \
		&& rm -f "${_controlFileBaseForFunction}.failed" \
		&& mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function sendEmail() {
	local    _project_state_file="${1}"
	local    _project="${2}"
	local    _run="${3}"
	local    _phase="${4}"
	local    _state="${5}"
	local    _lfs_root_dir="${6}"
	local    _controlFileBase="${7}"
	local    _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	#
	# Check if email was already send.
	#
	if [[ -e "${_project_state_file}.mailed" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_project_state_file}.mailed"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping: ${_project}/${_run}. Email was already sent for state ${_state} of phase ${_phase}."
		return
	fi
	printf '' > "${_controlFileBaseForFunction}.started"
	#
	# Check if we have email addresses for the recipients of the notifications.
	# Must be
	#   * either a "course" grained mailinglist with the same email recipients for all states of the same phase
	#     located at: ${_lfs_root_dir}/logs/${_phase}.mailinglist
	#   * or a "fine" grained mailinglist with the email recipients for a specific state of a phase
	#     located at: ${_lfs_root_dir}/logs/${_phase}.{_state}.mailinglist
	# The latter will overrule the former when both are found.
	#
	local _email_to
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
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Cannot send notifications by mail. I'm giving up, bye bye."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Compile message.
	#
	local _subject
	local _body
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
	#
	# Signal succes.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for ${_project}/${_run}.${_phase}.${_state}. See ${_controlFileBaseForFunction}.finished for details." \
		&& rm -f "${_controlFileBaseForFunction}.failed" \
		&& mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
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
if [[ "${email}" == 'true' ]]; then
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
# ${NOTIFY_FOR_PHASE_WITH_STATE[@]} is a hash
#  Key   = phase:state
#  Value = type of notification for that combination of state and phase in the workflow.
# 
# ${NOTIFICATION_ORDER_PHASE_WITH_STATE[@]} is an array and contains the keys of the ${NOTIFY_FOR_PHASE_WITH_STATE[@]} hash
# in a specific order to ensure notification order is in sync with workflow order.
#

declare -a _lfs_root_dirs=("${TMP_ROOT_DIR:-}" "${SCR_ROOT_DIR:-}" "${PRM_ROOT_DIR:-}" "${DAT_ROOT_DIR:-}")
for _lfs_root_dir in "${_lfs_root_dirs[@]}"
do
	
	if [[ -z "${_lfs_root_dir}" ]] || [[ ! -e "${_lfs_root_dir}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "_lfs_root_dir ${_lfs_root_dir} is not set or does not exist."
		continue
	fi
	
	export JOB_CONTROLE_FILE_BASE="${_lfs_root_dir}/logs/${SCRIPT_NAME}"
	printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
	status_notifications="unknown"
	
	if [[ -n "${NOTIFICATION_ORDER_PHASE_WITH_STATE[*]:-}" && "${#NOTIFICATION_ORDER_PHASE_WITH_STATE[@]:-0}" -ge 1 ]]
	then
		for ordered_phase_with_state in "${NOTIFICATION_ORDER_PHASE_WITH_STATE[@]}"
		do
			if [[ -n "${ordered_phase_with_state:-}" && -n "${NOTIFY_FOR_PHASE_WITH_STATE[${ordered_phase_with_state}]:-}" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found notification types ${NOTIFY_FOR_PHASE_WITH_STATE[${ordered_phase_with_state}]} for ${ordered_phase_with_state}."
				notification "${ordered_phase_with_state}" "${NOTIFY_FOR_PHASE_WITH_STATE[${ordered_phase_with_state}]}" "${_lfs_root_dir}"
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '1' "Missing value for 'phase:state' ${ordered_phase_with_state:-} in NOTIFY_FOR_PHASE_WITH_STATE array in ${CFG_DIR}/${group}.cfg"
				log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "No notification types specified for this 'phase:state' combinations: cannot send notifications."
			fi
		done
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '1' "Missing NOTIFICATION_ORDER_PHASE_WITH_STATE array in ${CFG_DIR}/${group}.cfg"
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "No 'phase:state' combinations for which notifications must be sent specified."
	fi
	
	if [[ "${status_notifications}" == "failed" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "There is something wrong, please check ${JOB_CONTROLE_FILE_BASE}.failed"
		mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
	elif [[ "${status_notifications}" == "unknown" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${JOB_CONTROLE_FILE_BASE}.finished."
		mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "This is a unknown status =>  ${status_notifications}"
	fi
	
	
done

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished.'

trap - EXIT
exit 0
