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
	trap - EXIT
	exit 1
fi


function sanityChecking() {
	
	local _run="${1}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_run}..."
	
	#
	local _controlFileBase="${TMP_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}"
	local _logFile="${_controlFileBase}.log"
	
	#
	# Determine if samplesheet merging is possible for this sequence run, which is the case when
	#  1. The data transfer sequence run has finished successfully, and 
	#  2. corresponding samplesheets are present in samplesheets dir.
	#  3. samplesheets are ok.
	#  4. checksums are ok.
	
	#
	# Check if transfer of raw data has finished.
	#
	if  [[ -e "${TMP_ROOT_DIR}/${_run}/${_run}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/${_run}/${_run}.finished present."
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/${_run}/${_run}.finished absent."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}."
		return
	fi
	
	#
	# Check if processGsDataForPrm script was finished before for this run.
	#
	if [[ -e "${_controlFileBase}.finished" ]]
	then
		#
		# Check in script was finished before, which indicates the sequence run was already renamed and samplesheets merged.
		#
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.finished is there, data conversion and samplesheet merging ready done."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${_controlFileBase}.finished present."
	fi
	
	#
	# Check if sanityChecking was finished before for this run.
	#
	if [[ -e "${_controlFileBase}.sanityChecking.finished" ]]
	then
		#
		# If previous sanityChecking was ok, skip
		# 
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.sanityChecking.ok is there, ready for samplesheet merging."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sanityChecking ${_run}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.sanityChecking.ok not present. Continue..."
	fi
	
	#check if GS samplesheet is present
	if ls ${TMP_ROOT_DIR}/${_run}/CSV_UMCG_* > /dev/null 2>&1;then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "found: ${TMP_ROOT_DIR}/${_run}/CSV_UMCG_* "
		_gsSamplesheet=$(ls ${TMP_ROOT_DIR}/${_run}/CSV_UMCG_*.csv)
	else
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No GS samplesheet present for run ${TMP_ROOT_DIR}/${_run}/CSV_UMCG_*.csv"
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No GS samplesheet present for run ${_run}." >> "${_controlFileBase}.failed"
		return
	fi
	
	#check if checksum file is present.
	if ls "${TMP_ROOT_DIR}/${_run}/checksums.md5" > /dev/null 2>&1;then
		_checksumfile=$(ls "${TMP_ROOT_DIR}/${_run}/checksums.md5")
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '0' "No checksums file present." >> "${_controlFileBase}.failed"
		return
	fi	
		local _transferSoFarSoGood='true'
	#
	# Sanity checking for _run.
	#
	#     (No need to waist a lot of time on computing checksums for a partially failed transfer).
	#  1. Count fastq files presents and compair with number if samples in samplesheet.
	#  2. Secondly verify checksums on the destination.
	#
	if [[ "${_transferSoFarSoGood}" == 'true' ]];then
		local _countFilesSamplesheet=$(tail -n +2 ${TMP_ROOT_DIR}/${_run}/CSV_UMCG_*.csv | wc -l)
		local _countFastQFiles=$(ls ${TMP_ROOT_DIR}/${_run}/*_R1.fastq.gz | wc -l)
		if [[ ${_countFilesSamplesheet} -ne ${_countFastQFiles} ]]; then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_run} on GS samplsheet (${_countFilesSamplesheet}) and files (${_countFastQFiles}) is NOT the same!" \
				>> "${_controlFileBase}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files for ${_run} on GS samplsheet (${_countFilesSamplesheet}) and files (${_countFastQFiles}) is NOT the same!"
			_checksumVerification='FAILED'
		elif [ ! -e "${_controlFileBase}.md5.PASS" ]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files in samplesheet and in directory is the same for run: ${_run}: ${_countFastQFiles}."
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.md5.PASS missing, start md5sum check..."
			#
			# Verify checksums on transfered data.
			#
			local _checksumVerification='unknown'
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Started verification of checksums by ${DATA_MANAGER}@${sourceServerFQDN} using checksums from ${TMP_ROOT_DIR}/${_run}/checksums.md5"
			_checksumVerification=$(cd ${TMP_ROOT_DIR}/${_run}/
				if md5sum -c checksums.md5 > ${_controlFileBase}.md5.log 2>&1
				then
					echo 'PASS'
					touch "${_controlFileBase}.md5.PASS"
				else
					echo 'FAILED'
					touch "${_controlFileBase}.md5.FAILED"
				fi
			)
		elif [ -e "${_controlFileBase}.md5.PASS" ]
		then
			local _checksumVerification='PASS'
		fi
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
		if [[ "${_checksumVerification}" == 'FAILED' ]]; then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${_controlFileBase}.md5.log for details." \
				>> "${_controlFileBase}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${_controlFileBase}.md5.log for details."
		elif [[ "${_checksumVerification}" == 'PASS' || "${_controlFileBase}.md5.PASS" ]]; then
			#
			# Overwrite any previously created *.failed file if present,
			# add new status info incl. demultiplex stats to *.failed file and
			# then move the *.failed file to *.finished.
			# (Note: the content of *.finished will get inserted in the body of email notification messages,
			# when enabled in <group>.cfg for use by notifications.sh)
			#
			echo "The results can be found in: ${TMP_ROOT_DIR}." > "${_controlFileBase}.failed"
			if ls "${_controlFileBase}.log" 1>/dev/null 2>&1
			then
				cat "${_controlFileBase}.log" >> "${_controlFileBase}.failed"
			fi
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${_controlFileBase}.md5.log for details." \
				>>    "${_controlFileBase}.sanityChecking.failed" \
				&& mv "${_controlFileBase}.sanityChecking."{failed,finished}
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
		fi
	fi
	
	if [[ "${_checksumVerification}" == 'PASS' ]]; then
		#
		# Parse sample sheet to get a list of project values.
		#
		declare -a _sampleSheetColumnNames=()
		declare -A _sampleSheetColumnOffsets=()
		local      _projectFieldIndex
		declare -a _projects=()
	
		IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_gsSamplesheet}"))
		for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
		do
			_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
		done
		#
		# Check if GS samplesheet contains required project column.
		#
		if [[ ! -z "${_sampleSheetColumnOffsets['Sample_ID']+isset}" ]]; then
			_projectFieldIndex=$((${_sampleSheetColumnOffsets['Sample_ID']} + 1))
			IFS=$'\n' _projects=($(tail -n +2 "${_gsSamplesheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sort | uniq ))
			if [[ "${#_projects[@]:-0}" -lt '1' ]]
			then
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_gsSamplesheet} does not contain at least one project value."
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in samplesheet."
				touch "${_controlFileBase}.failed"
				return
			fi
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "project column missing in sample sheet."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in sample sheet."
			touch "${_controlFileBase}.failed"
			return
		fi
		
		#
		# Check if samplesheet is present for all projects.
		#
		for _project in "${_projects[@]}"
		do
		
		# ToDo: change location of sample sheet per project back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
			if [[ -f "${TMP_ROOT_DIR}/Samplesheets/new/${_project}.${SAMPLESHEET_EXT}" && -r "${TMP_ROOT_DIR}/Samplesheets/new/${_project}.${SAMPLESHEET_EXT}" && "${_controlFileBase}.samplesheetCheck.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_project}.${SAMPLESHEET_EXT} is present." >> "${_logFile}"
				_sampleSheet="${TMP_ROOT_DIR}/Samplesheets/new/${_project}.${SAMPLESHEET_EXT}"
			else
				log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '0' "${_project}.${SAMPLESHEET_EXT} is missing!" >> "${_controlFileBase}.failed"
			fi

			declare -a _sampleSheetColumnNames=()
			declare -A _sampleSheetColumnOffsets=()
			local      _projectFieldIndex
			declare -a _projects=()

			IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_sampleSheet}"))
			for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
			do
				_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
			done

			declare -a _sequencingStartDate=()
			local      _sequencingStartDateFieldIndex
			if [[ ! -z "${_sampleSheetColumnOffsets['sequencingStartDate']+isset}" ]]; then
			_sequencingStartDateFieldIndex=$((${_sampleSheetColumnOffsets['sequencingStartDate']} + 1))
			IFS=$'\n' _sequencingStartDate=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_sequencingStartDateFieldIndex}" | sort | uniq ))
			if [[ "${#_sequencingStartDate[@]:-0}" -lt '1' ]]
			then
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} does not contain at least one project value."
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in samplesheet."
				touch "${_controlFileBase}.failed"
				return
			elif [[  "${#_sequencingStartDate[@]:-0}" -eq '1' ]]
			then
				echo "$_sequencingStartDate" >> "${_controlFileBase}.sequencingStartDate"
			fi
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "project column missing in sample sheet."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in sample sheet."
			touch "${_controlFileBase}.failed"
			return
		fi
		done
		touch "${_controlFileBase}.sanityChecking.finished"
	else 
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
		echo "_checksumVerification = ${_checksumVerification} for run ${_run}" > "${_controlFileBase}.failed"
		return
	fi


}

function renameFastQs() {
	local _run="${1}"
	local _controlFileBase="${TMP_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}"
	local _logFile="${_controlFileBase}.log"
	local _runPrefix="${TMP_ROOT_DIR}/${_run}/"

if [[ -e "${_controlFileBase}.renameFastQs.finished" ]]
then
	#
	# If previous sanityChecking was ok, skip
	# 
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.renameFastQs.finished is there, nothing to do here."
	return
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.renameFastQs.finished not present. continue"
fi

if [[ -e "${_controlFileBase}.sanityChecking.finished" && "${_controlFileBase}.sequencingStartDate" ]]
then
	#
	# If previous sanityChecking was ok, skip
	# 
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.sanityChecking.finished is there, ready for samplename renaming."
	IFS=$'\n' _sequencingStartDate=($( cat "${_controlFileBase}.sequencingStartDate" | sort | uniq ))
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBase}.sanityChecking.finished not present. return..."
	return
fi

echo "_sequencingStartDate: ${_sequencingStartDate}"

cd "${_runPrefix}"
local _firstFastQ=$(ls -1 *.fastq.gz | head -1)
	echo "DEBUG:    Found _firstFastQ ............ = ${_firstFastQ}"

	local _regex='^([A-Z0-9]+)_(103373-009)(.+).fastq.gz'

	if [[ "${_firstFastQ}" =~ ${_regex} ]]
	then
		local _flowcell="${BASH_REMATCH[1]}"
		local _runID="${BASH_REMATCH[2]}"

		echo "DEBUG:    Found _flowcell ............... = ${_flowcell}"
		echo "DEBUG:    Found _runID .................. = ${_runID}"
	else
		echo "FATAL: Failed to parse required meta-data values from ID of first read of ${_runPrefix}/${_firstFastQ}"
		exit 1
	fi

module load ngs-utils/"${NGS_UTILS_VERSION}"
module list

cd "${_runPrefix}"

renameFastQs.bash -s "${_sequencingStartDate}" -f "${_flowcell}_${_runID}"'*'

if [ ${?} -eq 0 ]
then
	touch "${_controlFileBase}.renameFastQs.finished"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "renameFastQs finished."
else
	touch "${_controlFileBase}.renameFastQs.failed"
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '0' "renameFastQs failed."
fi

}

function mergeSamplesheetPerProject() {
	
	local _run="${1}"
	local _sampleSheet="${TMP_ROOT_DIR}/Samplesheets/archive/${_run}.${SAMPLESHEET_EXT}"
	local _controlFileBase="${TMP_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}"
	local _controlFileFinished="${_controlFileBase}.mergeSamplesheetPerProject.finished"
	local _logFile="${_controlFileBase}.log"
	local _processSoFarSoGood='false'
	
	if [[ -e "${_controlFileFinished}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_controlFileFinished} -> Skipping merging ${_run}."
		return
	elif [[ ! -e "${_controlFileBase}.sanityChecking.finished" || ! -e "${_controlFileBase}.renameFastQs.finished" ]]
	then
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '0' "Not Found ${_controlFileBase}.sanityChecking.finished or ${_controlFileBase}.renameFastQs.finished"
		touch "${_controlFileBase}.mergeSamplesheetPerProject.failed"
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${_controlFileFinished} present -> Merge samplesheets for ${_run}..."
		_processSoFarSoGood='true'
		
	fi
	

#
# combine GS samplesheet with inhouse samplesheets.
python NGS_Automated/bin/createInhouseSamplesheetFromGS.py \
--GenomeScanInputDir "${TMP_ROOT_DIR}/${_run}/" \
--logfile "${_controlFileBase}.log" \
--samplesheetNewDir "${TMP_ROOT_DIR}/Samplesheets/new/" \
--samplesheetOutputDir "${TMP_ROOT_DIR}/Samplesheets/"


	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	
	cd "${TMP_ROOT_DIR}/${_run}/" 
	local _runDir=$(find * -type d | grep -P '[0-9]*_[A_Za-z0-9]*_*[0-9]*')
	cd -
	_gsSamplesheet=$(ls ${TMP_ROOT_DIR}/${_run}/CSV_UMCG_*.csv)
	IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_gsSamplesheet}"))
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	_projectFieldIndex=$((${_sampleSheetColumnOffsets['Sample_ID']} + 1))
	IFS=$'\n' _projects=($(tail -n +2 "${_gsSamplesheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sort | uniq ))
	
	#
	# Cat samplesheets projects to _runDir.csv.
	#
	flag=0
	cd "${TMP_ROOT_DIR}/Samplesheets/"
	for _project in "${_projects[@]}"
	do
		if [ "$flag" -eq 0 ]
		then
			cat "${_project}.csv" > "${TMP_ROOT_DIR}/${_run}/${_runDir}/${_runDir}.csv"
			flag=1
		else
			tail -n +2 "${_project}.csv" >> "${TMP_ROOT_DIR}/${_run}/${_runDir}/${_runDir}.csv"
		fi
	done
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' " GS run samplesheet can found in: ${TMP_ROOT_DIR}/${_run}/${_runDir}/${_runDir}.csv"
	cd -
	
	if [ ${?} -eq 0 ]
	then
		touch "${_controlFileFinished}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Merge samplesheets ${_run} finished."
		_processSoFarSoGood='true'
		touch "${TMP_ROOT_DIR}/logs/${_runDir}_Demultiplexing.started"
	else
		touch "${_controlFileBase}.mergeSamplesheetPerProject.failed"
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '0' "Merge samplesheets ${_run} failed."
		return
	fi
		
	if [[ "${_processSoFarSoGood}" == 'true' ]]
	then
		
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Moving  ${_run}/${_runDir} to: ${TMP_ROOT_DIR}/rawdata/ngs/"
		mv "${TMP_ROOT_DIR}/${_run}/${_runDir}" "${TMP_ROOT_DIR}/rawdata/ngs/${_runDir}"
		echo "OK! $(date '+%Y-%m-%d-T%H%M'): Samplesheets ${_runDir} merged." \
		>>    "${TMP_ROOT_DIR}/logs/${_runDir}_Demultiplexing.started" \
		&& mv "${TMP_ROOT_DIR}/logs/${_runDir}_Demultiplexing."{started,finished}
		
	
		# Overwrite any previously created *.failed file if present,
		# then move the *.failed file to *.finished.
		# (Note: the content of *.finished will get inserted in the body of email notification messages,
		# when enabled in <group>.cfg for use by notifications.sh)
		echo "OK! $(date '+%Y-%m-%d-T%H%M'): Samplesheets ${_run} merged." \
		>>    "${_controlFileBase}.failed" \
		&& mv "${_controlFileBase}."{failed,finished}
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Merging samplesheets succeeded.'
	fi
}

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished demultiplexed run from tmp to prm storage.
Usage:
	$(basename $0) OPTIONS
Options:
	-h   Show this help.
	-g   Group.
	-e   Enable email notification. (Disabled by default.)
	-n   Dry-run: Do not perform actual sync, but only list changes instead.
	-l   Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.
	-s   Source server address from where the rawdate will be fetched
		Must be a Fully Qualified Domain Name (FQDN).
		E.g. gattaca01.gcc.rug.nl or gattaca02.gcc.rug.nl

Config and dependencies:
	This script needs 4 config files, which must be located in ${CFG_DIR}:
	1. <group>.cfg       for the group specified with -g
	2. <this_host>.cfg   for this server. E.g.: "${HOSTNAME_SHORT}.cfg"
	3. <source_host>.cfg for the source server. E.g.: "<hostname>.cfg" (Short name without domain)
	4. sharedConfig.cfg  for all groups and all servers.
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
declare sourceServerFQDN=''
while getopts "g:l:s:h" opt
do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		s)
			sourceServerFQDN="${OPTARG}"
			sourceServer="${sourceServerFQDN%%.*}"
			;;
		l)
			l4b_log_level="${OPTARG^^}"
			l4b_log_level_prio="${l4b_log_levels[${l4b_log_level}]}"
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
if [[ -z "${sourceServerFQDN:-}" ]]
then
log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a Fully Qualified Domain Name (FQDN) for sourceServer with -s.'
fi


#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/${sourceServer}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
)
for configFile in "${configFiles[@]}"
do
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
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
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
# ToDo: change location of job control files back to ${TMP_ROOT_DIR} once we have a 
#       proper prm mount on the GD clusters and this script can run a GD cluster
#       instead of on a research cluster.
#

lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
#log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."

#
# Use multiplexing to reduce the amount of SSH connections created
# when rsyncing using the group's data manager account.
# 
#  1. Become the "${DATA_MANAGER} user who will rsync the data to prm and 
#  2. Add to ~/.ssh/config:
#		ControlMaster auto
#		ControlPath ~/.ssh/tmp/%h_%p_%r
#		ControlPersist 5m
#  3. Create ~/.ssh/tmp dir:
#		mkdir -p -m 700 ~/.ssh/tmp
#  3. Recursively restrict access to the ~/.ssh dir to allow only the owner/user:
#		chmod -R go-rwx ~/.ssh
#

#
# Get a list of all sample sheets for this group on the specified sourceServer, where the raw data was generated,
# then
#	1. loop over their analysis ("run") sub dirs and check if there are any we need to rsync.
#	2. split the sample sheets per project and the data was rsynced.
#


declare -a runDirs=($(find "${TMP_ROOT_DIR}" -maxdepth 1 -mindepth 1 -type d -name "[0-9]*-[0-9]*"))

echo "${runDirs[@]}"

if [[ "${#runDirs[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No directories found for ${TMP_ROOT_DIR}/"
else
	for rundir in "${runDirs[@]}"
	do
		#
		# Process this sample sheet / run.
		#
		runPrefix="$(basename "${rundir}")"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${runPrefix}..."
		#
		# ToDo: change location of log files back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
		
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${runPrefix}/"
		
		sanityChecking "${runPrefix}"
		renameFastQs "${runPrefix}"
		mergeSamplesheetPerProject "${runPrefix}"

	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0

