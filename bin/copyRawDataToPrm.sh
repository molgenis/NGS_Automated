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
	trap - EXIT
	exit 1
fi

function rsyncDemultiplexedRuns() {

	local _run="${1}"

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_run}..."
	local _log_file="${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.log"

	mkdir -p "${PRM_ROOT_DIR}/logs/${_run}/"
	mkdir -p "${PRM_ROOT_DIR}/rawdata/ngs/${_run}"

	#
	# Determine whether an rsync is required for this run, which is the case when
	#  1. either the runs has finished and this copy script has not
	#  2. or when a pipeline has updated the results after a previous execution of this script. 
	#
	# Temporarily check for "${TMP_ROOT_DIR}/logs/${_run}/${_run}.pipeline.finished"

	local _runFinished='false'
	local _rsyncRequired='false'
	local _demultiplexingFinishedFile="${PRM_ROOT_DIR}/logs/${_run}/${_run}.copyRawDataToPrm.sh.finished"

	# check if demultiplexing was finished
		
	#log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${gattacaAddress}" "test -e ${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished"
	
	#ssh "${DATA_MANAGER}@${gattacaAddress}" test -f "${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished" \
		
	if ssh ${DATA_MANAGER}@${gattacaAddress} test -e "${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished"
	then
		_runFinished='true'
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' " ${DATA_MANAGER}@${gattacaAddress} ${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished present."
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' " ${DATA_MANAGER}@${gattacaAddress} ${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished not present."
		_runFinished='false'
		continue	
	fi
	
	
	
	if [[ -f "${PRM_ROOT_DIR}/logs/${_run}/${_run}.copyRawDataToPrm.sh.finished" ]] 
	then
		_runFinished='true'
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' " ${_run}.copyRawDataToPrm.sh.finished present."
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' " ${_run}.copyRawDataToPrm.sh.finished not present."
	fi
	
	if [[ "${_runFinished}" == 'true' ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Demultiplexing finished = ${_runFinished}."
		
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "check if ${_run}_Demultiplexing.finished is newer than ${_demultiplexingFinishedFile}"
		rsync -a ${DATA_MANAGER}@${gattacaAddress}:${SCR_ROOT_DIR}/logs/${_run}_Demultiplexing.finished ${_demultiplexingFinishedFile}.${GAT}
				
		# check if ${_run}_Demultiplexing.finished is newer than ${_demultiplexingFinishedFile}
		if [[ "${_demultiplexingFinishedFile}" -nt "${_demultiplexingFinishedFile}.${GAT}" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "*.dataCopiedToPrm newer than *.${_run}_Demultiplexing.finished."
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "*.dataCopiedToPrm older than *.${SCRIPT_NAME}.finished."
			_rsyncRequired='true'
		fi
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No {PRM_ROOT_DIR}/logs/${_run}/${_run}.dataCopiedToPrm present."
		_rsyncRequired='true'
	fi
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsync required = ${_rsyncRequired}."

	# skip if nothing needs to be done.
	if [[ "${_rsyncRequired}" == 'false' ]]; then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_run}."
		continue
	fi



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
	rsync -av --chmod=Dg-w,g+rsX,o-rwx,Fg-wsx,g+r,o-rwx ${dryrun:-} \
		"${DATA_MANAGER}@${gattacaAddress}:${SCR_ROOT_DIR}/runs/${_run}/results/*" \
			"${PRM_ROOT_DIR}/rawdata/ngs/${_run}/" \
				>> "${_log_file}" 2>&1 \
	|| {
	log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync {gattacaAddress}:${SCR_ROOT_DIR}/runs/${_run} dir. See ${_log_file} for details."
	echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_log_file} for details." \
		>> "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed"
	_transferSoFarSoGood='false'
	}

	#
	# rsync samplesheet to prm samplesheets folder
	#
	rsync -av ${dryrun:-} \
		"${DATA_MANAGER}@${gattacaAddress}:${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT}" \
			"${PRM_ROOT_DIR}/Samplesheets/" \
				>> "${_log_file}" 2>&1 \
	|| {
	log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${SCR_ROOT_DIR}/Samplesheets/${_run}.${SAMPLESHEET_EXT} dir. See ${_log_file} for details."
	echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_log_file} for details." \
		>> "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed"
	_transferSoFarSoGood='false'
	}

	#
	#fix permissions
	#
	#chmod -R g-w,g+r,o-rwx,g+r,o-rwx "${PRM_ROOT_DIR}/rawdata/ngs/${_run}"
	#chmod g-w,g+r,o-rwx,g+r,o-rwx,u-x,u-x "${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}*"

	#
	# Sanity check.
	#
	#  1. Firstly do a quick count of the amount of files to make sure we are complete.
	#     (No need to waist a lot of time on computing checksums for a partially failed transfer).
	#  2. Secondly verify checksums on the destination.
	#
	if [[ "${_transferSoFarSoGood}" == 'true' ]];then
		local _countFilesDemultiplexRunDirScr=$(ssh ${DATA_MANAGER}@${gattacaAddress} "find ${SCR_ROOT_DIR}/runs/${_run}/ -type f | wc -l")
		local _countFilesDemultiplexRunDirPrm=$(find "${PRM_ROOT_DIR}/rawdata/ngs/${_run}/" -type f | wc -l)
		if [[ ${_countFilesDemultiplexRunDirScr} -ne ${_countFilesDemultiplexRunDirPrm} ]]; then
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_run} on scr (${_countFilesDemultiplexRunDirScr}) and prm (${_countFilesDemultiplexRunDirPrm}) is NOT the same!" \
				>> "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files for ${_run} on tmp (${_countFilesDemultiplexRunDirScr}) and prm (${_countFilesDemultiplexRunDirPrm}) is NOT the same!"
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files on tmp and prm is the same for ${_run}: ${_countFilesDemultiplexRunDirPrm}."
			
			#
			# Verify checksums on prm storage.
			#
			local _checksumVerification='unknown'
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Started verification of checksums by ${DATA_MANAGER}@${gattacaAddress} using checksums from ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/*.md5."
			_checksumVerification=$(cd ${PRM_ROOT_DIR}/rawdata/ngs/${_run}
			if md5sum -c *.md5 > ${PRM_ROOT_DIR}/logs/${_run}/${_run}.md5.log 2>&1
			then
				echo 'PASS'
			else
				echo 'FAILED'
			fi
			)
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
			 	
			if [[ "${_checksumVerification}" == 'FAILED' ]]; then
				echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}.md5.log for details." \
					>> "${TMP_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed"
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}.md5.log for details."
			elif [[ "${_checksumVerification}" == 'PASS' ]]; then
				echo "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}.md5.log for details." \
					>>    "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed" \
					&& mv "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}."{failed,finished}
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
			else
				log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Got unexpected result from checksum verification:'
				log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected FAILED or PASS, but got: ${_checksumVerification}."
			fi
		fi
	fi


	#
	# Send e-mail notification.
	#
		
	if [[ -f "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed" ]]; then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if ${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed exists."
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if ${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed.mailed exists."
		local _message1="MD5 checksum verification failed for ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}:"
		local _message2="The data is corrupt or incomplete. The original data is located at ${gattacaAddress}:${SCR_ROOT_DIR}/runs/${_run}/."
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message1}"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message2}"
		if [[ "${email}" == 'true' \
				&&  $(cat "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed" | wc -l) -ge 10 \
				&& ! -f "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed.mailed" ]]; then
			printf '%s\n%s\n' \
				"${_message1}" \
				"${_message2}" \
				| mail -s "Failed to copy ${_run} to permanent storage." "${EMAIL_TO}"
			touch "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed.mailed"
		fi
	elif [[ -f "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.finished" ]]; then
		local _message1="run ${_run} is ready. The data is available at ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/."
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${_message1}"
		
				
		if [[ "${email}" == 'true' ]]; then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Try to mail to ${EMAIL_TO}"
			
			if ls ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}*.log 1> /dev/null 2>&1
			then
				local _logFileStatistics=$(cat ${PRM_ROOT_DIR}/rawdata/ngs/${_run}/${_run}*.log)
			else
				local _logFileStatistics="Not present."
			fi
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "MAIL: Run ${_run} was successfully copied to permanent storage. Demultiplex statistics: ${_logFileStatistics}"
			_message1="Run ${_run} was successfully copied to permanent storage.\nDemultiplex statistics:\n\n ${_logFileStatistics}"
			echo -e "${_message1}" | mail -s "Run ${_run} was successfully copied to permanent storage" "${EMAIL_TO}"
				touch "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}.failed.mailed" \
				&& mv "${PRM_ROOT_DIR}/logs/${_run}/${_run}.${SCRIPT_NAME}."{failed,finished}.mailed
		fi
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Ended up in unexpected state:'
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected either ${SCRIPT_NAME}.finished or ${SCRIPT_NAME}.failed, but both files are absent."
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
	-s   Source of the tmpData, must be gattaca01 or gattaca02
	
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
declare sourceServer=''
while getopts "g:l:s:hen" opt; do
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
			sourceServer="${OPTARG}"
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

#log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${sourceServer}"

#
# Check commandline options.
#
if [[ -z "${group:-}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -z "${sourceServer:-}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a sourceServer with -s.'
fi
if [[ -n "${dryrun:-}" ]]; then
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
)
for configFile in "${configFiles[@]}"; do 
	if [[ -f "${configFile}" && -r "${configFile}" ]]; then
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
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."





#
# Get a list of all  for this group, loop over their run analysis ("run") sub dirs and check if there are any we need to rsync.
#

GAT="${sourceServer}"
gattacaAddress="${GAT}.gcc.rug.nl"


### VERVANG DOOR UMCG-ATEAMBOT USER
ssh ${DATA_MANAGER}@${gattacaAddress} "ls ${SCR_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT}" > ${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_${HOSTNAME_SHORT}.txt

trap finish HUP INT QUIT TERM EXIT ERR

declare -a runs=()
while read i
do
runs+=($i)
done<${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_${HOSTNAME_SHORT}.txt


if [[ "${#runs[@]:-0}" -eq '0' ]] 
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found @ ${TMP_ROOT_DIR}/runs."
else
	for csvFile  in "${runs[@]}"
	do
		run=$(basename ${csvFile%.*})
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${run}..."
		rsyncDemultiplexedRuns "${run}"
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0






