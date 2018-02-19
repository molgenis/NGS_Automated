#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]
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
if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
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

    $(basename $0) OPTIONS

Options:

    -h   Show this help.
    -g   Group.
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

function generateScripts () {
	local _project="${1}"
	local _run="${2}"
	local _sampleType="${3}" ## DNA or RNA
	local _loadPipeline="NGS_${_sampleType}"
	local _generateShScript="${TMP_ROOT_DIR}/generatedscripts/${_project}/generate.sh"
	local _controlFileBase="${TMP_ROOT_DIR}/logs/${_project}/${_run}.generateScripts"
	local _logFile="${_controlFileBase}.log"
	local _message
	
	if [[ -e "${_controlFileBase}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.finished exists."
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Will use existing scripts for ${_project}."
		return
	elif [[ -e "${_controlFileBase}.started" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.started exists."
                log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Will use existing scripts for ${_project}."
                return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.finished does not exist."
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Generating scripts for ${_project} ..."
	fi
	
	if [ "${_sampleType}" == "DNA" ]
	then
		_version="${NGS_DNA_VERSION}"
		module load "${_loadPipeline}/${_version}" || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to load ${_loadPipeline} module."
		_pathToPipeline="${EBROOTNGS_DNA}"
	elif [ "${_sampleType}" == "RNA" ]
	then
		_version="${NGS_RNA_VERSION}"
		module load "${_loadPipeline}/${_version}" || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to load ${_loadPipeline} module."
		_pathToPipeline="${EBROOTNGS_RNA}"
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Unknown _sampleType: ${_sampleType}."
	fi
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_pathToPipeline is ${_pathToPipeline}"
	
	_message="Creating directory: ${TMP_ROOT_DIR}/generatedscripts/${_project}/ ..."
	echo "${_message}" > "${_logFile}"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	mkdir -p "${TMP_ROOT_DIR}/generatedscripts/${_project}/"
	
	_message="Copying ${_pathToPipeline}/templates/generate_template.sh to ${_generateShScript} ..."
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${_logFile}"
	cp "${_pathToPipeline}/templates/generate_template.sh" "${_generateShScript}"
	
	if [ -f "${TMP_ROOT_DIR}/generatedscripts/${_project}/${_project}.${SAMPLESHEET_EXT}" ]
	then
		_message="${TMP_ROOT_DIR}/generatedscripts/${_project}/${_project}.${SAMPLESHEET_EXT} already exists and will be removed ..."
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
		echo "${_message}" >> "${_logFile}"
		rm "${TMP_ROOT_DIR}/generatedscripts/${_project}/${_project}.${SAMPLESHEET_EXT}"
	fi
	
	_message="Copying ${TMP_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT} to ${TMP_ROOT_DIR}/generatedscripts/${_project}/ ..."
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${_logFile}"
	cp "${TMP_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}" "${TMP_ROOT_DIR}/generatedscripts/${_project}/"
	
	cd "${TMP_ROOT_DIR}/generatedscripts/${_project}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to $(pwd)."
	
	_message="Running: sh ${TMP_ROOT_DIR}/generatedscripts/${_project}/generate.sh -p ${_project} -g ${group}>> ${_logFile}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	sh "${TMP_ROOT_DIR}/generatedscripts/${_project}/generate.sh" -p "${_project}" -g ${group} >> "${_logFile}" 2>&1
	touch "${_controlFileBase}.started"
	cd scripts
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to $(pwd)."
	
	sh submit.sh
	touch "${_controlFileBase}.finished"
	_message="Scripts generated and created: ${_controlFileBase}.finished."
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${_logFile}"
}

function submitPipeline () {
	local _project="${1}"
	local _run="${2}"
	local _sampleType="${3}" ## DNA or RNA
	local _controlFileBase="${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline"
	local _logFile="${_controlFileBase}.log"
	
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Starting submitPipeline part for project: ${_project}/${_run} ..."
	
	if [[ -e "${_controlFileBase}.started" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping  ${_project}/${_run}, because jobs were already submitted."
		return
	elif [[ -e "${_controlFileBase}.finished" ]]
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
	
	#
	# Track and Trace: log that we will start running jobs on the cluster.
	#
	local _url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
	printf '%s\n' "project,run_id,pipeline,url,copy_results_prm,date"  > "${_controlFileBase}.trackAndTrace.csv"
	printf '%s\n' "${_project},${_project},${_sampleType},${_url},,"  >> "${_controlFileBase}.trackAndTrace.csv"
	trackAndTracePostFromFile 'status_projects' 'add'                    "${_controlFileBase}.trackAndTrace.csv"
	
	_url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_samples&hideselect=true&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
	printf '%s\n' "project_job,job,project,started_date,finished_date,status,url,step"  > "${_controlFileBase}.trackAndTrace.csv"
	grep '^processJob' submit.sh | tr '"' ' ' | awk -v pro=${_project} -v url=${_url} '{OFS=","} {print pro"_"$2,$2,pro,"","","",url}' \
		>> "${_controlFileBase}.trackAndTrace.csv"
	awk '{FS=","}{if (NR==1){print $0}else{split($2,a,"_"); print $0","a[1]"_"a[2]}}' "${_controlFileBase}.trackAndTrace.csv"\
		> "${_controlFileBase}.trackAndTrace.csv.tmp"
	mv "${_controlFileBase}.trackAndTrace.csv.tmp" "${_controlFileBase}.trackAndTrace.csv"
	trackAndTracePostFromFile 'status_jobs' 'add' "${_controlFileBase}.trackAndTrace.csv"
	
	#
	# Submit jobs to scheduler.
	#
	log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Submitting jobs for ${_project}/${_run} ..."
	if [ ${group} == "umcg-atd" ]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Using submit option: --qos=dev."
		sh submit.sh --qos=dev >> "${_logFile}" 2>&1 \
                || {
                        echo "See ${_logFile} for details." > "${_controlFileBase}.failed"
                        return
                }
	else
		sh submit.sh >> "${_logFile}" 2>&1 \
                || {
                        echo "See ${_logFile} for details." > "${_controlFileBase}.failed"
                        return
                }
	fi
	touch "${_controlFileBase}.started"
	local _message="Jobs were submitted to the scheduler on ${HOSTNAME_SHORT} by ${ROLE_USER} for ${_project}/${_run} on $(date '+%Y-%m-%d-T%H%M')."
	echo "${_message}" >> "${_logFile}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
}

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
while getopts "g:l:h" opt; do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
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
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
)
for configFile in "${configFiles[@]}"; do 
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."

#
# Fetch (new) sample sheets from prm.
#
# ToDo: skip fetching sample sheets from prm once we have a 
#       proper prm mount on the GD clusters and the previous script
#       that created the sample sheet per project can run a GD cluster
#       instead of on a research cluster to create them directly on tmp.
#
declare -a sampleSheets=($(ssh ${HOSTNAME_PRM} "ls -1 ${PRM_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT}"))
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
sampleSheets=($(ls -1 "${TMP_ROOT_DIR}/Samplesheets/"*".${SAMPLESHEET_EXT}"))
for sampleSheet in "${sampleSheets[@]}"
do
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing sample sheet: ${sampleSheet} ..."
	
	project=$(basename "${sampleSheet}" ".${SAMPLESHEET_EXT}")
	run='run01'
	
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing: ${project} ..."
	if [[ ! -e "${TMP_ROOT_DIR}/logs/${project}" ]]
	then
		mkdir -m 2770 "${TMP_ROOT_DIR}/logs/${project}"
	fi
	
	#
	# Generate scripts (per sample sheet).
	#
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()
	declare    sampleType='DNA' # Default when not specified in sample sheet.
	declare    sampleTypeFieldIndex
	IFS="${SAMPLESHEET_SEP}" sampleSheetColumnNames=($(head -1 "${sampleSheet}"))
	for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]:-0} ; offset++ ))
	do
		#
		# Backwards compatibility for "Sample Type" including - the horror - a space and optionally quotes :o.
		#
		regex='Sample Type'
		if [[ "${sampleSheetColumnNames[${offset}]}" =~ ${regex} ]]
		then
			columnName='sampleType'
		else
			columnName="${sampleSheetColumnNames[${offset}]}"
		fi
		sampleSheetColumnOffsets["${columnName}"]="${offset}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${columnName} and sampleSheetColumnOffsets["${columnName}"] offset ${offset} "
	done
	
	if [[ ! -z "${sampleSheetColumnOffsets['sampleType']+isset}" ]]; then
		#
		# Get sampleType from sample sheet and check if all samples are of the same type.
		#
		sampleTypeFieldIndex=$((${sampleSheetColumnOffsets['sampleType']} + 1))
		sampleTypesCount=$(tail -n +2 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${sampleTypeFieldIndex} | sort | uniq | wc -l)
		if [[ "${sampleTypesCount}" -eq '1' ]]
		then
			sampleType=$(tail -n 1 "${sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${sampleTypeFieldIndex})
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found sampleType: ${sampleType}."
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${sampleSheet} contains multiple different sampleType values."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${project} due to error in sample sheet."
			continue
		fi
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType column missing in sample sheet; will use default value: ${sampleType}."
	fi
	
	generateScripts "${project}" "${run}" "${sampleType}"
	
	#
	# Submit generated job scripts (per project).
	#
	if [[ -e "${TMP_ROOT_DIR}/logs/${project}/${run}.generateScripts.finished" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project}..."
		submitPipeline "${project}" "${run}" "${sampleType}"
	fi
done

trap - EXIT
exit 0
