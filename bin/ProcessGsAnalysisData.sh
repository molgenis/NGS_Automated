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

function sanityChecking(){
	local _batch="${1}"
	local _controlFileBase="${2}"
	local _dataType="${3}"
	local _originalbatch="${4}"
	local _projectName="${5}"
	local _controlFileBaseForFunction="${_controlFileBase}.${_dataType}_${FUNCNAME[0]}"
	
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing batch ${_batch}..."
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_batch}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
		
	local _numberOfSamplesheets
	_numberOfSamplesheets=$(find "${TMP_ROOT_DIR}/${_batch}/" -maxdepth 1 -mindepth 1 -name 'UMCG_CSV_*.'"${SAMPLESHEET_EXT}" 2>/dev/null | wc -l)
	
	if [[ "${_numberOfSamplesheets}" -eq 1 ]]
	then
		local _gsSampleSheet
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found: one ${TMP_ROOT_DIR}/${_batch}/UMCG_CSV_*.${SAMPLESHEET_EXT} samplesheet."
		_gsSampleSheet=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/UMCG_CSV_"*".${SAMPLESHEET_EXT}")
		#
		# Make sure:
		#  1. The last line ends with a line end character.
		#  2. We have the right line end character: convert any carriage return (\r) to newline (\n).
		#  3. We remove empty lines: lines containing only white space and/or field separators are considered empty too.
		#
		cp "${_gsSampleSheet}"{,.converted} \
			2>> "${_controlFileBaseForFunction}.started" \
			&& printf '\n' \
			2>> "${_controlFileBaseForFunction}.started" \
			>> "${_gsSampleSheet}.converted" \
			&& sed -i 's/\r/\n/g' "${_gsSampleSheet}.converted" \
			2>> "${_controlFileBaseForFunction}.started" \
			&& sed -i "/^[\s${SAMPLESHEET_SEP}]*$/d" "${_gsSampleSheet}.converted" \
			2>> "${_controlFileBaseForFunction}.started" \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to convert line end characters and/or remove empty lines for ${_gsSampleSheet}. (project=${_projectName})"
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		#
		# Continue with converted samplesheet.
		#
		_gsSampleSheet="${_gsSampleSheet}.converted"
		
	elif [[ "${_numberOfSamplesheets}" -gt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "More than one UMCG_CSV_*.${SAMPLESHEET_EXT} GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/. (project=${_projectName})"
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	elif [[ "${_numberOfSamplesheets}" -lt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/. (project=${_projectName})"
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	
	#
	# Check if there are known missing samples. Columnname available [Y/N]
	#
	csvFile="${_gsSampleSheet}"
	batchDir="${TMP_ROOT_DIR}/${_batch}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Check if available column header is there"
	
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()

	IFS="," read -r -a sampleSheetColumnNames <<< "$(head -1 "${csvFile}")"
	for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]} ; offset++ ))
	do
		columnName="${sampleSheetColumnNames[${offset}]}"
		sampleSheetColumnOffsets["${columnName}"]="${offset}"
	done

	if [[ -n "${sampleSheetColumnOffsets['ID']+isset}" ]]; then
		idFieldIndex=$((${sampleSheetColumnOffsets['ID']} + 1))
	fi

	if [[ -n "${sampleSheetColumnOffsets['available']+isset}" ]]; then
		availableFieldIndex=$((${sampleSheetColumnOffsets['available']} + 1))
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "headername [available] found, now checking for known missing samples"
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "columnname [available] not found"
		return
	fi
	
	awk -v batchDir="${batchDir}" -v aFI="${availableFieldIndex}" -v iFI="${idFieldIndex}" 'BEGIN {FS=","}{if (NR>1){if ($aFI=="Y"){print $0}else{ print $iFI > batchDir"/missing_samples.txt" }}else{print $0}}' "${csvFile}" > "${csvFile}.checked"
	mv -v "${csvFile}.checked" "${csvFile}"

	if [[ -e "${batchDir}/missing_samples.txt" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "WARN: There are samples missing, ${batchDir}/missing_samples.txt is created with the missing sample(s)"
		rsync -v "${batchDir}/missing_samples.txt" "${JOB_CONTROLE_FILE_BASE}.missingSamples"
	
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "sample(s) will be removed from inhouse samplesheet and UMCG_CSV"
	
		mapfile -t uniqProjects< <(awk -v iFI="${idFieldIndex}" 'BEGIN {FS=","}{if (NR>1){print $iFI}}' "${csvFile}" | awk 'BEGIN {FS="-"}{print $1"-"$2}' | sort -V  | uniq)
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "awk -v iFI=\"${idFieldIndex}\" 'BEGIN {FS=\",\"}{if (NR>1){print \$iFI}}' \"${csvFile}\" | awk 'BEGIN {FS=\"-\"}{print \$1\"-\"\$2}' | sort -V  | uniq"
		if [[ "${#uniqProjects[@]}" -eq '0' ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "There are no projects in the samplesheet! (${csvFile})"
			return
		elif [[ "${#uniqProjects[@]}" -gt '1' ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "There is more than 1 project in the samplesheet, is this an old GS samplesheet? (${csvFile})"
			return
		fi
		
		projectName="${uniqProjects[0]}"
		IFS="-" read  -r -a splittedProjectName <<< "${projectName}"
		projectNumber="${splittedProjectName[0]}"
		projectSuffix="${splittedProjectName[1]}"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "projectNumber=${projectNumber}, projectSuffix=${projectSuffix}"
		newProjectName=''
	
		if [[ "${projectNumber: -1}" == "G" ]]
		then
			newProjectName="${projectNumber%?}H-${projectSuffix}"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "new samplesheet name will be ${newProjectName}.csv"
		elif [[ "${projectNumber: -1}" == "H" ]]	
		then
			newProjectName="${projectNumber%?}I-${projectSuffix}"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "new samplesheet name will be ${newProjectName}.csv"
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "This was too much reanalysis, projectname options are G,H or I"
			return
		fi
		if [[ ! -e "${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv.original" ]]
		then
			rsync -v "${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv" "${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv.original"
		fi
	
		header='yes'
		while read -r line 
		do
			sampleProcessStepID=$(echo "${line}" | awk 'BEGIN {FS="-"}{print $3}')
			if [[ "${header}" == 'yes' ]]
			then 
				head -1 "${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv" > "${TMP_ROOT_DIR}/Samplesheets/${newProjectName}.csv"
			fi
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Adding missing sample to new samplesheet: ${TMP_ROOT_DIR}/Samplesheets/${newProjectName}.csv"
			if grep -q "${sampleProcessStepID}" "${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv"
			then	
				grep "${sampleProcessStepID}" "${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv" >> "${TMP_ROOT_DIR}/Samplesheets/${newProjectName}.csv"
			else
				log4Bash 'WARN' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Mmm, the sampleProcessStepID ${sampleProcessStepID} is not found in ${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv"
			fi
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Removing missing sample from old samplesheet: ${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv (created ${TMP_ROOT_DIR}/Samplesheets/${projectName}.original"
			sed -i "/,${sampleProcessStepID},/d" "${TMP_ROOT_DIR}/Samplesheets/${projectName}.csv"
		
			header='done'
		done <"${batchDir}/missing_samples.txt"
	
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Changing projectName ${projectName} into new project name ${newProjectName}"
		perl -p -e "s|${projectName}|${newProjectName}|g" "${TMP_ROOT_DIR}/Samplesheets/${newProjectName}.csv" > "${TMP_ROOT_DIR}/Samplesheets/${newProjectName}.csv.tmp"
		mv "${TMP_ROOT_DIR}/Samplesheets/${newProjectName}.csv.tmp" "${TMP_ROOT_DIR}/Samplesheets/${newProjectName}.csv"
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "There are no samples missing."
	fi
	
	#
	# Count Bam/gVCF files present on disk 
	#
	
	local _countSamplesInSamplesheet
	local _countBamFilesOnDisk
	local _countgVcfFilesOnDisk

	_countSamplesInSamplesheet=$(grep -o "${_originalbatch}-[0-9][0-9]*" "${csvFile}" | sort -u | wc -l)
	_countBamFilesOnDisk=$(find "${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/" -maxdepth 2 -mindepth 2 \( -name '*bam' ! -name '*.repeats.bam' \) | wc -l)
	_countgVcfFilesOnDisk=$(find "${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/" -maxdepth 2 -mindepth 2 -name '*.gvcf.gz' | wc -l)
	if [[ "${_countBamFilesOnDisk}" -ne "${_countSamplesInSamplesheet}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Amount bam files (${_countBamFilesOnDisk}) is not the same as the number of lines in the samplesheet ${_countSamplesInSamplesheet} (${_countSamplesInSamplesheet}). (project=${_projectName})"
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	if [[ "${_countgVcfFilesOnDisk}" -ne "${_countSamplesInSamplesheet}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Amount gVCF files (${_countgVcfFilesOnDisk}) is not the same as the number of lines in the samplesheet ${_countSamplesInSamplesheet} (${_countSamplesInSamplesheet}). (project=${_projectName})"
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi

	#
	# get list of sampleFolders
	#
	mapfile -t _sampleFolders < <(find "${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/" -maxdepth 1 -mindepth 1 -type d)
	if [[ "${#_sampleFolders[@]}" -eq '0' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "There is no data in ${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/ (project=${_projectName})"
		return
	fi
	local _sampleFolder 
	for _sampleFolder in "${_sampleFolders[@]}"
	do
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${_sampleFolder}"
		mapfile -t _checksumFiles < <(find "${_sampleFolder}/" -name '*.md5sum' )
		if [[ "${#_checksumFiles[@]}" -eq '0' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No checksum files (.md5sum) found in ${_sampleFolder}/ (project=${_projectName})"
			return
		fi
		
		#
		# Checksumming + renaming md5sum to md5 format
		#
		local _checksumFile
		for _checksumFile in "${_checksumFiles[@]}"
		do
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing checksumFile: ${_checksumFile} in sampleFolder:${_sampleFolder}"
			local _filename
			_filename="$(basename "${_checksumFile%.md5sum}")"
			cat "${_checksumFile}" > "${_sampleFolder}/${_filename}.md5"
		done
	done
	
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
}

function mergeSamplesheets(){
	
	local _batch="${1}"
	local _controlFileBase="${2}"
	local _dataType="${3}"
	local _originalbatch="${4}"
	local _projectName="${5}"
	local _controlFileBaseForFunction="${_controlFileBase}.${_dataType}_${FUNCNAME[0]}"
	
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_batch}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	
	#
	# Convert log4bash log levels to Python logging levels where necessary
	#
	local _pythonLogLevel
	_pythonLogLevel='TRACE' # default fallback.
	if [[ "${l4b_log_level}" == 'TRACE' ]]
	then
		_pythonLogLevel='DEBUG'
	elif [[ "${l4b_log_level}" == 'WARN' ]]
	then
		_pythonLogLevel='WARNING'
	elif [[ "${l4b_log_level}" == 'FATAL' ]]
	then
		_pythonLogLevel='CRITICAL'
	else
		_pythonLogLevel="${l4b_log_level}"
	fi
	#
	# Combine GenomeScan samplesheet per batch with inhouse samplesheet(s) per project.
	#
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "combining GS samplesheet with inhouse samplesheet"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "createInhouseSamplesheetFromGS_v2.py --genomeScanInputDir \"${TMP_ROOT_DIR}/${_batch}/\" --inhouseSamplesheetsInputDir \"${TMP_ROOT_DIR}/Samplesheets/\" --samplesheetsOutputDir \"${TMP_ROOT_DIR}/${_batch}/\" --batchName \"${_batch}\" --logLevel \"${_pythonLogLevel}\" >> ${_controlFileBaseForFunction}.started"
	createInhouseSamplesheetFromGS_v2.py \
		--genomeScanInputDir "${TMP_ROOT_DIR}/${_batch}/" \
		--inhouseSamplesheetsInputDir "${TMP_ROOT_DIR}/Samplesheets/" \
		--samplesheetsOutputDir "${TMP_ROOT_DIR}/${_batch}/" \
		--batchName "${_batch}" \
		--logLevel "${_pythonLogLevel}" \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "createInhouseSamplesheetFromGS_v2.py failed. (project=${_projectName})"
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}


	csvFile=$(ls -1 "${TMP_ROOT_DIR}/${gsBatch}/UMCG_CSV_"*".csv")
	mapfile -t uniqProjects< <(awk 'BEGIN {FS=","}{if (NR>1){print $2}}' "${csvFile}" | awk 'BEGIN {FS="-"}{print $1"-"$2}' | sort -V  | uniq)
	if [[ "${#uniqProjects[@]}" -eq '0' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "There are no projects, ERROR "
		return
	elif [[ "${#uniqProjects[@]}" -gt '1' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "There is more than 1 project (NUMBER:${#uniqProjects[@]})"
		return
	fi
		# 	then
	samplesheet="${TMP_ROOT_DIR}/${_batch}/${uniqProjects[0]}.csv"
	
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Moving ${samplesheet} to ${TMP_ROOT_DIR}/Samplesheets/POST_DRAGEN/"
	mv -v "${samplesheet}" "${TMP_ROOT_DIR}/Samplesheets/POST_DRAGEN/"
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
}

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
Script to process genomescan analysis data.

Usage:
	$(basename "${0}") OPTIONS
Options:
	-h	Show this help.
	-g	Group.
	-t	overruling which tmpdir to use (default: tmp1X)
	-l	Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:
	This script needs 4 config files, which must be located in ${CFG_DIR}:
	1. <group>.cfg       for the group specified with -g
	2. <this_host>.cfg   for this server. E.g.: "${HOSTNAME_SHORT}.cfg"
	3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================
EOH
	trap - EXIT
	exit 0
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
while getopts ":g:l:t:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		t)
			overrulingTMP_LFS="${OPTARG}"
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


if [[ -n "${overrulingTMP_LFS:-}" ]]
then
	TMP_LFS="${overrulingTMP_LFS}"
	# shellcheck disable=SC1091
	source "${CFG_DIR}/sharedConfig.cfg"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "TMP_LFS= ${TMP_LFS}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "TMP_ROOT_DIR= ${TMP_ROOT_DIR}"
fi


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
# but before doing the actual data transfers.
#
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

#
# Define timestamp per day for a log file per day.
#
# We pull all data in one go and not per batch/experiment/sample/project,
# so we cannot create a log file per batch/experiment/sample/project to signal *.finished or *.failed.
# Using a single log file for this script, would mean we would only get an email notification for *.failed once,
# which would not get cleaned up / reset during the next attempt to rsync data.
# Therefore we define a JOB_CONTROLE_FILE_BASE per day, which will ensure we get notified once a day if something goes wrong.
#
# Note: this script will only create a *.failed using the log4Bash() function from lib/sharedFunctions.sh.
#

#
# To make sure a *.finished file is not rsynced before a corresponding data upload is complete, we
# * first rsync everything, but with an exclude pattern for '*.finished' and
# * then do a second rsync for only '*.finished' files.
#

#
##
### process local Analysis data
##
#
	readarray -t gsBatches< <(rsync -f"+ */" -f"- *" "${TMP_ROOT_DIR}/" | awk '{if ($5 != "" && $5 != "." && $5 ~/-/){print $5}}')
	if [[ "${#gsBatches[@]}" -eq '0' ]]
	then
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${TMP_ROOT_DIR}/"
	else
		for gsBatch in "${gsBatches[@]}"
		do
			controlFileBase="${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}"
			export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing process analysis batch ${gsBatch}..."

			if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gsBatch} already processed, no need process the data again."
				continue
			fi
			
			if [[ -e "${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.PullGsAnalysisData.finished" ]]
			then
				if [[ "${gsBatch}" == *"_"* ]]
				then
					originalBatch=$(echo "${gsBatch}" | awk 'BEGIN {FS="_"}{print $1}')
					else
					originalBatch="${gsBatch}"
				fi
				projectName=$(head -2 "${TMP_ROOT_DIR}/${gsBatch}/UMCG_CSV_"*".csv" | tail -1 | awk 'BEGIN {FS=","}{print $2}' | awk 'BEGIN {FS="-"}{print $1"-"$2}')

				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${gsBatch}/"
				printf '' > "${JOB_CONTROLE_FILE_BASE}.started"

				sanityChecking "${gsBatch}" "${controlFileBase}" "${analysisFolder}" "${originalBatch}" "${projectName}"
					
				if [[ -e "${controlFileBase}.${analysisFolder}_sanityChecking.finished" ]]
				then
					mergeSamplesheets "${gsBatch}" "${controlFileBase}" "${analysisFolder}" "${originalBatch}" "${projectName}"
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.sanityChecking.finished absent -> sanityChecking failed."
				fi

				if [[ -e "${controlFileBase}.${analysisFolder}_mergeSamplesheets.finished" ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.mergeSamplesheets.finished present -> processing completed for batch ${gsBatch}..."
					rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing batch ${gsBatch}."
					mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.mergeSamplesheets.finished absent -> processing failed for batch ${gsBatch}."
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process batch ${gsBatch}. (project=${projectName})"
					mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				fi

			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gsBatch}.PullGsAnalysisData is not finished (yet)"
				continue
			fi
		done
	fi
#
# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0
