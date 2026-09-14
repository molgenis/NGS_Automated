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
function rsyncData(){
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
	#
	# Rsync everything except the *.finished file and except any "hidden" files starting with a dot
	# (which may be temporary files created by rsync and which we do not have permissions for):
	# this may be an incompletely uploaded batch, but we already rsync everything we've got so far.
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing everything but the .finished file for ${gsBatch} ..."
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/./${gsBatch}/${_dataType} to ${TMP_ROOT_DIR}"
	/usr/bin/rsync -e 'ssh -p 443' -vrltD \
		--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
		--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
		--omit-dir-times \
		--omit-link-times \
		--exclude='*.finished' \
		--exclude='.*' \
		--relative "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/./${gsBatch}/${_dataType}" \
		"${TMP_ROOT_DIR}/"
	
	#
	# Rsync the Gs samplesheet to the gsbatch directory
	#
	/usr/bin/rsync -e 'ssh -p 443' -vrltD \
		--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
		--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
		--omit-dir-times \
		--omit-link-times \
		"${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/UMCG_CSV_*.${SAMPLESHEET_EXT}" \
		"${TMP_ROOT_DIR}/${gsBatch}/"
	
	#
	# Rsync the .finished file last if the upload was complete.
	#
	if [[ "${gsBatchUploadCompleted}" == 'true' ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing only the .finished file for ${gsBatch} ..."
		/usr/bin/rsync -e 'ssh -p 443' -vrltD \
			--log-file="${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log" \
			--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
			--omit-dir-times \
			--omit-link-times \
			"${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished" \
			"${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished"
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "No .finished file for ${gsBatch} present yet: nothing to sync."
	fi
	rm -f "${_controlFileBaseForFunction}.failed"
	mv "${_controlFileBaseForFunction}."{started,finished}

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
if [[ -z "${splitoption:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' 'No specifc splitoption provide, default is (all)'
	splitoption="all"
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


# Note: this script will only create a *.failed using the log4Bash() function from lib/sharedFunctions.sh.
#

#
# To make sure a *.finished file is not rsynced before a corresponding data upload is complete, we
# * first rsync everything, but with an exclude pattern for '*.finished' and
# * then do a second rsync for only '*.finished' files.
#
# shellcheck disable=SC2153
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Pulling data from data staging server ${HOSTNAME_DATA_STAGING} using rsync to /groups/${GROUP}/${TMP_LFS}/ ..."
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

			if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gsBatch} already processed, no need to transfer the data again."
				continue
			else
				#
				# Check if gsBatch is supposed to be complete (*.finished present).
				#
				gsBatchUploadCompleted='false'
				if rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished" 2>/dev/null
				then
					checkIfRawDataFolderExists=$(rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/")
					if [[ "${checkIfRawDataFolderExists}" == *"${analysisFolder}"* ]]
					then
						gsBatchUploadCompleted='true'
							rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${analysisFolder}/" 
					else
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "There is no Analysis folder, skipping"
						continue
					fi
				else
					log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished does not exist"
					continue
				fi

				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing pulling analysis batch ${gsBatch}..."
				logDir="${TMP_ROOT_DIR}/logs/${gsBatch}/"
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${logDir}"
				printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
				rsyncData "${gsBatch}" "${controlFileBase}" "${analysisFolder}"

				if [[ -e "${controlFileBase}.${analysisFolder}_rsyncData.finished" ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${analysisFolder}_rsyncData.finished present -> rsyncing completed for batch ${gsBatch}..."
					rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished rsyncing batch ${gsBatch}."
					mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${analysisFolder}_rsyncData.finished absent -> rsyncing failed for batch ${gsBatch}."
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to rsync batch ${gsBatch}. (project=${_projectName})"
					mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
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
