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
	_numberOfSamplesheets=$(find "${TMP_ROOT_DIR}/${_batch}/" -maxdepth 1 -mindepth 1 -name 'CSV_UMCG_*.'"${SAMPLESHEET_EXT}" 2>/dev/null | wc -l)
	
	if [[ "${_numberOfSamplesheets}" -eq 1 ]]
	then
		local _gsSampleSheet
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found: one ${TMP_ROOT_DIR}/${_batch}/CSV_UMCG_*.${SAMPLESHEET_EXT} samplesheet."
		_gsSampleSheet=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/CSV_UMCG_"*".${SAMPLESHEET_EXT}")	
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
		#
		# Continue with converted samplesheet.
		#
		_gsSampleSheet="${_gsSampleSheet}.converted"
		
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

	_countSamplesInSamplesheet=$(grep -o "${_batch}-[0-9][0-9]*" "${_gsSampleSheet}" | sort -u | wc -l)
	_countBamFilesOnDisk=$(find "${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/" -maxdepth 2 -mindepth 2 -name '*bam' | wc -l)
	_countgVcfFilesOnDisk=$(find "${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/" -maxdepth 2 -mindepth 2 -name '*.gvcf.gz' | wc -l)
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

	#
	# get list of sampleFolders
	#
	mapfile -t _sampleFolders < <(find "${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/" -maxdepth 1 -mindepth 1 -type d)
	if [[ "${#_sampleFolders[@]}" -eq '0' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "There is no data in ${TMP_ROOT_DIR}/${_batch}/${analysisFolder}/"
		return
	fi
	local _sampleFolder 
	for _sampleFolder in "${_sampleFolders[@]}"
	do
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${_sampleFolder}"
		mapfile -t _checksumFiles < <(find "${_sampleFolder}/" -name '*.md5sum' )
		if [[ "${#_checksumFiles[@]}" -eq '0' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No checksum files (.md5sum) found in ${_sampleFolder}/"
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
			cd "${_sampleFolder}/"
			if md5sum -c "${_filename}.md5" >> "${_controlFileBaseForFunction}.started" 2>&1
			then
				echo 'PASS'
				touch "${_controlFileBaseForFunction}.md5.PASS"
			else
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Checksum verification failed. See ${_controlFileBaseForFunction}.failed for details."
				mv "${_controlFileBaseForFunction}."{started,failed}
				return
			fi
			cd -
		done
	done
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
}
function mergeSamplesheets(){
	
	local _batch="${1}"
	local _controlFileBase="${2}"
	local _dataType="${3}"
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
	
	csvFile=$(ls -1 "${TMP_ROOT_DIR}/${gsBatch}/CSV_UMCG_"*".csv")

	# Combine samplesheets 
	mapfile -t uniqProjects< <(awk 'BEGIN {FS=","}{if (NR>1){print $2}}' "${csvFile}" | awk 'BEGIN {FS="-"}{print $1"-"$2}' | sort -V  | uniq)
	teller=0
	local _projectName
	for i in "${uniqProjects[@]}"
	do
		if [[ "${teller}" -eq '0' ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Creating new combined samplesheet for the processing of the Analysis data"
			#Renaming samplesheet to solely the GS_XX (e.g. GS_182.. so without the A,B,C etc suffix)
			_projectName=$(echo "${i}" | grep -Eo GS_[0-9]+)
			# create a combined samplesheet header, renamed project to originalproject and added new project column
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "new samplesheet name: ${_projectName}.csv"
			head -1 "${TMP_ROOT_DIR}/Samplesheets/${i}.csv" | perl -p -e 's|project|originalproject|' | awk '{print $0",project,gsBatch"}' > "${TMP_ROOT_DIR}/${_batch}/${_projectName}.csv"
			teller=$((${teller}+1))
		else
			tail -n+2 "${TMP_ROOT_DIR}/Samplesheets/${i}.csv" >> "${TMP_ROOT_DIR}/${_batch}/${_projectName}.csv"
		fi
	done
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Adding projectName ${_projectName} and gsBatch:${gsBatch} to the samplesheet and put the samplesheet ${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/${_projectName}.csv"
	
	awk -v projectName="${_projectName}" -v gsBatch="${_batch}" '{if (NR==1){print $0}else{print $0","projectName","gsBatch}}' "${TMP_ROOT_DIR}/${_batch}/${_projectName}.csv" > "${TMP_ROOT_DIR}/Samplesheets/NGS_DNA/${_projectName}.csv"
	rm "${TMP_ROOT_DIR}/${_batch}/${_projectName}.csv"
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
while getopts ":g:l:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
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

##
log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "HOSTNAME: ${HOSTNAME_DATA_STAGING}"
if rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::"
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "server is up"
	server='up'
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "server is down"
	server='down'
fi

#
##
### Get Analysis data 
##
#
if [[ "${server}" == 'up' ]]	
then
	readarray -t gsBatchesSourceServer< <(rsync -f"+ */" -f"- *" -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/" | awk '{if ($5 != "" && $5 != "." && $5 ~/-/){print $5}}')

	if [[ "${#gsBatchesSourceServer[@]}" -eq '0' ]]
	then
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/"
	else
		for gsBatch in "${gsBatchesSourceServer[@]}"
		do
			#
			# Process this batch.
			#
			gsBatch="$(basename "${gsBatch}")"
			controlFileBase="${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}"
			export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
			#
			# ToDo: change location of log files back to ${TMP_ROOT_DIR} once we have a 
			#       proper prm mount on the GD clusters and this script can run a GD cluster
			#       instead of on a research cluster.
			#
			if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gsBatch} already processed, no need to transfer the data again."
				continue
			else
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing pulling analysis batch ${gsBatch}..."
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${gsBatch}/"
				printf '' > "${JOB_CONTROLE_FILE_BASE}.started"

				#
				# Check if gsBatch is supposed to be complete (*.finished present).
				#
				gsBatchUploadCompleted='false'
				if rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished" 2>/dev/null
				then
					readarray -t testForEmptyDir < <(rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/")
					if [[ "${#testForEmptyDir[@]}" -gt 2 ]]
					then
						gsBatchUploadCompleted='true'
						logTimeStamp=$(date '+%Y-%m-%d-T%H%M')
						rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${analysisFolder}/" \
						> "${logDir}/${gsBatch}.uploadCompletedListing_${logTimeStamp}.log"
					else
						log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${gsBatch}/ is empty, nothing to do."
						continue
					fi
				else
					log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished does not exist"
					continue
				fi
				# First parse samplesheet to see where the data should go
			#	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing only the CSV_UMCG samplesheet file for ${gsBatch} to ${group}..."
		#		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${rawdataFolder}/CSV_UMCG_*.csv"
			#	/usr/bin/rsync -e 'ssh -p 443' -vrltD \
		#			"${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${rawdataFolder}/CSV_UMCG_"*".csv" \
		#			"${TMP_ROOT_DIR}/${gsBatch}/"
				
				rsyncData "${gsBatch}" "${controlFileBase}" "${analysisFolder}"
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "rsyncing done"
			fi
		done
	fi
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "server is down, there will be no data transfer!"
fi

#
##
### process Analysis data
##
#
readarray -t gsBatches< <(rsync -f"+ */" -f"- *" "${TMP_ROOT_DIR}/" | awk '{if ($5 != "" && $5 != "." && $5 ~/-/){print $5}}')
if [[ "${#gsBatches[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${TMP_ROOT_DIR}/"
else
	for gsBatch in "${gsBatches[@]}"
	do
		gsBatch="$(basename "${gsBatch}")"
		controlFileBase="${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing process analysis batch ${gsBatch}..."
		
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gsBatch} already processed, no need process the data again."
			continue
		else
			# shellcheck disable=SC2174
			mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
			# shellcheck disable=SC2174
			mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${gsBatch}/"
			printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
			if [[ -e "${controlFileBase}.${analysisFolder}_rsyncData.finished" ]]
			then
				if [[ -e "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished" ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished present -> Data transfer completed; let's process batch ${gsBatch}..."
					sanityChecking "${gsBatch}" "${controlFileBase}" "${analysisFolder}"
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished absent -> Data transfer not yet completed; skipping batch ${gsBatch}."
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Data transfer not yet completed; skipping batch ${gsBatch}."
					break
				fi
				if [[ -e "${controlFileBase}.${analysisFolder}_sanityChecking.finished" ]]
				then
					mergeSamplesheets "${gsBatch}" "${controlFileBase}" "${analysisFolder}"
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.sanityChecking.finished absent -> sanityChecking failed."
				fi
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${analysisFolder}_rsyncData.finished absent, waiting for ${gsBatch} to finish rsyncing before starting to sanity check"
				break
			fi
		fi
		if [[ -e "${controlFileBase}.${analysisFolder}_mergeSamplesheets.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.mergeSamplesheets.finished present -> processing completed for batch ${gsBatch}..."
			rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing batch ${gsBatch}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.mergeSamplesheets.finished absent -> processing failed for batch ${gsBatch}."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process batch ${gsBatch}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		fi
	done
fi

if [[ "${CLEANUP}" == "false" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "this is a testgroup, data should not be removed"
else
	#
	# Cleanup old data if data transfer with rsync finished successfully (and hence did not crash this script).
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Deleting data that has been processed completely"
	#
	# Get the batch name by parsing the ${GENOMESCAN_HOME_DIR} folder, directories only and no empty or '.'
	#
	readarray -t gsBatchesSourceServer< <(rsync -f"+ */" -f"- *" -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}" | awk '{if ($5 != "" && $5 != "."){print $5}}')
	if [[ "${#gsBatchesSourceServer[@]}" -eq '0' ]]
	then
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/"
	else
		for gsBatch in "${gsBatchesSourceServer[@]}"
		do
			gsBatch="$(basename "${gsBatch}")"
			controlFileBase="${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.${SCRIPT_NAME}_cleanup"
			if [[ -f "${TMP_ROOT_DIR}/logs/${gsBatch}.PullAndProcessGsAnalysisData.finished" ]]
			then
				touch "${controlFileBase}.started"
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Pulling data and Preprocessing of ${gsBatch} has been finished, removing Analysis data from the datastaging server: ${HOSTNAME_DATA_STAGING}"
				#
				# Create an empty dir (source dir) to sync with the destination dir && then remove source dir.
				#
				##
				### Enable and execute this once it is tested properly
				##
				#
				#mkdir -p "${HOME}/empty_dir/"
				#if rsync -a --delete "${HOME}/empty_dir/" "${HOSTNAME_DATA_STAGING}:${GENOMESCAN_HOME_DIR}/${gsBatch}/Analysis"
				#then
				#	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully removed ${gsBatch}/Analysis from ${HOSTNAME_DATA_STAGING}"
				#	rmdir "${HOME}/empty_dir/"
				#else
				# log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "An error occured while removing ${gsBatch}/Analysis from ${HOSTNAME_DATA_STAGING}"
				# mv "${controlFileBase}".{started,failed}
				#fi
				mv "${controlFileBase}".{started,finished}
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "the processing of batch ${gsBatch} is not yet finished"
			fi
		done
	fi
fi

#
# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0
