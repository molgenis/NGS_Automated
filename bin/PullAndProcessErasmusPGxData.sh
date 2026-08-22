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
# shellcheck disable=SC2153
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Pulling data from data staging server ${HOSTNAME_DATA_STAGING} using rsync to /groups/${GROUP}/${TMP_LFS}/ ..."

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

GAP_HOME_DIR='groups/umcg-gap/'
#
##
### Get data 
##
#
if [[ "${server}" == 'up' ]]	
then
	readarray -t gapSourceServer< <(rsync -rv -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GAP_HOME_DIR}/" | awk '{if ($5 != "" && $5 != "." && $5 ~/D-/ && $5 ~ /tar$/){print $5}}')

	if [[ "${#gapSourceServer[@]}" -eq '0' ]]
	then
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${HOSTNAME_DATA_STAGING}::${GAP_HOME_DIR}/"
	else
		for gapBatchFile in "${gapSourceServer[@]}"
		do
			gapBatchFile="$(basename "${gapBatchFile}")"
			gapBatch=${gapBatchFile%%.*} 
			controlFileBase="${TMP_ROOT_DIR}/logs/${gapBatch}/${gapBatch}"
			export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"

			if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gapBatch} already processed, no need to transfer the data again."
				continue
			else

				logDir="${TMP_ROOT_DIR}/logs/${gapBatch}/"
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${logDir}"
				printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
				
				if rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GAP_HOME_DIR}/${gapBatchFile}.md5" 2>/dev/null
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "creating tmp folder"
					# shellcheck disable=SC2174
					mkdir -m 2770 -p "${TMP_ROOT_DIR}/tmp/AGCT/${gapBatch}"
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "copying ${gapBatchFile} to ${TMP_ROOT_DIR}/tmp/AGCT/${gapBatch}/"
					rsync -rv -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GAP_HOME_DIR}/${gapBatchFile}" "${TMP_ROOT_DIR}/tmp/AGCT/${gapBatch}/"
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "navigate to folder: ${TMP_ROOT_DIR}/tmp/AGCT/${gapBatch}/"
					cd "${TMP_ROOT_DIR}/tmp/AGCT/${gapBatch}/"
					
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "untar ${gapBatchFile}"
					tar -xvf "${gapBatchFile}"
					samplesheet=$(find . -name "D-*.csv")
					
					cp "${samplesheet}"{,.converted}
					printf '\n'     >> "${samplesheet}.converted"
					sed -i 's/\r/\n/g' "${samplesheet}.converted"
					sed -i "/^[\s,]*$/d" "${samplesheet}.converted"
					mv "${samplesheet}.converted" "${samplesheet}"

					awk '/Sample_Well/ {display=1} display {print}' "${samplesheet}" | awk '{ gsub (" ", "_", $0); print}' > "${gapBatch}.csv.tmp"
					awk 'BEGIN {FS=","}{if (NR==1){print $0",analysis,manifest,egt"}else{print $0",diagnostics,GSAMD-24v3-0-EA_20034606_A1.bpm,referentie_GSAMD_V3_20210115.egt"}}' "${gapBatch}.csv.tmp" > "${gapBatch}.csv.tmp2"
					
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "copying glaasjes directories to ${TMP_ROOT_DIR}/rawdata/array/IDAT/"
					find ./* -type d -exec rsync -rv {} "${TMP_ROOT_DIR}/rawdata/array/IDAT/" \;

					declare -a _sampleSheetColumnNames=()
					declare -A _sampleSheetColumnOffsets=()

					IFS="," read -r -a _sampleSheetColumnNames <<< "$(head -1 "${gapBatch}.csv.tmp2")"
					for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
					do
						_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
					done
					
					_projectFieldIndex=""
					if [[ -n "${_sampleSheetColumnOffsets["Project"]+isset}" ]]; 
					then
						_projectFieldIndex=$((${_sampleSheetColumnOffsets["Project"]} + 1))
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "does not exist!!!!"
					fi
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "projectFieldIndex=${_projectFieldIndex}"
					folder=$(date +%Y-%m)
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "checking which batch to create for this month: ${folder}"
					if [[ ! -d "${TMP_ROOT_DIR}/runs/AGCT/${folder}_batch1" ]]
					then
						newProjectName="${folder}_batch1"
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "batch1 is selected for creation"
					elif [[ ! -d "${TMP_ROOT_DIR}/runs/AGCT/${folder}_batch2" ]]
					then
						newProjectName="${folder}_batch2"
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "batch2 is selected for creation"
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Is this really a third run? CRASHHH"
						exit 1
					fi
					
					awk -v p="${_projectFieldIndex}" -v n="${newProjectName}" -F',' 'BEGIN{OFS=","} {if (NR>1){$p=n; print}else{ print $0}}' "${gapBatch}.csv.tmp2" > "${gapBatch}.csv.tmp3"
					
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "copying samplesheet to ${TMP_ROOT_DIR}/Samplesheets/AGCT/${newProjectName}.csv"
					rsync -v "${gapBatch}.csv.tmp3" "${TMP_ROOT_DIR}/Samplesheets/AGCT/${newProjectName}.csv"
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "navigate back to original folder"
					cd -
					rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
					mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
				else
					log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${GAP_HOME_DIR}/${gapBatch}/${gapBatch}.finished does not exist"
					continue
				fi
			fi
		done
	fi
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "server is down, there will be no data transfer!"
fi


#
# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0
