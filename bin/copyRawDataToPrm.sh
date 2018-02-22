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

function contains() {
	local n=$#
	local value=${!n}
	for ((i=1;i < $#;i++)) {
		if [ "${!i}" == "${value}" ]; then
			echo "y"
			return 0
		fi
	}
	echo "n"
	return 1
}

function rsyncDemultiplexedRuns() {

	local _run="${1}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_run}..."
	#
	# ToDo: change location of job control files back to ${TMP_ROOT_DIR} once we have a 
	#       proper prm mount on the GD clusters and this script can run a GD cluster
	#       instead of on a research cluster.
	#
	#local _controlFileBase="${TMP_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}"
	local _controlFileBase="${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}"
	local _logFile="${_controlFileBase}.log"

	#
	# Determine whether an rsync is required for this run, which is the case when
	#  1. either the sequence run has finished successfully and this copy script has not
	#  2. or when a pipeline has updated the results after a previous execution of this script.
	#
	
	#
	# Check if production of raw data @ sourceServer has finished.
	#
	if ssh ${DATA_MANAGER}@${sourceServerFQDN} test -e "${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished"
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished present."
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished absent."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}."
		return
	fi

	if [[ -e "${_controlFileBase}.finished" ]]
	then
		#
		# Get modification times as integers (seconds since epoch) 
		# and check if *_Demultiplexing.finished is newer than *.dataCopiedToPrm,
		# which indicates the run was re-demultiplexed and converted to FastQ files.
		#
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if ${_run}_Demultiplexing.finished is newer than ${_controlFileBase}.finished"
		local _demultiplexingFinishedModTime=$(ssh ${DATA_MANAGER}@${sourceServerFQDN} stat --printf='%Y' "${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished")
		local _myFinishedModTime=$(stat --printf='%Y' "${_controlFileBase}.finished")

		if [[ "${_demultiplexingFinishedModTime}" -gt "${_myFinishedModTime}" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "*_Demultiplexing.finished newer than ${_controlFileBase}.finished."
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "*_Demultiplexing.finished older than ${_controlFileBase}.finished."
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}."
			return
		fi
	else

		mkdir -m 2750 -p "${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${_controlFileBase}.finished present."
	fi

	#
	# Track and Trace: log that we will start rsyncing to prm.
	#
	touch "${_controlFileBase}.started"
	printf '%s\n' "run_id,group,demultiplexing,copy_raw_prm,projects,date"  > "${_controlFileBase}.trackAndTrace.csv"
	printf '%s\n' "${_run},${group},finished,started,,"                    >> "${_controlFileBase}.trackAndTrace.csv"
	trackAndTracePostFromFile 'status_overview' 'update'                      "${_controlFileBase}.trackAndTrace.csv"

	#
	# Perform rsync.
	#  1. For ${_run} dir: recursively with "default" archive (-a),
	#     which checks for differences based on file size and modification times.
	#     No need to use checksums here as we will verify checksums later anyway.
	#  2. For *.md5 list of checksums with archive (-a) and -c to determine
	#     differences based on checksum instead of file size and modification time.
	#     It is vitally important (and computationally cheap) to make sure
	#     the list of checksums is complete and up-to-date!
	#
	# ToDo: Do we need to add --delete to get rid of files that should no longer be there
	#       if an analysis run got updated?
	#
	local _transferSoFarSoGood='true'
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_run} dir..."
	rsync -rav --chmod=Dg-w,g+rsX,o-rwx,Fg-wsx,g+r,o-rwx ${dryrun:-} \
		"${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/runs/${_run}/results/*" \
		"${PRM_ROOT_DIR}/rawdata/ngs/${_run}/" \
		>> "${_logFile}" 2>&1 \
	|| {
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${sourceServerFQDN}:${SCR_ROOT_DIR}/runs/${_run} dir. See ${_logFile} for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync of sequence run dir failed. See ${_logFile} for details." \
			>> "${_controlFileBase}.failed"
		_transferSoFarSoGood='false'
	}
	rsync -acv --chmod=Dg-w,g+rsX,o-rwx,Fg-wsx,g+r,o-rwx ${dryrun:-} \
		"${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/runs/${_run}/results/*.md5" \
		"${PRM_ROOT_DIR}/rawdata/ngs/${_run}/" \
		>> "${_logFile}" 2>&1 \
	|| {
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${sourceServerFQDN}:${SCR_ROOT_DIR}/runs/${_run}/*.md5. See ${_logFile} for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync of checksums failed. See ${_logFile} for details." \
			>> "${_controlFileBase}.failed"
		_transferSoFarSoGood='false'
	}

	#
	# Rsync samplesheet to prm samplesheets folder.
	#
	rsync -av ${dryrun:-} \
		"${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}" \
		"${PRM_ROOT_DIR}/Samplesheets/archive/" \
		>> "${_logFile}" 2>&1 \
	|| {
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}. See ${_logFile} for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync of sample sheet failed. See ${_logFile} for details." \
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
	if [[ "${_transferSoFarSoGood}" == 'true' ]];then
		local _countFilesDemultiplexRunDirScr=$(ssh ${DATA_MANAGER}@${sourceServerFQDN} "find ${SCR_ROOT_DIR}/runs/${_run}/results/${_run}* -type f | wc -l")
		local _countFilesDemultiplexRunDirPrm=$(find "${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}"* -type f | wc -l)
		if [[ ${_countFilesDemultiplexRunDirScr} -ne ${_countFilesDemultiplexRunDirPrm} ]]; then
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_run} on scr (${_countFilesDemultiplexRunDirScr}) and prm (${_countFilesDemultiplexRunDirPrm}) is NOT the same!" \
				>> "${_controlFileBase}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files for ${_run} on tmp (${_countFilesDemultiplexRunDirScr}) and prm (${_countFilesDemultiplexRunDirPrm}) is NOT the same!"
			_checksumVerification='FAILED'
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files on tmp and prm is the same for ${_run}: ${_countFilesDemultiplexRunDirPrm}."
			#
			# Verify checksums on prm storage.
			#
			local _checksumVerification='unknown'
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Started verification of checksums by ${DATA_MANAGER}@${sourceServerFQDN} using checksums from ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/*.md5."
			_checksumVerification=$(cd ${PRM_ROOT_DIR}/rawdata/ngs/${_run}
				if md5sum -c *.md5 > ${_controlFileBase}.md5.log 2>&1
				then
					echo 'PASS'
				else
					echo 'FAILED'
				fi
			)
		fi
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
		if [[ "${_checksumVerification}" == 'FAILED' ]]; then
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${_controlFileBase}.md5.log for details." \
				>> "${_controlFileBase}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${_controlFileBase}.md5.log for details."
		elif [[ "${_checksumVerification}" == 'PASS' ]]; then
			#
			# Overwrite any previously created *.failed file if present,
			# add new status info incl. demultiplex stats to *.failed file and
			# then move the *.failed file to *.finished.
			# (Note: the content of *.finished will get inserted in the body of email notification messages,
			# when enabled in <group>.cfg for use by notifications.sh)
			#
			echo "The results can be found in: ${PRM_ROOT_DIR}." > "${_controlFileBase}.failed"
			if ls "${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}"*.log 1>/dev/null 2>&1
			then
				cat "${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}"*.log >> "${_controlFileBase}.failed"
			fi
			echo "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${_controlFileBase}.md5.log for details." \
				>>    "${_controlFileBase}.failed" \
				&& mv "${_controlFileBase}."{failed,finished}
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
		fi
	fi

	#
	# Sanity check and report status to track & trace.
	#
	if [[ -e "${_controlFileBase}.failed" ]]; then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_controlFileBase}.failed. Setting track & trace state to failed :(."
		printf '%s\n' "run_id,group,demultiplexing,copy_raw_prm,projects,date"  > "${_controlFileBase}.trackAndTrace.csv"
		printf '%s\n' "${_run},${group},finished,failed,,"                     >> "${_controlFileBase}.trackAndTrace.csv"
		trackAndTracePostFromFile 'status_overview' 'update'                      "${_controlFileBase}.trackAndTrace.csv"
	elif [[ -e "${_controlFileBase}.finished" ]]; then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_controlFileBase}.finished. Setting track & trace state to finished :)."
		printf '%s\n' "run_id,group,demultiplexing,copy_raw_prm,projects,date"  > "${_controlFileBase}.trackAndTrace.csv"
		printf '%s\n' "${_run},${group},finished,finished,,"                   >> "${_controlFileBase}.trackAndTrace.csv"
		trackAndTracePostFromFile 'status_overview' 'update'                      "${_controlFileBase}.trackAndTrace.csv"
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' 'Ended up in unexpected state:'
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected either ${_controlFileBase}.finished or ${_controlFileBase}.failed, but both are absent."
	fi
}

function splitSamplesheetPerProject() {
	
	local _run="${1}"
	local _sampleSheet="${PRM_ROOT_DIR}/Samplesheets/archive/${_run}.${SAMPLESHEET_EXT}"
	#
	# ToDo: change location of job control files back to ${TMP_ROOT_DIR} once we have a 
	#       proper prm mount on the GD clusters and this script can run a GD cluster
	#       instead of on a research cluster.
	#
	#local _controlFileBase="${TMP_ROOT_DIR}/logs/${_run}/${_run}.splitSamplesheetPerProject"
	local _rsyncControlFileFinished="${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.finished"
	local _controlFileBase="${PRM_ROOT_DIR}/logs/${_run}/${_run}.splitSamplesheetPerProject"
	local _logFile="${_controlFileBase}.log"
	
	if [[ -e "${_controlFileBase}.finished" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_controlFileBase}.finished -> Skipping ${_run}."
		return
	elif [[ ! -e "${_rsyncControlFileFinished}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Not found ${_rsyncControlFileFinished} -> Skipping splitting ${_run}."
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${_controlFileBase}.finished present -> Splitting sample sheet per project for ${_run}..."
	fi
	
	#
	# Parse sample sheet to get a list of project values.
	#
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	declare -a _pipelines=()
	declare -a _demultiplexOnly=("n")
	
	IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_sampleSheet}"))
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	
	#
	# Check if the pipeline step can be skipped. 
	#
	if [[ ! -z "${_sampleSheetColumnOffsets['GCC_Analysis']+isset}" ]]; then
		_pipelineFieldIndex=$((${_sampleSheetColumnOffsets['GCC_Analysis']} + 1))
		_projectFieldIndex=$((${_sampleSheetColumnOffsets['project']} + 1))
		IFS=$'\n' _pipelines=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f ${_pipelineFieldIndex} | sort | uniq ))
		if [[ "${#_pipelines[@]:-0}" -lt '1' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} does not contain at least one pipeline value."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in sample sheet."
			touch "${_controlFileBase}.failed"
			return
		elif [[ "${#_pipelines[@]:-0}" -eq '1' ]]
		then
			for _pipeline in "${_pipelines[@]}"
			do
				_pipeline_to_upper_case=$(echo "${_pipeline}"| awk '{print toupper($0)}')
				if [[ "${_pipeline_to_upper_case}" = *"DEMULTIPLEXING ONLY"* ]]
				then
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing only."
					touch "${_controlFileBase}.finished"
					return
				fi
			done
		elif [[ "${#_pipelines[@]:-0}" -gt '1' ]]
		then
			for _pipeline in "${_pipelines[@]}"
			do
				_pipeline_to_upper_case=$(echo "${_pipeline}"| awk '{print toupper($0)}')
				if [[ "${_pipeline_to_upper_case}" == *"DEMULTIPLEXING ONLY"* ]]
				then
					IFS=$'\n' _demultiplexOnly=($(awk -F "${SAMPLESHEET_SEP}" "{if (NR>1 && \$${_pipelineFieldIndex} ~ /${_pipelines}/) {print}}" "${_sampleSheet}" |  awk "BEGIN{FS=\"${SAMPLESHEET_SEP}\"} {print \$${_projectFieldIndex}}" | sort -u))
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing only detected."
				fi
			done
		fi
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "GCC_Analysis column missing in sample sheet."
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Continue with ${_run} due to missing pipeline column."
	fi
	
	
	if [[ ! -z "${_sampleSheetColumnOffsets['project']+isset}" ]]; then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets['project']} + 1))
		IFS=$'\n' _projects=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sort | uniq ))
		if [[ "${#_projects[@]:-0}" -lt '1' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} does not contain at least one project value."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run} due to error in sample sheet."
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
	# Create sample sheet per project.
	#
	for _project in "${_projects[@]}"
	do
		#
		# Skip project if demultiplexing only.
		#
		if [ $(contains "${_demultiplexOnly[@]}" "${_project}") == "y" ]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing Only for project: ${_project}, continue"
			continue
		else
		#
		# ToDo: change location of sample sheet per project back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
		#local _projectSampleSheet="${TMP_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}"
		local _projectSampleSheet="${PRM_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}"
		head -1 "${_sampleSheet}" > "${_projectSampleSheet}.tmp"
		awk -F "${SAMPLESHEET_SEP}" \
			"{if (NR>1 && \$${_projectFieldIndex} ~ /${_project}/) {print}}" \
			"${_sampleSheet}" \
			>> "${_projectSampleSheet}.tmp"
		mv "${_projectSampleSheet}"{.tmp,}
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Created ${_projectSampleSheet}."
		fi
	done
	
	touch "${_controlFileBase}.finished"
}
#	mkdir -p "${PRM_ROOT_DIR}/logs/${_run}/tmp"
#	python samplesheetChecker.py "${PRM_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}" "${PRM_ROOT_DIR}/logs/${_run}/tmp/project.txt.tmp"
#	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "samplesheet splitted, now sorting"
#	sort "${PRM_ROOT_DIR}/logs/${_run}/tmp/project.txt.tmp" | uniq > "${PRM_ROOT_DIR}/logs/${_run}/tmp/project.txt"
#	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sorting done"
#	
#	CLUSTERS=()
#	
#	#
#	## Check which servers are up
#	#
#	for i in zinc-finger leucine-zipper
#	do
#		configFile="${CFG_DIR}/${i}.cfg"
#		mixed_stdouterr=$(source ${configFile} 2>&1) || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot source ${configFile}."
#		source ${configFile}
#		#log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "ssh -q ${HOSTNAME_TMP} ls /groups/${GROUP}/${TMP_LFS}/logs/production.ready"
#		#if ssh -q ${HOSTNAME_TMP} "ls /groups/${GROUP}/${TMP_LFS}/logs/production.ready"
#		#then
#		#	CLUSTERS+=("${HOST_ABBREVATION}")
#		#	mkdir -p "${PRM_ROOT_DIR}/Samplesheets/project_${HOST_ABBREVATION}"
#		#fi
#		#log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "ls /groups/${GROUP}/${PRM_LFS}/logs/${i}.production.ready"
#		if [ -f /groups/${GROUP}/${PRM_LFS}/logs/${i}.production.ready ]
#		then
#			CLUSTERS+=("${HOST_ABBREVATION}")
#			mkdir -p "${PRM_ROOT_DIR}/Samplesheets/project_${HOST_ABBREVATION}"
#		else
#			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${i} is not available for submitting jobs"
#		fi
#	done
#	if [ -z "${CLUSTERS:-}" ]
#	then
#		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '1' "there are no clusters available, exiting"
#		break
#	else
#		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "The available clusters are: ${CLUSTERS[@]}"
#	fi
#	## reloading original hostname configfile
#	source "${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
#	
#	cluster=""
#	count=1
#	
#	for project in $(awk '$1' "${PRM_ROOT_DIR}/logs/${_run}/tmp/project.txt")
#	do
#		if [[ $((count % 2)) == 0 ]]
#		then
#			if [[ ${#CLUSTERS[@]} == 2 ]]
#			then
#				cluster=${CLUSTERS[1]}
#			else
#				cluster=${CLUSTERS[0]}
#			fi
#		else
#			cluster=${CLUSTERS[0]}
#		fi
#		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
#			"${project} will be running on ${cluster}"
#		
#		extract_samples_from_GAF_list.pl --i "${PRM_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}" --o "${PRM_ROOT_DIR}/Samplesheets/project_${cluster}/${project}.csv" --c project --q "${project}"
#		perl -pi -e 's/\r(?!\n)//g' "${PRM_ROOT_DIR}/Samplesheets/project_${cluster}/${project}.csv"
#		
#		count=$((count+1))
#	done
#	touch "${PRM_ROOT_DIR}/logs/${_run}.samplesheetSplittedPerProject"

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
declare email='false'
declare dryrun=''
declare sourceServerFQDN=''
while getopts "g:l:s:hen" opt
do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		e)
			email='true'
			;;
		n)
			dryrun='-n'
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
#lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
#log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs..."

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
IFS=$'\n' sampleSheetsFromSourceServer=($(ssh ${DATA_MANAGER}@${sourceServerFQDN} "ls -1 ${SCR_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT}"))

if [[ "${#sampleSheetsFromSourceServer[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No sample sheets found for ${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT}."
else
	for sampleSheet in "${sampleSheetsFromSourceServer[@]}"
	do
		#
		# Process this sample sheet / run.
		#
		filePrefix="$(basename "${sampleSheet%.*}")"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${filePrefix}..."
		#
		# ToDo: change location of log files back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
		#mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${filePrefix}/"
		mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${filePrefix}/"
		mkdir -m 2750 -p "${PRM_ROOT_DIR}/Samplesheets/archive/"
		rsyncDemultiplexedRuns "${filePrefix}"
		splitSamplesheetPerProject "${filePrefix}"
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0

