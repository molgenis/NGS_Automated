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
	local _sampleType="${3}" ## DNA or RNA
	local _generateShScript="${TMP_ROOT_DIR}/generatedscripts/${_project}/generate.sh"
	export JOB_CONTROLE_FILE_BASE="${TMP_ROOT_DIR}/logs/${_project}/${_run}.generateScripts"
	local _message
	echo "generating scripts for ${_project} (incl copyPrmToTmpData)" > "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
	#
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${JOB_CONTROLE_FILE_BASE}.finished exists."
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Will use existing scripts for ${_project}."
		return
	elif [[ -e "${JOB_CONTROLE_FILE_BASE}.started" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${JOB_CONTROLE_FILE_BASE}.started exists."
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Will use existing scripts for ${_project}."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${JOB_CONTROLE_FILE_BASE}.finished nor ${JOB_CONTROLE_FILE_BASE}.started exists."
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Generating scripts for ${_project} ..."
	fi
	#
	# Determine sample type and hence for which pipeline we need to fetch a copy of the generate_template.sh
	#
	if [ "${_sampleType}" == "DNA" ]
	then
		_pathToPipeline="${EBROOTNGS_DNA}"
	elif [ "${_sampleType}" == "RNA" ]
	then
		_pathToPipeline="${EBROOTNGS_RNA}"
	elif [ "${_sampleType}" == "GAP" ]
	then
		_pathToPipeline="${EBROOTGAP}"
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Unknown _sampleType: ${_sampleType}."
	fi
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_pathToPipeline is ${_pathToPipeline}"
	_message="Creating directory: ${TMP_ROOT_DIR}/generatedscripts/${_project}/ ..."

	echo "${_message}" >> "${JOB_CONTROLE_FILE_BASE}.started"
	echo "started: $(date +%FT%T%z)" > "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.totalRuntime"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	mkdir -p "${TMP_ROOT_DIR}/generatedscripts/${_project}/"
	_message="Copying ${_pathToPipeline}/templates/generate_template.sh to ${_generateShScript} ..."
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${JOB_CONTROLE_FILE_BASE}.started"
	cp "${_pathToPipeline}/templates/generate_template.sh" "${_generateShScript}"
	#
	# Check if we need to remove a previously used potentially wrong samplesheet.
	#
	if [[ -e "${TMP_ROOT_DIR}/generatedscripts/${_project}/${_project}.${SAMPLESHEET_EXT}" ]]
	then
		_message="${TMP_ROOT_DIR}/generatedscripts/${_project}/${_project}.${SAMPLESHEET_EXT} already exists and will be removed ..."
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
		echo "${_message}" >> "${JOB_CONTROLE_FILE_BASE}.started"
		rm "${TMP_ROOT_DIR}/generatedscripts/${_project}/${_project}.${SAMPLESHEET_EXT}"
	fi
	#
	# Fetch the (new) samplesheet.
	#
	_message="Copying ${TMP_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT} to ${TMP_ROOT_DIR}/generatedscripts/${_project}/ ..."
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${JOB_CONTROLE_FILE_BASE}.started"
	cp "${TMP_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}" "${TMP_ROOT_DIR}/generatedscripts/${_project}/"
	#
	# Generate scripts.
	#
	cd "${TMP_ROOT_DIR}/generatedscripts/${_project}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to $(pwd)."
	_message="Running: sh ${TMP_ROOT_DIR}/generatedscripts/${_project}/generate.sh -p ${_project} -g ${group} -r ${_run} >> ${JOB_CONTROLE_FILE_BASE}.started"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	sh "${TMP_ROOT_DIR}/generatedscripts/${_project}/generate.sh" -p "${_project}" -g "${group}" -r "${_run}" >> "${JOB_CONTROLE_FILE_BASE}.started" 2>&1

	cd scripts
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to $(pwd)."
	#
	# Execute generated scripts.
	#
	sh submit.sh
	mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
	_message="Scripts generated and created: ${JOB_CONTROLE_FILE_BASE}.finished."
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${JOB_CONTROLE_FILE_BASE}.finished"
}

function submitPipeline () {
	local _project="${1}"
	local _run="${2}"
	local _sampleType="${3}" ## DNA, RNA, GAP
	export JOB_CONTROLE_FILE_BASE="${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline"
	echo "submitting pipeline for ${_project}" > "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Starting submitPipeline part for project: ${_project}/${_run} ..."
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.started" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping  ${_project}/${_run}, because jobs were already submitted."
		return
	elif [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping  ${_project}/${_run}, because jobs have already finished."
		return
	fi
	if [[ ! -e "${TMP_ROOT_DIR}/logs/${_project}" ]]
	then
		mkdir -p "${TMP_ROOT_DIR}/logs/${_project}"
	fi
	cd "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to: ${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/"
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()
	local _filePrefix	
	local _columnName
	local _priority
	local _priorityIndex
	local _sequencingStartDate
	local _sequencingStartDateIndex
	local _sequencer
	local _sequencerIndex
	local _runIdIndex
	local _runId
	local _flowcell
	local _flowcellIndex
	local _capturingKit
	local _capturingKitIndex
	local _prio
	
	declare    sampleTypeFieldIndex
	IFS="${SAMPLESHEET_SEP}" read -r -a sampleSheetColumnNames <<< "$(head -1 "${project}.${SAMPLESHEET_EXT}")"
	for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]:-0} ; offset++ ))
	do
		#
		# Backwards compatibility for "Sample Type" including - the horror - a space and optionally quotes :o.
		#
		regex='Sample Type'
		if [[ "${sampleSheetColumnNames[${offset}]}" =~ ${regex} ]]
		then
			_columnName='sampleType'
		else
			_columnName="${sampleSheetColumnNames[${offset}]}"
		fi
		sampleSheetColumnOffsets["${_columnName}"]="${offset}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_columnName} and sampleSheetColumnOffsets [${_columnName}] offset ${offset} "
	done
	_prio="false"
	if [[ -n "${sampleSheetColumnOffsets['FirstPriority']+isset}" ]]
	then
		_priorityIndex=$((${sampleSheetColumnOffsets['FirstPriority']} + 1))
		_priority=$(tail -n +2 "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/${project}.${SAMPLESHEET_EXT}" | awk -v prio="${_priorityIndex}" 'BEGIN {FS=","}{print "$prio"}')
		if [[ "${_priority^^}" == *"TRUE"* ]]
		then
			echo "should submit this in prio queue"
			_prio="true"
		fi
	fi
	capturingKit="None"
	if [[ "${_sampleType}" == "DNA" || "${_sampleType}" == "RNA" ]]
	then
		
		if [[ -n "${sampleSheetColumnOffsets['sequencingStartDate']+isset}" ]]
		then
			_sequencingStartDateIndex=$((${sampleSheetColumnOffsets['sequencingStartDate']} + 1))
			_sequencingStartDate=$(tail -n +2 "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/${project}.${SAMPLESHEET_EXT}" | awk -v seqstart="${_sequencingStartDateIndex}" 'BEGIN {FS=","}{print $seqstart}' | head -1)
		fi
		if [[ -n "${sampleSheetColumnOffsets['sequencer']+isset}" ]]
		then
			_sequencerIndex=$((${sampleSheetColumnOffsets['sequencer']} + 1))
			_sequencer=$(tail -n +2 "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/${project}.${SAMPLESHEET_EXT}" | awk -v sequencer="${_sequencerIndex}" 'BEGIN {FS=","}{print $sequencer}' | head -1)
		fi
		if [[ -n "${sampleSheetColumnOffsets['run']+isset}" ]]
		then
			_runIdIndex=$((${sampleSheetColumnOffsets['run']} + 1))
			_runId=$(tail -n +2 "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/${project}.${SAMPLESHEET_EXT}" | awk -v runId="${_runIdIndex}" 'BEGIN {FS=","}{print $runId}' | head -1)
		fi
		if [[ -n "${sampleSheetColumnOffsets['flowcell']+isset}" ]]
		then
			_flowcellIndex=$((${sampleSheetColumnOffsets['flowcell']} + 1))
			_flowcell=$(tail -n +2 "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/${project}.${SAMPLESHEET_EXT}" | awk -v flowcell="${_flowcellIndex}" 'BEGIN {FS=","}{print $flowcell}' | head -1)
		fi
		
		if [ "${_sampleType}" == "DNA" ]
		then
			_capturingKitIndex=$((${sampleSheetColumnOffsets['capturingKit']} + 1))
			_capturingKit=$(tail -n +2 "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/${project}.${SAMPLESHEET_EXT}" | awk -v capt="${_capturingKitIndex}" 'BEGIN {FS=","}{print $capt}' | awk 'BEGIN{FS="/"}{print $2}' | head -1)
		fi
		_filePrefix="${_sequencingStartDate}_${_sequencer}_${_runId}_${_flowcell}"
	#
	# Track and Trace: log that we will start running jobs on the cluster.
	#
	elif [ "${_sampleType}" == "GAP" ]
	then
			_filePrefix="${_project}"
			_capturingKit="NA"
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Unknown sampleType: ${sampleType}"
	fi
	local _url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
	printf '%s\n' "project,run_id,pipeline,url,capturingKit,message,copy_results_prm,finishedDate"  > "${JOB_CONTROLE_FILE_BASE}.trace_post_projects.csv"
	printf '%s\n' "${_project},${_filePrefix},${_sampleType},${_url},${_capturingKit},,,"  >> "${JOB_CONTROLE_FILE_BASE}.trace_post_projects.csv"

	_url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_samples&hideselect=true&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
	printf '%s\n' "project_job,job,project,started_date,finished_date,status,url,step"  > "${JOB_CONTROLE_FILE_BASE}.trace_post_jobs.csv.tmp"
	grep '^processJob' submit.sh | tr '"' ' ' | awk -v pro="${_project}" -v url="${_url}" '{OFS=","} {print pro"_"$2,$2,pro,"","","",url}' \
		>> "${JOB_CONTROLE_FILE_BASE}.trace_post_jobs.csv.tmp"
	awk '{FS=","}{if (NR==1){print $0}else{split($2,a,"_"); print $0","a[1]"_"a[2]}}' "${JOB_CONTROLE_FILE_BASE}.trace_post_jobs.csv.tmp"\
		> "${JOB_CONTROLE_FILE_BASE}.trace_post_jobs.csv.tmp2"
	mv "${JOB_CONTROLE_FILE_BASE}.trace_post_jobs.csv.tmp2" "${JOB_CONTROLE_FILE_BASE}.trace_post_jobs.csv"
	rm -f "${JOB_CONTROLE_FILE_BASE}.trace_post_jobs.csv.tmp"

	#
	# Submit jobs to scheduler.
	#
	log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Submitting jobs for ${_project}/${_run} ..."
	if [[ "${group}" == "umcg-atd" || "${group}" == "umcg-gsad" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Using submit option: --qos=leftover."
		sh submit.sh --qos=leftover >> "${JOB_CONTROLE_FILE_BASE}.started" 2>&1 \
			|| {
					mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
					echo "See ${JOB_CONTROLE_FILE_BASE}.failed for details." > "${JOB_CONTROLE_FILE_BASE}.failed"
					return
				}
	elif [ "${_prio}" == "true" ]
	then
		sh submit.sh --qos=priority >> "${JOB_CONTROLE_FILE_BASE}.started" 2>&1 \
			|| {
					mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
					echo "See ${JOB_CONTROLE_FILE_BASE}.failed for details." > "${JOB_CONTROLE_FILE_BASE}.failed"
					return
				}
	else
		sh submit.sh >> "${JOB_CONTROLE_FILE_BASE}.started" 2>&1 \
			|| {
					mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
					echo "See ${JOB_CONTROLE_FILE_BASE}.failed for details." >> "${JOB_CONTROLE_FILE_BASE}.failed"
					return
				}
	fi
	touch "${JOB_CONTROLE_FILE_BASE}.started"
	local _message
	if [ "${_prio}" == "true" ]
	then
		_message="Jobs were submitted to the scheduler on in the prio queue on ${HOSTNAME_SHORT} by ${ROLE_USER} for ${_project}/${_run} on $(date '+%Y-%m-%d-T%H%M')."
	else
		_message="Jobs were submitted to the scheduler on ${HOSTNAME_SHORT} by ${ROLE_USER} for ${_project}/${_run} on $(date '+%Y-%m-%d-T%H%M')."
	fi
	echo "${_message}" >> "${JOB_CONTROLE_FILE_BASE}.started"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
}

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
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
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi

if [[ -z "${pipelineRun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'no runID is given, default is taken (run01).'
	pipelineRun="run01"
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
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

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
sampleSheets=( "$(ssh "${HOSTNAME_PRM}" "find \"${PRM_ROOT_DIR}/Samplesheets/\" -mindepth 1 -maxdepth 1 \( -type l -o -type f \) -name '*.${SAMPLESHEET_EXT}'")" )
if [[ "${#sampleSheets[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No sample sheets found @ ${PRM_ROOT_DIR}/Samplesheets/: There is nothing to do."
	trap - EXIT
	exit 0
else
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Fetching ${#sampleSheets[@]} sample sheets from ${PRM_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT} ..."
	rsync -rltD \
		"${HOSTNAME_PRM}:/${PRM_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT}" \
		"${TMP_ROOT_DIR}/Samplesheets/"
fi

#
# Parse sample sheets.
#
sampleSheets=( "$(ls -1 "${TMP_ROOT_DIR}/Samplesheets/"*".${SAMPLESHEET_EXT}")" )
for sampleSheet in ${sampleSheets[@]}
do
	mac2unix "${sampleSheet}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing sample sheet: ${sampleSheet} ..."
	project=$(basename "${sampleSheet}" ".${SAMPLESHEET_EXT}")
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing: ${project} ..."
	if [[ ! -e "${TMP_ROOT_DIR}/logs/${project}" ]]
	then
		mkdir -m 2770 "${TMP_ROOT_DIR}/logs/${project}"
	fi
	#
	# Sanity checks.
	#
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()
	declare    sampleTypeFieldIndex
	sampleType='DNA'
	IFS="${SAMPLESHEET_SEP}" read -r -a sampleSheetColumnNames <<< "$(head -1 "${sampleSheet}")"
	#
	# Backwards compatibility for "Sample Type" including - the horror - a space and optionally quotes :o.
	#
	for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]:-0} ; offset++ ))
	do
		regex='Sample Type'
		if [[ "${sampleSheetColumnNames[${offset}]}" =~ ${regex} ]]
		then
			columnName='sampleType'
		else
			columnName="${sampleSheetColumnNames[${offset}]}"
		fi
		sampleSheetColumnOffsets["${columnName}"]="${offset}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${columnName} and sampleSheetColumnOffsets[${columnName}] offset ${offset}"
	done
	#
	# Get sampleType from sample sheet and check if all samples are of the same type.
	#
	if [[ -n "${sampleSheetColumnOffsets['sampleType']+isset}" ]]; then
		sampleTypeFieldIndex=$((${sampleSheetColumnOffsets['sampleType']} + 1))
		sampleTypesCount=$(tail -n +2 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}" | sort | uniq | wc -l)
		if [[ "${sampleTypesCount}" -eq '1' ]]
		then
			sampleType=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}")
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found sampleType: ${sampleType}."
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${sampleSheet} contains multiple different sampleType values."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${project} due to error in sample sheet."
			continue
		fi
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType column missing in sample sheet; will use default value: ${sampleType}."
	fi
	#
	# Generate scripts (per sample sheet).
	#
	generateScripts "${project}" "${pipelineRun}" "${sampleType}"
	#
	# Submit generated job scripts (per project).
	#
	if [[ -e "${TMP_ROOT_DIR}/logs/${project}/${pipelineRun}.generateScripts.finished" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project} with runnumber ${pipelineRun} and sampleType ${sampleType}"
		submitPipeline "${project}" "${pipelineRun}" "${sampleType}"
	fi
done
echo "done" > "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
trap - EXIT
exit 0
