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
	local _filePrefix="${1}" ## name of the run: sequencingStartDate_Sequencer_run_flowcell
	local _sampleType="${2}" ## DNA or RNA
	local _loadPipeline="NGS_${_sampleType}"
	local _generateShScript="${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh"
	local _logger="${TMP_ROOT_DIR}/logs/${_filePrefix}/${_filePrefix}.${SCRIPT_NAME}.log"
	local _message
	
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
	
	_message="Creating directory: ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/ ..."
	echo "${_message}" > "${_logger}"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	mkdir -p "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
	
	_message="Copying ${_pathToPipeline}/generate_template.sh to ${_generateShScript} ..."
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${_logger}"
	cp "${_pathToPipeline}/generate_template.sh" "${_generateShScript}"
	
	if [ -f "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/${_filePrefix}.${SAMPLESHEET_EXT}" ]
	then
		_message="${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/${_filePrefix}.${SAMPLESHEET_EXT} already exists and will be removed ..."
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
		echo "${_message}" >> "${_logger}"
		rm "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/${_filePrefix}.${SAMPLESHEET_EXT}"
	fi
	
	_message="Copying ${TMP_ROOT_DIR}/Samplesheets/${_filePrefix}.${SAMPLESHEET_EXT} to ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/ ..."
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${_logger}"
	cp "${TMP_ROOT_DIR}/Samplesheets/${_filePrefix}.${SAMPLESHEET_EXT}" "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
	
	cd "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to $(pwd)."
	
	_message="Running: sh ${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh -p ${_filePrefix} >> ${_logger}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	sh "${TMP_ROOT_DIR}/generatedscripts/${_filePrefix}/generate.sh" -p "${_filePrefix}" >> "${_logger}" 2>&1
	
	cd scripts
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to $(pwd)."
	
	sh submit.sh
	touch "${TMP_ROOT_DIR}/logs/${_filePrefix}/${_filePrefix}.scriptsGenerated"
	_message="Scripts generated and created: ${TMP_ROOT_DIR}/logs/${_filePrefix}/${_filePrefix}.scriptsGenerated."
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	echo "${_message}" >> "${_logger}"
}

function submitPipeline () {
	local _project="${1}"
	local _run='run01'
	local _logger="${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}.log"
	
	if [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.started" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping  ${_project}/${_run}, because jobs were already submitted."
	elif [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping  ${_project}/${_run}, because jobs have already finished."
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Starting submitPipeline part for project: ${_project}/${_run} ..."
		
		if [[ ! -e "${TMP_ROOT_DIR}/logs/${_project}" ]]
		then
			mkdir -p "${TMP_ROOT_DIR}/logs/${_project}"
		fi
		
		cd "${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Navigated to: ${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/"
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Submitting jobs for ${_project}/${_run} ..."
		if [ ${group} == "umcg-atd" ]
		then
			sh submit.sh --qos=dev
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Using submit options: --qos=dev."
		else
			sh submit.sh
		fi
		touch "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.started"
		local _message="Jobs were submitted to the scheduler on ${HOSTNAME_SHORT} by ${ROLE_USER} for ${_project}/${_run} on $(date '+%Y-%m-%d-T%H%M')."
		echo "${_message}" >> "${_logger}"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message}"
	fi
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
# Get list of sample sheets from prm.
#
declare -a sampleSheets=($(ls -1 "${PRM_ROOT_DIR}/Samplesheets/"*".${SAMPLESHEET_EXT}"))
if [[ "${#sampleSheets[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No sample sheets found @ ${PRM_ROOT_DIR}/Samplesheets/: There is nothing to do."
	trap - EXIT
	exit 0
else
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${#sampleSheets[@]} sample sheets from ${PRM_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT} ..."
fi

#
# Parse sample sheets.
#
for sampleSheet in "${sampleSheets[@]}"
do
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing sample sheet: ${sampleSheet} ..."
	
	fileP=$(basename "${sampleSheet}")
	filePrefix=${fileP%.*}

	cp ${PRM_ROOT_DIR}/Samplesheets/${filePrefix}.${SAMPLESHEET_EXT} ${TMP_ROOT_DIR}/Samplesheets/

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run: ${filePrefix} ..."
	if [ ! -e "${TMP_ROOT_DIR}/logs/${filePrefix}" ]
	then
		mkdir -m 2770 "${TMP_ROOT_DIR}/logs/${filePrefix}"
	fi

	#
	# Generate scripts (per sample sheet).
	#
	if [ -f "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated" ]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated exists."
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Will use existing scripts for ${filePrefix}."
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated does not exist."
		log4Bash 'INFO'  "${LINENO}" "${FUNCNAME:-main}" '0' "Generating scripts for ${filePrefix} ..."
		
		HEADER=$(head -1 "${sampleSheet}") ; sed '1d' "${sampleSheet}" > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp" ; IFS=','  array=(${HEADER})
		count=1
		
		pipeline="DNA" # Default when not specified in sample sheet.
		for j in ${array[@]}
		do
			if [[ "${j}" == *"Sample Type"* ]]
			then
				awk -F"," '{print $'$count'}' "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.tmp" > "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.whichPipeline"
				pipeline=$(head -1 "${TMP_ROOT_DIR}/tmp/NGS_Automated/${filePrefix}.whichPipeline")
				break
			fi
		done
		
		generateScripts "${filePrefix}" "${pipeline}"
		
	fi
	
	#
	# Submit generated job scripts (per project).
	#
	if [ -f "${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.scriptsGenerated" ]
	then
		PROJECTARRAY=()
		while read line
		do
			PROJECTARRAY+="${line}"
		done<"${TMP_ROOT_DIR}/generatedscripts/${filePrefix}/project.txt"
		
		for project in "${PROJECTARRAY[@]}"
		do
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project}..."
			submitPipeline "${project}"
		done
	fi
done

trap - EXIT
exit 0
