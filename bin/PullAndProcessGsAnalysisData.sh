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

	_numberOfSamplesheets=$(find "${TMP_ROOT_DIR}/tmp/${_batch}/" -maxdepth 1 -mindepth 1 -name 'CSV_UMCG_*.'"${SAMPLESHEET_EXT}" 2>/dev/null | wc -l)
	if [[ "${_numberOfSamplesheets}" -eq 1 ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found: one ${TMP_ROOT_DIR}/tmp/${_batch}/CSV_UMCG_*.${SAMPLESHEET_EXT} samplesheet."
		local _gsSampleSheet
		_gsSampleSheet=$(ls -1 "${TMP_ROOT_DIR}/tmp/${_batch}/CSV_UMCG_"*".${SAMPLESHEET_EXT}")
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
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to convert line end characters and/or remove empty lines for ${_gsSampleSheet}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}

	elif [[ "${_numberOfSamplesheets}" -gt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "More than one CSV_UMCG_*.${SAMPLESHEET_EXT} GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	elif [[ "${_numberOfSamplesheets}" -lt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi

	#
	# Count Bam/gVCF files present on disk 
	#
	
	local _countSamplesInSamplesheet
	local _countBamFilesOnDisk
	local _countgVcfFilesOnDisk

	_countSamplesInSamplesheet=$(grep -o "${_batch}-[0-9][0-9]*" "${_gsSamplesheet}" | sort -u | wc -l)
	_countBamFilesOnDisk=$(find "${TMP_ROOT_DIR}/tmp/${_batch}/" -maxdepth 2 -mindepth 2 -name '*bam' | wc -l)
	_countgVcfFilesOnDisk=$(find "${TMP_ROOT_DIR}/tmp/${_batch}/" -maxdepth 1 -mindepth 1 -name '*.gvcf.gz' | wc -l)
	if [[ "${_countBamFilesOnDisk}" -ne "${_countSamplesInSamplesheet}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Amount bam files (${_countBamFilesOnDisk}) is not the same as the number of lines in the samplesheet ${_countSamplesInSamplesheet} (${_countSamplesInSamplesheet})."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	if [[ "${_countgVcfFilesOnDisk}" -ne "${_countSamplesInSamplesheet}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Amount gVCF files (${_countgVcfFilesOnDisk}) is not the same as the number of lines in the samplesheet ${_countSamplesInSamplesheet} (${_countSamplesInSamplesheet})."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi

	for i in "${TMP_ROOT_DIR}/tmp/${_batch}/*/"
	do
		cd "${i}"  
		for j in "${i}/"*".md5sum" 
		do 
			filename=$(basename ${j%.md5sum})
			awk -v filename="${filename}" '{print $0  ""filename}' "${j}" > "${i}/${filename}.md5"
			
			_checksumVerification=$(cd "${TMP_ROOT_DIR}/${_batch}/"
				if md5sum -c "${i}/${filename}.md5" >> "${_controlFileBaseForFunction}.started" 2>&1
				then
					echo 'PASS'
					touch "${_controlFileBaseForFunction}.md5.PASS"
				else
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Checksum verification failed. See ${_controlFileBaseForFunction}.failed for details."
					mv "${_controlFileBaseForFunction}."{started,failed}
					return
				fi
			)
		done
		cd -
	done

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
Script to pull data from a Data Staging (DS) server.

Usage:
	$(basename "${0}") OPTIONS
Options:
	-h	Show this help.
	-g	Group.
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
while getopts ":g:s:l:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		s)
			sourceGroup="${OPTARG}"
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
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -z "${sourceGroup:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a source group with -s.'
fi


#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	#"${HOME}/molgenis.cfg" Pull data from a DS server is currently not monitored using a Track & Trace Molgenis.
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
logTimeStamp="$(date "+%Y-%m-%d")"
logDir="${TMP_ROOT_DIR}/logs/${logTimeStamp}/"
# shellcheck disable=SC2174
mkdir -m 2770 -p "${logDir}"
touch "${logDir}"
export JOB_CONTROLE_FILE_BASE="${logDir}/${logTimeStamp}.${SCRIPT_NAME}"

#
# To make sure a *.finished file is not rsynced before a corresponding data upload is complete, we
# * first rsync everything, but with an exclude pattern for '*.finished' and
# * then do a second rsync for only '*.finished' files.
#
# shellcheck disable=SC2153
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Pulling data from data staging server ${HOSTNAME_DATA_STAGING%%.*} using rsync to /groups/${GROUP}/${TMP_LFS}/ ..."
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "See ${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log for details ..."
declare -a gsBatchesSourceServer

##only get directories from /home/umcg-ndewater/files/
readarray -t gsBatchesSourceServer< <(rsync -f"+ */" -f"- *" "${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/" | awk '{if ($5 != "" && $5 != "."){print $5}}')
if [[ "${#gsBatchesSourceServer[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/"
else
	for gsBatch in "${gsBatchesSourceServer[@]}"
	do
		gsBatch="$(basename "${gsBatch}")"
		if [[ -e "/groups/${GROUP}/${TMP_LFS}/logs/${gsBatch}/${gsBatch}.processGsAnalysisData.finished" ]]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${gsBatch} already processed, no need to transfer the data again."
		else
			#
			# Check if gsBatch is supposed to be complete (*.finished present).
			#
			gsBatchUploadCompleted='false'
			if rsync "${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished" 2>/dev/null
			then
				readarray -t testForEmptyDir < <(${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/${gsBatch}/)
				if [[ "${#testForEmptyDir[@]}" -gt 2 ]]
				then
				gsBatchUploadCompleted='true'
				logTimeStamp=$(date '+%Y-%m-%d-T%H%M')
				rsync "${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/${gsBatch}/Analysis/" \
					> "${logDir}/${gsBatch}.uploadCompletedListing_${logTimeStamp}.log"
				else
					log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${gsBatch}/ is empty, nothing to do."
					return
				fi
			fi
			#
			# Rsync everything except the *.finished file and except any "hidden" files starting with a dot
			# (which may be temporary files created by rsync and which we do not have permissions for):
			# this may be an incompletely uploaded batch, but we already rsync everything we've got so far.
			#
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing everything but the .finished file for ${gsBatch} ..."
			/usr/bin/rsync -vrltD \
				--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
				--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
				--omit-dir-times \
				--omit-link-times \
				--exclude='*.finished' \
				--exclude='.*' \
				"${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/${gsBatch}/Analysis/" \
				"/groups/${group}/${TMP_LFS}/tmp/"
			#
			# Rsync the .finished file last if the upload was complete.
			#
			if [[ "${gsBatchUploadCompleted}" == 'true' ]]
			then
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing only the .finished file for ${gsBatch} ..."
				/usr/bin/rsync -vrltD \
					--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
					--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
					--omit-dir-times \
					--omit-link-times \
					"${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished" \
					"/groups/${group}/${TMP_LFS}/tmp/${gsBatch}/"
				
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing only the CSV_UMCG samplesheet file for ${gsBatch} to ${destinationGroup}..."
				/usr/bin/rsync -vrltD \
					--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
					--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
					--omit-dir-times \	
					--omit-link-times \
					"${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/${gsBatch}/${rawdataFolder}/CSV_UMCG_"*".csv" \
					"/groups/${group}/${TMP_LFS}/tmp/${gsBatch}/"
			else
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No .finished file for ${gsBatch} present yet: nothing to sync."
			fi
			
			#
			# Step 1: Sanity Check if transfer of raw data has finished.
			#
			if [[ -e "${TMP_ROOT_DIR}/tmp/${gsBatch}/${gsBatch}.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/tmp/${gsBatch}/${gsBatch}.finished present -> Data transfer completed; let's process batch ${gsBatch}..."
				sanityChecking "${gsBatch}" "${controlFileBase}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/tmp/${gsBatch}/${gsBatch}.finished absent -> Data transfer not yet completed; skipping batch ${gsBatch}."
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Data transfer not yet completed; skipping batch ${gsBatch}."
				continue
			fi
			
		fi
	done
fi

#
# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0
