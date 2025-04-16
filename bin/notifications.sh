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
ROLE_USER="$(whoami)"
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
	-d   datDir
	-e   Enable email notification. (Disabled by default.)
	-c   Enable notification to MS Teams channel via webhook. (Disabled by default.)
	-s   Run specific phase:state (see cfg files which combinations can be selected)
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
	local    _lfsRootDir="${3}"
	local -a _actions
	#
	# This will only work with Bash 4.4 and up, 
	# which introduced the -d argument to specify a delimitor for readarray.
	#
	#readarray -t -d '|' _actions <<< "${2}"
	readarray -t _actions <<< "${2//|/$'\n'}"
	local -a _projectStateFiles=()
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
	readarray -t _projectStateFiles < <(find "${_lfsRootDir}/logs/" -maxdepth 2 -mindepth 2 -type f \
			-name "*.${_phase}.${_state}*" \
			-not -name '*.mailed' \
			-not -name '*.channelsnotified')
	if [[ "${#_projectStateFiles[@]}" -eq '0' ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No *.${_phase}.${_state} files present in ${_lfsRootDir}/logs/*/."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found project state files: ${_projectStateFiles[*]}."
	fi
	#
	# Create notifications.
	#
	for _projectStateFile in "${_projectStateFiles[@]}"
	do
		#
		# Get project, run and timestamp from state file name/path.
		#
		local _project
		local _projectStateFile_name
		local _run
		local _timestamp
		_project="$(basename "$(dirname "${_projectStateFile}")")"
		_projectStateFile_name="$(basename "${_projectStateFile}")"
		_run="${_projectStateFile_name%%.*}"
		_timestamp="$(date --date="$(LC_DATE=C stat --printf='%y' "${_projectStateFile}" | cut -d ' ' -f1,2)" "+%Y-%m-%dT%H:%M:%S")"
		#
		# Configure logging for this notification script.
		# We use the same logic with exported JOB_CONTROLE_FILE_BASE as for the other scripts from NGS_Automated,
		# but obviously we can only use them for manual inspection if something goes wrong
		# and not for automated notifications as that would result in a "chicken versus the egg; which came first?" problem.
		#
		# Note that currently we cannot no if a new ${_projectStateFile} will appear later on.
		# Hence logs for a project will always be parsed and as the logs dir grows,
		# this may become problematic at some point and require cleanup of the logs.
		#
		# ${_controlFileBase}       is used for tracking the succes of specific notifiction per run per project
		#                           and therefore passed to the notification functions "trackAndTrace", "sendEmail" and postMessageToChannel.
		# ${JOB_CONTROLE_FILE_BASE} is is used for tracking the overall succes of this notifiction script as a whole.
		#
		local _controlFileBase="${_lfsRootDir}/logs/${_project}/${_run}"
		#
		# In case a pipeline failed check if jobs were already resubmitted
		# and only notify if the failure was reproducible and the pipeline failed again.
		#
		if [[ "${_phase}" == 'pipeline' && "${_state}" == 'failed' ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Pipeline has state failed; checking if jobs were already resubmitted ..."
			if [[ ! -e "${_projectStateFile%.pipeline.failed}.startPipeline.resubmitted" ]]
			then
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Jobs for project ${_project} were not resubmitted yet -> skip notification for state failed of phase pipeline."
				continue
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_projectStateFile%.pipeline.failed}.startPipeline.resubmitted"
				if [[ "${_projectStateFile}" -nt "${_projectStateFile%.pipeline.failed}.startPipeline.resubmitted" ]]
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
				#trackAndTrace "${_projectStateFile}" "${_project}" "${_run}" "${_phase}" "${_state}" "${_action}" "${_controlFileBase}"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "no trackandtrace actions will happen"
			elif [[ "${_action}" == *'email'* || "${_action}" == *'channel'* ]]
			then
				#
				# Check if notifications need to be send only after a specific time.
				#
				local _sendMessage
				local _maxTime
				local _maxTimeMin
				local _oldPhaseStateFile
				IFS='/' read -r -a _traceSpecifications <<< "${_action}"
				_maxTime="${_traceSpecifications[1]:-0}"
				if [[ "${_maxTime}" -ne '0' ]]
				then
					_maxTimeMin=$((${_maxTime}*60))
					_oldPhaseStateFile=$(find "${_projectStateFile}" -mmin +"${_maxTimeMin}")
					if [[ -z "${_oldPhaseStateFile:-}" ]]
					then
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "The file ${_projectStateFile} is not yet available or not yet older than ${_maxTime} hours."
						continue
					else
						echo -e "Dear HPC helpdesk,\n\nPlease check if there is something wrong with the ${_phase}.\nThe ${_phase} for project ${_project} is not finished after ${_maxTime} hours.\n\nKind regards,\n\nThe UMCG HPC Helpdesk" > "${_projectStateFile}"
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_projectStateFile} file is older than ${_maxTime} hours for project ${_project}."
					fi
				fi
				#
				# Check if email notifications were explicitly enabled on the commandline.
				#
				if [[ "${_action}" == *'email'* && "${email}" == 'true' ]]
				then
					sendEmail "${_projectStateFile}" "${_timestamp}" "${_project}" "${_run}" "${_phase}" "${_state}" "${_lfsRootDir}" "${_controlFileBase}"
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Email disabled and not creating file: ${_projectStateFile}.mailed"
				fi
				#
				# Check if notifications to channels were explicitly enabled on the commandline.
				#
				if [[ "${_action}" == *'channel'* && "${channel}" == 'true' ]]
				then
					postMessageToChannel "${_projectStateFile}" "${_timestamp}" "${_project}" "${_run}" "${_phase}" "${_state}" "${_lfsRootDir}" "${_controlFileBase}"
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Posting notifications to channels disabled and not creating file: ${_projectStateFile}.channelsnotified"
				fi
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Found unhandled action ${_action} for ${_run}.${_phase}.${_state} of ${_project}."
			fi
		done
		#
		# Signal succes.
		#
		if [[ ! -e "${_controlFileBase}.trackAndTrace.failed" && ! -e "${_controlFileBase}.sendEmail.failed" && ! -e "${_controlFileBase}.postMessageToChannel.failed" ]]
		then 
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${SCRIPT_NAME} succeeded for the last processed phase:state combination (for which notifications were configured) of ${_project}/${_run}."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Beware that notifications for previously processed phase:state combinations may have failed."
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${JOB_CONTROLE_FILE_BASE}.finished."
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to handle notifications for at least one phase:state combination of ${_project}/${_run}."
			notificationStatus="failed"
		fi
	done
}

function trackAndTrace() {
	local    _projectStateFile="${1}"
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
		# shellcheck disable=2310
		if trackAndTracePostFromFile "${_entity}" 'add_update_existing' "${_projectStateFile}"
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
		# shellcheck disable=2310
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
		# shellcheck disable=2310
		if trackAndTracePutFromFile "${_entity}" "${_project}" "${_field}" "${_projectStateFile}"
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
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for ${_project}/${_run}.${_phase}.${_state}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function sendEmail() {
	local	_projectStateFile="${1}"
	local	_timestamp="${2}"
	local	_project="${3}"
	local	_run="${4}"
	local	_phase="${5}"
	local	_state="${6}"
	local	_lfsRootDir="${7}"
	local	_controlFileBase="${8}"
	local	_controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	#
	# Check if email was already send.
	#
	if [[ -e "${_projectStateFile}.mailed" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_projectStateFile}.mailed"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping: ${_project}/${_run}. Email was already sent for state ${_state} of phase ${_phase}."
		return
	fi
	printf '' > "${_controlFileBaseForFunction}.started"
	#
	# Check if we have email addresses for the recipients of the notifications.
	# Must be
	#   * either a "course" grained mailinglist with the same email recipients for all states of the same phase
	#     located at: ${_lfsRootDir}/logs/${_phase}.mailinglist
	#   * or a "fine" grained mailinglist with the email recipients for a specific state of a phase
	#     located at: ${_lfsRootDir}/logs/${_phase}.{_state}.mailinglist
	# The latter will overrule the former when both are found.
	#
	local _email_to
	if [[ -r "${_lfsRootDir}/logs/${_phase}.mailinglist" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_lfsRootDir}/logs/${_phase}.mailinglist."
		_email_to="$(< "${_lfsRootDir}/logs/${_phase}.mailinglist" tr '\n' ' ')"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed ${_phase}.mailinglist and will send mail to: ${_email_to}."
	fi
	if [[ -r "${_lfsRootDir}/logs/${_phase}.{_state}.mailinglist" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_lfsRootDir}/logs/${_phase}.{_state}.mailinglist for more fine grained control over recipients for state {_state}."
		_email_to="$(< "${_lfsRootDir}/logs/${_phase}.{_state}.mailinglist" tr '\n' ' ')"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed ${_phase}.mailinglist and will send mail to: ${_email_to}."
	fi
	if [[ -z "${_email_to:-}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Cannot parse recipients from ${_lfsRootDir}/logs/${_phase}.mailinglist nor from ${_lfsRootDir}/logs/${_phase}.${_phase}.mailinglist."
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
	_body="$(cat "${_projectStateFile}")"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Email subject: ${_subject}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Email body   : ${_body}"
	#
	# Send message.
	#
	printf '%s\n' "${_body}" \
		| mail -s "${_subject}" "${_email_to}"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating file: ${_projectStateFile}.mailed"
	touch "${_projectStateFile}.mailed"
	#
	# Signal succes.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for ${_project}/${_run}.${_phase}.${_state}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function postMessageToChannel() {
	local	_projectStateFile="${1}"
	local	_timestamp="${2}"
	local	_project="${3}"
	local	_run="${4}"
	local	_phase="${5}"
	local	_state="${6}"
	local	_lfsRootDir="${7}"
	local	_controlFileBase="${8}"
	local	_controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	#
	# Check if notification was already send.
	#
	if [[ -e "${_projectStateFile}.channelsnotified" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_projectStateFile}.channelsnotified"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping: ${_project}/${_run}. Message was already posted to channel for state ${_state} of phase ${_phase}."
		return
	fi
	printf '' > "${_controlFileBaseForFunction}.started"
	#
	# Check if we have webhooks for the recipients of the notifications.
	# Must be
	#   * either a "course" grained webhookslist with the same recipients for all states of the same phase
	#     located at: ${_lfsRootDir}/logs/${_phase}.notification_webhooks
	#   * or a "fine" grained webhookslist with the recipients for a specific state of a phase
	#     located at: ${_lfsRootDir}/logs/${_phase}.{_state}.notification_webhooks
	# The latter will overrule the former when both are found.
	#
	declare -a _webhooks
	if [[ -r "${_lfsRootDir}/logs/${_phase}.notification_webhooks" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_lfsRootDir}/logs/${_phase}.notification_webhooks."
		readarray -t _webhooks < "${_lfsRootDir}/logs/${_phase}.notification_webhooks"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed ${_phase}.notification_webhooks."
	fi
	if [[ -r "${_lfsRootDir}/logs/${_phase}.{_state}.notification_webhooks" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_lfsRootDir}/logs/${_phase}.{_state}.notification_webhooks for more fine grained control over recipients for state {_state}."
		readarray -t _webhooks < "${_lfsRootDir}/logs/${_phase}.{_state}.notification_webhooks"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed ${_phase}.{_state}.notification_webhooks."
	fi
	if [[ "${#_webhooks[@]}" -lt '1' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Cannot parse recipients from ${_lfsRootDir}/logs/${_phase}.notification_webhooks nor from ${_lfsRootDir}/logs/${_phase}.{_state}.notification_webhooks."
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Cannot send notifications to channels via webhooks. I'm giving up, bye bye."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Compile message in JSON format.
	# JSON cannot contain any double quotes, so replace all double quotes in the message body with single quotes.
	#
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Compiling JSON message ..."
	local _jsonMessage
	local _messageBody
	local _numberOfLines
	_numberOfLines=$(wc -l "${_projectStateFile}" | awk '{print $1}')
	if [[ "${_numberOfLines}" -gt 10 ]]
	then
		head="$(head -n 6 "${_projectStateFile}" | tr \" \')"
		tail="$(tail -n 4 "${_projectStateFile}" | tr \" \')"
		_messageBody="$(printf '%s\n(.....)\n%s' "${head}" "${tail}")"
	else
		_messageBody="$(tr \" \' < "${_projectStateFile}")"
	fi
	
	_jsonMessage=$(cat <<-EOM
		{
		"title": "${ROLE_USER}@${HOSTNAME_SHORT}: Project ${_project}/${_run} has state ${_state} for phase ${_phase} at ${_timestamp}.",
		"text": "${_messageBody}"
		}
		EOM
	)
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "JSON message: ${_jsonMessage//\"/\\\"}"
	#
	# Post message to channels.
	#
	local _webhook
	for _webhook in "${_webhooks[@]}"
	do
		if [[ -n "${_webhook:-}" ]]
		then
			curl -X POST "${_webhook}" \
				-H 'Content-Type: application/json' \
				-d "${_jsonMessage}"
		fi
	done
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating file: ${_projectStateFile}.channelsnotified"
	touch "${_projectStateFile}.channelsnotified"
	#
	# Signal succes.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for ${_project}/${_run}.${_phase}.${_state}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
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
declare channel='false'
declare selectedPhaseState='all'
while getopts ":g:l:s:p:d:hec" opt; do
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
		c)
			channel='true'
			;;
		d)
			datDir="${OPTARG}"
			;;
		p)
			prmDir="${OPTARG}"
			;;
		s)
			selectedPhaseState="${OPTARG}"
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
fi
if [[ "${channel}" == 'true' ]]; then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Post message to channel option enabled: will try to send notifications to MS Teams channel.'
fi
if [[ "${email}" == 'flase' && "${channel}" == 'false' ]]; then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Both notifications via email and via posting a message to a channel not enabled: will log for debugging on stdout.'
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
# Overrule group's DAT_ROOT_DIR if necessary.
#
if [[ -z "${datDir:-}" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "default (${DAT_ROOT_DIR})"
else
	# shellcheck disable=SC2153
	DAT_ROOT_DIR="/groups/${GROUP}/${datDir}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "DAT_ROOT_DIR is set to ${DAT_ROOT_DIR}"
	if test -e "/groups/${GROUP}/${datDir}/"
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DAT_ROOT_DIR} is available"
		
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "${DAT_ROOT_DIR} does not exist, exit!"
	fi
fi

#
# Overrule group's PRM_ROOT_DIR if necessary.
#
if [[ -z "${prmDir:-}" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "default (${PRM_ROOT_DIR})"
else
	PRM_ROOT_DIR="/groups/${GROUP}/${prmDir}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "DAT_ROOT_DIR is set to ${PRM_ROOT_DIR}"
	if test -e "/groups/${GROUP}/${prmDir}/"
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${PRM_ROOT_DIR} is available"
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "${PRM_ROOT_DIR} does not exist, exit!"
	fi
fi


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

declare -a _lfsRootDirs=("${TMP_ROOT_DIR:-}" "${SCR_ROOT_DIR:-}" "${PRM_ROOT_DIR:-}" "${DAT_ROOT_DIR:-}")
for _lfsRootDir in "${_lfsRootDirs[@]}"
do
	if [[ -z "${_lfsRootDir}" ]] || [[ ! -e "${_lfsRootDir}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "_lfsRootDir ${_lfsRootDir} is not set or does not exist."
		continue
	fi
	export JOB_CONTROLE_FILE_BASE="${_lfsRootDir}/logs/${SCRIPT_NAME}"
	printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
	notificationStatus="sofarsogood"  # Will be changed to failed on error. 
	if [[ -n "${NOTIFICATION_ORDER_PHASE_WITH_STATE[*]:-}" && "${#NOTIFICATION_ORDER_PHASE_WITH_STATE[@]}" -ge 1 ]]
	then
		for ordered_phase_with_state in "${NOTIFICATION_ORDER_PHASE_WITH_STATE[@]}"
		do
			if [[ -n "${ordered_phase_with_state:-}" && -n "${NOTIFY_FOR_PHASE_WITH_STATE[${ordered_phase_with_state}]:-}" ]]
			then
				if [[ "${selectedPhaseState}" == 'all' || "${selectedPhaseState}" == "${ordered_phase_with_state}" ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found notification types ${NOTIFY_FOR_PHASE_WITH_STATE[${ordered_phase_with_state}]} for ${ordered_phase_with_state}."
					notification "${ordered_phase_with_state}" "${NOTIFY_FOR_PHASE_WITH_STATE[${ordered_phase_with_state}]}" "${_lfsRootDir}"
				fi
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '1' "Missing value for 'phase:state' ${ordered_phase_with_state:-} in NOTIFY_FOR_PHASE_WITH_STATE array in ${CFG_DIR}/${group}.cfg"
				log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "No notification types specified for this 'phase:state' combinations: cannot send notifications."
			fi
		done
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '1' "Missing NOTIFICATION_ORDER_PHASE_WITH_STATE array in ${CFG_DIR}/${group}.cfg"
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "No 'phase:state' combinations for which notifications must be sent specified."
	fi
	if [[ "${notificationStatus}" == "failed" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "There is something wrong, please check ${JOB_CONTROLE_FILE_BASE}.failed"
		mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
	elif [[ "${notificationStatus}" == "sofarsogood" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${JOB_CONTROLE_FILE_BASE}.finished."
		mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "This is a unknown status =>  ${notificationStatus}"
	fi
done

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished.'

trap - EXIT
exit 0
