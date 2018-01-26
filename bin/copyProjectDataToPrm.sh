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

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished analysis project from tmp to prm storage.

Usage:

	$(basename $0) OPTIONS

Options:

	-h   Show this help.
	-g   Group.
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

function rsyncProjectRun() {
	local _project="${1}"
	local _run="${2}"
	local _sampleType=${3}
	local _controlFileBase="${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}"
	local _logFile="${_controlFileBase}.log"
	
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_project}/${_run}..."
	
	#
	# Determine whether an rsync is required for this run, which is the case when
	#  1. either the pipeline has finished and this copy script has not
	#  2. or when a pipeline has updated the results after a previous execution of this script. 
	#
	# Temporarily check for "${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished"
	#        in addition to "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished"
	# for backwards compatibility with old NGS_Automated 1.x.
	#
	local _pipelineFinished='false'
	local _rsyncRequired='false'
	if [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished" ]]
	then
		# New NGS_Automated 2.x *.pipeline.finished per project per run sub dir.
		local _pipelineFinishedFile="${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished"
		_pipelineFinished='true'
	elif [[ -f "${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished" ]]
	then
		# Deprecated old NGS_Automated 1.x *.pipeline.finished per project.
		local _pipelineFinishedFile="${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished"
		_pipelineFinished='true'
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No *.pipeline.finished present."
	fi
	if [[ "${_pipelineFinished}" == 'true' ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_pipelineFinishedFile}..."
		if [[ -f "${_controlFileBase}.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_controlFileBase}.finished."
			if [[ "${_pipelineFinishedFile}" -nt "${_controlFileBase}.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "*.pipeline.finished newer than *.${SCRIPT_NAME}.finished."
				_rsyncRequired='true'
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "*.pipeline.finished older than *.${SCRIPT_NAME}.finished."
			fi
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${_controlFileBase}.finished present."
			_rsyncRequired='true'
		fi
	fi
	
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsync required = ${_rsyncRequired}."
	if [[ "${_rsyncRequired}" == 'false' ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_project}/${_run}."
		return
	else
		touch "${_controlFileBase}.started"
	fi
	
	#
	# Track and Trace: log that we will start rsyncing to prm.
	#
	local _url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
	printf '%s\n' "project,run_id,pipeline,url,copy_results_prm,date"  > "${_controlFileBase}.trackAndTrace.csv"
	printf '%s\n' "${_project},${_project},${_sampleType},${_url},started,"      >> "${_controlFileBase}.trackAndTrace.csv"
	trackAndTracePostFromFile 'status_projects' 'update'                 "${_controlFileBase}.trackAndTrace.csv"
	
	#
	# Count the number of all files produced in this analysis run.
	#
	local _countFilesProjectRunDirTmp=$(find "${TMP_ROOT_DIR}/projects/${_project}/${_run}/" -type f | wc -l)
	
	#
	# Recursively create a list of MD5 checksums unless it is 
	#  1. already present, 
	#  2. and complete,
	#  3. and up-to-date.
	#
	local _checksumsAvailable='false'
	if [ -f "${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5" ]
	then
		if [[ ${_pipelineFinishedFile} -ot "${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5" ]]
		then
			local _countFilesProjectRunChecksumFileTmp=$(wc -l "${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5" | awk '{print $1}')
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum file contains ${_countFilesProjectRunChecksumFileTmp} files and run dir contains ${_countFilesProjectRunDirTmp} files."
			if [[ "${_countFilesProjectRunChecksumFileTmp}" -eq "${_countFilesProjectRunDirTmp}" ]]
			then
				_checksumsAvailable='true'
			fi
		fi
	fi
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "md5deep checksums already present = ${_checksumsAvailable}."
	if [[ "${_checksumsAvailable}" == 'false' ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Computing MD5 checksums with md5deep for ${_project}/${_run}/..."
		#
		# ToDo: remove dependency on relative path.
		#
		cd "${TMP_ROOT_DIR}/projects/${_project}/" \
			|| log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot access ${TMP_ROOT_DIR}/projects/${_project}/."
		md5deep -r -j0 -o f -l "${_run}/" > "${_run}.md5" 2>> "${_logFile}" \
			|| log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot compute checksums with md5deep. See ${_logFile} for details."
	fi
	
	#
	# Perform rsync.
	#  1. For ${_run} dir: recursively with "default" archive (-a),
	#     which checks for differences based on file size and modification times.
	#     No need to use checksums here as we will verify checksums later anyway.
	#  2. For ${_run}.md5 list of checksums with archive (-a) and -c to determine 
	#     differences based on checksum instead of file size and modification time.
	#     It is vitally important (and computationally cheap) to make sure 
	#     the list of checksums is complete and up-to-date!
	#
	# ToDo: Do we need to add --delete to get rid of files that should no longer be there 
	#       if an analysis run got updated?
	#
	local _transferSoFarSoGood='true'
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run} dir..."
	rsync -av ${dryrun:-} \
		"${TMP_ROOT_DIR}/projects/${_project}/${_run}" \
		"${DATA_MANAGER}@${HOSTNAME_PRM}:${PRM_ROOT_DIR}/projects/${_project}/" \
		>> "${_logFile}" 2>&1 \
	|| {
		mv "${_controlFileBase}."{started,failed}
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${TMP_ROOT_DIR}/projects/${_project}/${_run} dir. See ${_logFile} for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_logFile} for details." \
			>> "${_controlFileBase}.failed"
		_transferSoFarSoGood='false'
		}

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run}.md5 checksums..."
	rsync -acv ${dryrun:-} \
		"${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5" \
		"${DATA_MANAGER}@${HOSTNAME_PRM}:${PRM_ROOT_DIR}/projects/${_project}/" \
		>> "${_logFile}" 2>&1 \
	|| {
		mv "${_controlFileBase}."{started,failed}
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${TMP_ROOT_DIR}/projects/${_project}/${_run}.md5. See ${_logFile} for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_logFile} for details." \
			>> "${_controlFileBase}.failed"
		_transferSoFarSoGood='false'
		}

	#
	# Sanity check.
	#
	#  1. Firstly do a quick count of the amount of files to make sure we are complete.
	#     (No need to waist a lot of time on computing checksums for a partially failed transfer).
	#  2. Secondly verify checksums on the destination.
	#
	if [[ "${_transferSoFarSoGood}" == 'true' ]]
	then
		local _countFilesProjectRunDirPrm=$(ssh ${DATA_MANAGER}@${HOSTNAME_PRM} "find ${PRM_ROOT_DIR}/projects/${_project}/${_run}/ -type f | wc -l")
		if [[ ${_countFilesProjectRunDirTmp} -ne ${_countFilesProjectRunDirPrm} ]]
		then
			mv "${_controlFileBase}."{started,failed}
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectRunDirTmp}) and prm (${_countFilesProjectRunDirPrm}) is NOT the same!" \
				>> "${_controlFileBase}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectRunDirTmp}) and prm (${_countFilesProjectRunDirPrm}) is NOT the same!"
			_checksumVerification='FAILED'
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files on tmp and prm is the same for ${_project}/${_run}: ${_countFilesProjectRunDirPrm}."
			#
			# Verify checksums on prm storage.
			#
			local _checksumVerification='unknown'
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Started verification of checksums by ${DATA_MANAGER}@${HOSTNAME_PRM} using checksums from ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5."
			_checksumVerification=$(ssh ${DATA_MANAGER}@${HOSTNAME_PRM} "
				cd ${PRM_ROOT_DIR}/projects/${_project}
				if md5sum -c ${_run}.md5 > ${_run}.md5.log 2>&1
				then
					echo 'PASS'
				else
					echo 'FAILED'
				fi
			")
		fi
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
		if [[ "${_checksumVerification}" == 'FAILED' ]]
		then
			mv "${_controlFileBase}."{started,failed}
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details." \
				>> "${_controlFileBase}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details."
		elif [[ "${_checksumVerification}" == 'PASS' ]]
		then
			#
			# Add new status info to *.started file and
			# then move the *.started file to *.finished.
			# (Note: the content of *.finished will get inserted in the body of email notification messages,
			# when enabled in <group>.cfg for use by notifications.sh)
			#
			echo "The results can be found in: ${PRM_ROOT_DIR}." >> "${_controlFileBase}.started"
			echo "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details." \
				>>    "${_controlFileBase}.started" \
				&& rm -f "${_controlFileBase}.failed" \
				&& mv "${_controlFileBase}."{started,finished}
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
		fi
	fi

	#
	# Report status to track & trace.
	#
	if [[ -e "${_controlFileBase}.failed" ]]; then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_controlFileBase}.failed. Setting track & trace state to failed :(."
		_url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
		printf '%s\n' "project,run_id,pipeline,url,copy_results_prm,date"  > "${_controlFileBase}.trackAndTrace.csv"
		printf '%s\n' "${_project},${_project},DNA,${_url},failed,"       >> "${_controlFileBase}.trackAndTrace.csv"
		trackAndTracePostFromFile 'status_projects' 'update'            "${_controlFileBase}.trackAndTrace.csv"
	elif [[ -e "${_controlFileBase}.finished" ]]; then
		echo "Project/run ${_project}/${_run} is ready. The data is available at ${PRM_ROOT_DIR}/projects/." \
			>> "${_controlFileBase}.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_controlFileBase}.finished. Setting track & trace state to finished :)."
		_url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
		printf '%s\n' "project,run_id,pipeline,url,copy_results_prm,date"  > "${_controlFileBase}.trackAndTrace.csv"
		printf '%s\n' "${_project},${_project},${_sampleType},${_url},finished,"     >> "${_controlFileBase}.trackAndTrace.csv"
		trackAndTracePostFromFile 'status_projects' 'update'            "${_controlFileBase}.trackAndTrace.csv"
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' 'Ended up in unexpected state:'
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected either ${_controlFileBase}.finished or ${_controlFileBase}.failed, but both are absent."
	fi
}

function archiveSampleSheet() {
	local _project="${1}"
	local _run="${2}"
	
	local _controlFileDir="${TMP_ROOT_DIR}/logs/${_project}"
	#
	# Check if rsync of results of all runs for this project have finished successfully.
	#
	_rsyncControlFileBase="${TMP_ROOT_DIR}/logs/${_project}/${_run}.${SCRIPT_NAME}"
	
	if [ -f "${_rsyncControlFileBase}.finished" ]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${project} samplesheet already archived"
		return
	fi
	local  _startedCount=$(ls -1 "${_controlFileDir}/"*".${SCRIPT_NAME}.started" 2>/dev/null | wc -l)
	local   _failedCount=$(ls -1 "${_controlFileDir}/"*".${SCRIPT_NAME}.failed"  2>/dev/null | wc -l)
	local _finishedCount=$(ls -1 "${_controlFileDir}/"*".${SCRIPT_NAME}.finished" 2>/dev/null | wc -l)

	if [[ ${_startedCount} -eq 0 && ${_failedCount} -eq 0 && ${_finishedCount} -gt 0 ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Archiving sample sheet for ${_project}..."
	else
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "Not archiving sample sheet for ${_project}, because some runs have not yet finished (successfully)."
		return
	fi
	log4Bash 'DEBUG' ${LINENO} "${FUNCNAME:-main}" 0 \
		"ssh ${DATA_MANAGER}@${HOSTNAME_PRM} mv ${PRM_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT} ${PRM_ROOT_DIR}/Samplesheets/archive/"
	local _status=$(ssh ${DATA_MANAGER}@${HOSTNAME_PRM} "mv ${PRM_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT} ${PRM_ROOT_DIR}/Samplesheets/archive/" 2>&1)
	log4Bash 'DEBUG' ${LINENO} "${FUNCNAME:-main}" 0 "STATUS: ${_status}"
	if [[ "${_status}" == *"cannot stat"* ]]
	then
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" 0 "Failed to move ${_project}.${SAMPLESHEET_EXT} to ${HOSTNAME_PRM}:${PRM_ROOT_DIR}/Samplesheets/archive folder: ${_status}"
		touch "${_rsyncControlFileBase}.failed"
	else
		log4Bash 'DEBUG' ${LINENO} "${FUNCNAME:-main}" 0 "Moved ${_project}.${SAMPLESHEET_EXT} to ${HOSTNAME_PRM}:${PRM_ROOT_DIR}/Samplesheets/archive folder."
		touch "${_rsyncControlFileBase}.finished"
	fi
}

function getSampleType(){
	local  _sampleSheet="${1}"
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()
	declare    sampleType='DNA' # Default when not specified in sample sheet.
	declare    sampleTypeFieldIndex
	IFS="${SAMPLESHEET_SEP}" sampleSheetColumnNames=($(head -1 "${_sampleSheet}"))
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
		sampleTypesCount=$(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}" | sort | uniq | wc -l)
		if [[ "${sampleTypesCount}" -eq '1' ]]
		then
			sampleType=$(tail -n 1 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}")
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found sampleType: ${sampleType}."
			echo ${sampleType}
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} contains multiple different sampleType values."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${project} due to error in sample sheet."
			continue
		fi
	else

		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType column missing in sample sheet; will use default value: ${sampleType}."
		echo ${sampleType}
	fi
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
while getopts "g:l:hn" opt
do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
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
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -n "${dryrun:-}" ]]
then
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
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
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
# Load hashdeep.
#
module load hashdeep/${HASHDEEP_VERSION} || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} 'Failed to load hashdeep module.'
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "$(module list)"

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
#  4. Recursively restrict access to the ~/.ssh dir to allow only the owner/user:
#		chmod -R go-rwx ~/.ssh
#

#
# Get a list of all projects for this group, loop over their run analysis ("run") sub dirs and check if there are any we need to rsync.
#
declare -a projects=($(find "${TMP_ROOT_DIR}/projects/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_ROOT_DIR}/projects/||"))
if [[ "${#projects[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_ROOT_DIR}/projects."
else
	for project in "${projects[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project}..."
		declare -a runs=($(find "${TMP_ROOT_DIR}/projects/${project}/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_ROOT_DIR}/projects/${project}/||"))
		if [[ "${#runs[@]:-0}" -eq '0' ]]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found for project ${project}."
		else
			for run in "${runs[@]}"
			do
				sampleType=$(getSampleType ${TMP_ROOT_DIR}/projects/${project}/${run}/jobs/${project}.${SAMPLESHEET_EXT})
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType =${sampleType}"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project}/${run}..."
				rsyncProjectRun "${project}" "${run}" "${sampleType}"
				archiveSampleSheet "${project}" "${run}" "${sampleType}"
			done
		fi
	done
fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0
