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
	exit 1
fi

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to stage data from prm to tmp and then start automagically the pipeline

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-r	Run number / runID (default is run01)
	-g	Group.
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

function generateScripts () {
	local _project="${1}"
	local _run="${2}"
	local _generateShScript="${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/generate_dragenScripts.sh"
	local _controlFileBase="${3}"
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_project}/${_run}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
		printf 'Generating scripts for project %s.\n' "${_project}" >> "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
		printf 'started: %s\n.' "$(date +%FT%T%z)" > "${_controlFileBase}.pipeline.totalRuntime"
	fi
	_pathToPipeline="${EBROOTNGS_DNA}"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "_pathToPipeline is ${EBROOTNGS_DNA}"
	#
	# Create dir and fetch template to generate scripts.
	#
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Creating directory: ${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/ ..."
	mkdir -p -v "${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/" \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create directory for generated scripts. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Copying ${_pathToPipeline}/templates/generate_dragenScripts.sh to ${_generateShScript} ..."
	cp -v "${_pathToPipeline}/templates/generate_dragenScripts.sh" "${_generateShScript}" \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to copy generate_template.sh. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	#
	# Check if we need to remove a previously used potentially wrong samplesheet.
	#
	if [[ -e "${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/${_project}.${SAMPLESHEET_EXT}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/generatedscripts/${_project}/${_project}.${SAMPLESHEET_EXT} already exists and will be removed ..."
		rm -f "${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/${_project}.${SAMPLESHEET_EXT}"
	fi
	#
	# Fetch the (new) samplesheet.
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Copying ${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/${_project}.${SAMPLESHEET_EXT} to ${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/ ..."
	cp -v "${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/${_project}.${SAMPLESHEET_EXT}" "${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/" \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to fetch samplesheet. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}

	cd "${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Navigated to $(pwd)."
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Executing: bash ${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/generate_dragenScripts.sh -p ${_project} -g ${group} -r ${_run}"
	bash "${TMP_ROOT_DIR}/generatedscripts/NGS_DNA/${_project}/generate_dragenScripts.sh" -p "${_project}" -g "${group}" -r "${_run}" \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to generate scripts. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	
	#
	# Signal succes.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for ${_project}/${_run}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}
function submitJobScripts () {
	local _project="${1}"
	local _run="${2}"
	local _priority="${3}"
	local _controlFileBase="${4}"
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	local _resubmitJobScripts="${5}"
	
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" && "${_resubmitJobScripts}" == 'false' ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present and _resubmitJobScripts is false -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_project}/${_run}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present or _resubmitJobScripts is true -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
		rm -f "${_controlFileBaseForFunction}.finished"
		printf 'Submitting job scripts to scheduler for project %s.\n' "${_project}" >> "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
	fi
	#
	# Go to scripts dir.
	#
	cd "${TMP_ROOT_DIR}/projects/NGS_DNA/${_project}/${_run}/jobs/"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Navigated to: $(pwd)."
	#
	# Determine submit options.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Submitting jobs for ${_project}/${_run} ..."
	local _submitOptions
	local _tmpDirectory
	_tmpDirectory="$(basename "${TMP_ROOT_DIR}")"
	if [[ "${group}" == 'umcg-atd' || "${group}" == 'umcg-gsad' ]]
	then
		_submitOptions="--qos=leftover"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Detected development group ${group}: using low priority QoS."
	elif [[ "${_priority}" == 'true' ]]
	then
		_submitOptions="--qos=priority"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Detected _priority ${_priority}: using high priority QoS."
	fi
	if [[ -n "${_submitOptions:-}" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Using commandline submit options: ${_submitOptions}"
	fi
	#
	# Submit jobs to scheduler.
	#
	# As soon as the first job was submitted it may start to run when enough resources are available,
	# so we must create pipeline.started just before submitting the first job.
	#
	printf '' > "${_controlFileBase}.pipeline.started"
	# shellcheck disable=SC2248
	bash submit.sh  "--constraint ${_tmpDirectory}" "${_submitOptions:-}" >> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to submit jobs for ${_project}/${_run} ."
			mv -v "${_controlFileBaseForFunction}."{started,failed}
			return
		}
	if [[ "${_resubmitJobScripts}" == 'false' ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' \
			"Jobs were submitted to the scheduler on ${HOSTNAME_SHORT} by ${ROLE_USER} for ${_project}/${_run} on $(date '+%Y-%m-%d-T%H%M')."
	elif [[ "${_resubmitJobScripts}" == 'true' ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' \
		"Jobs were resubmitted to the scheduler on ${HOSTNAME_SHORT} by ${ROLE_USER} for previously failed ${_project}/${_run} on $(date '+%Y-%m-%d-T%H%M')."
	else
		mv -v "${_controlFileBaseForFunction}."{started,failed}
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Unsupported value for _resubmitJobScripts: ${_resubmitJobScripts}."
	fi
	#
	# Signal succes.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for ${_project}/${_run}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Parsing commandline arguments ..."
declare group=''
while getopts ":g:l:r:h" opt; do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		r)
			pipelineRun="${OPTARG}"
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
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' 'Must specify a group with -g.'
fi

if [[ -z "${pipelineRun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' 'no runID is given, default is taken (run01).'
	pipelineRun="run01"
fi
#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config files ..."
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
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data trnasfers.
#
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

printf 'Started at %s.\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"

#
# Fetch (new) sample sheets from prm.
#
# ToDo: skip fetching sample sheets from prm once we have a 
#       proper prm mount on the GD clusters and the previous script
#       that created the sample sheet per project can run a GD cluster
#       instead of on a research cluster to create them directly on tmp.
#
declare -a sampleSheets
# shellcheck disable=SC2029
readarray -t sampleSheets < <(find "${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/" -mindepth 1 -maxdepth 1 -name "*.${SAMPLESHEET_EXT}" )
if [[ "${#sampleSheets[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No sample sheets found @ ${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/: There is nothing to do."
	trap - EXIT
	exit 0
else
	for sampleSheet in "${sampleSheets[@]}"
	do
		if [[ "${sampleSheet}" == *"WGS"* ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "This samplesheet is a (s)WGS samplesheet, there is another script that executes this type of data..."
			continue
		fi
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing sample sheet: ${sampleSheet} ..."
		project="$(basename "${sampleSheet}" ".${SAMPLESHEET_EXT}")"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing: ${project} ..."
		#
		# Configure logging for this project.
		#
		controlFileBase="${TMP_ROOT_DIR}/logs/${project}/${pipelineRun}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		#
		# Check if we should (re)start the pipeline.
		#
		resubmitJobScripts='false'
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			if [[ -e "${JOB_CONTROLE_FILE_BASE}.resubmitted" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already restarted ${project}/${pipelineRun}."
				continue
			elif [[ -e "${controlFileBase}.pipeline.failed" ]]
			then
				#
				# Restart pipeline once.
				# If it fails again we check for presence of ${JOB_CONTROLE_FILE_BASE}.resubmitted
				# and won't restart automatically again: manual intervention required.
				#
				resubmitJobScripts='true'
			else
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already started ${project}/${pipelineRun}."
				continue
			fi
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${project}/${pipelineRun} ..."
		fi
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${project}/"
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
		#
		# Sanity checks.
		#
		declare -a sampleSheetColumnNames=()
		declare -A sampleSheetColumnOffsets=()
		declare    sampleSheetFieldIndex
		declare    sampleSheetFieldValueCount
		IFS="${SAMPLESHEET_SEP}" read -r -a sampleSheetColumnNames <<< "$(head -1 "${sampleSheet}")"
		#
		# Backwards compatibility for "Sample Type" including - the horror - a space and optionally quotes :o.
		#
		for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]} ; offset++ ))
		do
			regex='Sample Type'
			if [[ "${sampleSheetColumnNames[${offset}]}" =~ ${regex} ]]
			then
				columnName='sampleType'
			else
				columnName="${sampleSheetColumnNames[${offset}]}"
			fi
			sampleSheetColumnOffsets["${columnName}"]="${offset}"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${columnName} and sampleSheetColumnOffsets[${columnName}] offset ${offset}"
		done
		#
		# Get sampleType from sample sheet and check if all samples are of the same type.
		#
		sampleType='DNA' # Default.
		if [[ -n "${sampleSheetColumnOffsets['sampleType']+isset}" ]]; then
			sampleSheetFieldIndex=$((${sampleSheetColumnOffsets['sampleType']} + 1))
			sampleSheetFieldValueCount=$(tail -n +2 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleSheetFieldIndex}" | sort | uniq | wc -l)
			if [[ "${sampleSheetFieldValueCount}" -eq '1' ]]
			then
				sampleType=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleSheetFieldIndex}")
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found sampleType: ${sampleType}."
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${sampleSheet} contains multiple different sampleType values."
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping ${project} due to error in sample sheet."
				continue
			fi
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "sampleType column missing in sample sheet; will use default value: ${sampleType}."
		fi
		#
		# Get priority from sample sheet (optional column + value).
		#
		priority='false' # default
		if [[ -n "${sampleSheetColumnOffsets['FirstPriority']+isset}" ]]
		then
			sampleSheetFieldIndex=$((${sampleSheetColumnOffsets['FirstPriority']} + 1))
			firstPriority=$(tail -n +2 "${sampleSheet}" | awk -v sampleSheetFieldIndex="${sampleSheetFieldIndex}" 'BEGIN {FS=","}{print $sampleSheetFieldIndex}')
			if [[ "${firstPriority^^}" == *"TRUE"* ]]
			then
				priority='true'
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "High priority requested for at least one sample in samplesheet for project ${project}."
			fi
		fi
		#
		# Get additional meta-data from samplesheet.
		# (Not required for generating and submitting job scripts; only used for track and trace.)
		#

		sampleSheetFieldIndex=$((${sampleSheetColumnOffsets['capturingKit']} + 1))
		capturingKit=$(tail -n 1 "${sampleSheet}" | awk -v sampleSheetFieldIndex="${sampleSheetFieldIndex}" 'BEGIN {FS=","}{print $sampleSheetFieldIndex}')
			
		#
		# Step 1: Generate scripts (per sample sheet).
		#
		generateScripts "${project}" "${pipelineRun}" "${controlFileBase}"
		#
		# Step 2: Submit generated job scripts (per project).
		#
		if [[ -e "${controlFileBase}.generateScripts.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.generateScripts.finished present -> generateScripts completed; let's submitScripts for ${project}/${pipelineRun} ..."
			submitJobScripts "${project}" "${pipelineRun}" "${priority}" "${controlFileBase}" "${resubmitJobScripts}"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.generateScripts.finished absent -> generateScripts failed."
		fi
		#
		# Signal success or failure for complete process.
		#
		if [[ -e "${controlFileBase}.submitJobScripts.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.submitJobScripts.finished present -> processing completed for ${project}/${pipelineRun} ..."
			rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing ${project}/${pipelineRun}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
			if [[ "${resubmitJobScripts}" == 'true' ]]
			then
				printf '' > "${JOB_CONTROLE_FILE_BASE}.resubmitted"
			fi
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.submitJobScripts.finished absent -> processing failed for ${project}/${pipelineRun}."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process ${project}/${pipelineRun}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		fi
	done
fi

printf 'Done at %s.\n' "$(date '+%Y-%m-%dT%H:%M:%S')" >> "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
trap - EXIT
exit 0
