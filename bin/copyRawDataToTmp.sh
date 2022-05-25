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
set -o pipefail # Fail when any command in series of piped commands failed as opposed to only when the last command failed.

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

if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
	# shellcheck source=lib/sharedFunctions.bash
	source "${LIB_DIR}/sharedFunctions.bash"
else
	printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
	trap - EXIT
	exit 1
fi

function rsyncNGSRuns() {
	local _samplesheet
	_samplesheet="${1}"

	while read -r line
	do
		## line is ${filePrefix/${filePrefix}_1.fq.gz
		## removed '-tp' arguments in the rsync, since dm user is not able to set those
		rsync -rlptDvc --relative --rsync-path="sudo -u umcg-${GROUP}-ateambot rsync" "${WORKING_DIR}/./rawdata/ngs/${line}"* "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/" \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync ${line}"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from ${WORKING_DIR}/./rawdata/ngs/"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/rawdata/ngs/"
			mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			return
		}
	done<"${_samplesheet}"
	
}

function rsyncArrayRuns() {
	local _samplesheet
	_samplesheet="${1}"

	while read -r line
	do
		## line is ${sentrixBarcode_A}/${sentrixBarcode_A}_${sentrixPosition_A}.gtc
		## removed '-tp' arguments in the rsync, since dm user is not able to set those
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "rsync -rlDvc ${WORKING_DIR}/./rawdata/array/GTC/${line}* ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
		rsync -rlptDvc --relative --rsync-path="sudo -u umcg-${GROUP}-ateambot rsync" "${WORKING_DIR}/./rawdata/array/GTC/${line}"* "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/" \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to rsync ${line}"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    from ${WORKING_DIR}/./rawdata/array/GTC/"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "    to ${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/rawdata/array/GTC/"
			mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			return
		}
	done<"${_samplesheet}"
}

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a raw data from prm to tmp.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g [group]
		Group for which to process data.
	-w [workingDirectory]
		working directory a.k.a. rootDir/groupDir/LFS_dir
		e.g. /groups/umcg-gd/prm06 or /groups/umcg-gap/scr01
	-s [samplesheetServerLocation]
		location of the samplesheet 
		e.g. localhost (default) or wingedhelix
	-l [level]
		Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.
	-r [root]
		Root dir on the server specified with -s and from where the raw data will be fetched (optional).
		By default this is the SCR_ROOT_DIR variable, which is compiled from variables specified in the
		<group>.cfg, <source_host>.cfg and sharedConfig.cfg config files (see below.)
		You need to override SCR_ROOT_DIR when the data is to be fetched from a non default path,
		which is for example the case when fetching data from another group.

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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
declare group=''
while getopts ":g:l:s:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		s)
			samplesheetsServerLocation="${OPTARG}"
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
	"${HOME}/molgenis.cfg"
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
## parsed after config files loaded
if [[ -z "${samplesheetsServerLocation:-}" ]]
then
	samplesheetsServerLocation="localhost"
	samplesheetsLocation="${WORKING_DIR}/Samplesheets/"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "samplesheetsServerLocation set to ${samplesheetsServerLocation}."
else
	# shellcheck disable=SC2153
	samplesheetsLocation="/groups/${GROUP}/${TMP_LFS}/Samplesheets/"
fi


#
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group per combination of ${samplesheetsServerLocation} and ${samplesheetsLocation}.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
# As servernames and folders may contain various characters that would require escaping in (lock) file names,
# we compute a hash for the combination of ${samplesheetsServerLocation} and ${samplesheetsLocation} to append to the ${SCRIPT_NAME}
# for creating unique lock file. We write the combination of ${samplesheetsServerLocation} and ${samplesheetsLocation} in the lock file
# to make it easier to detect which combination of ${samplesheetsServerLocation}and ${samplesheetsLocation} the lock file is for.
#
hashedSource="$(printf '%s:%s' "${samplesheetsServerLocation}" "${samplesheetsLocation}" | md5sum | awk '{print $1}')"
lockFile="${WORKING_DIR}/logs/${SCRIPT_NAME}_${hashedSource}.lock"
thereShallBeOnlyOne "${lockFile}"
printf 'Lock file for %s instance that pushes data to %s:%s\n' "${SCRIPT_NAME}" "${samplesheetsServerLocation}" "${samplesheetsLocation}" > "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${WORKING_DIR}/logs ..."

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
# Get a list of all samplesheets for this group on the specified samplesheetsServerLocation, where the raw data was generated, and
#	1. Loop over their analysis ("run") sub dirs and check if there are any we need to rsync.
#	2. Optionally, split the samplesheets per project after the data was rsynced.
#
# shellcheck disable=SC2029
readarray -t sampleSheetsFolder < <(ssh "${samplesheetsServerLocation}" "find \"${samplesheetsLocation}/\" -mindepth 1 -maxdepth 1 -type f -name '*.${SAMPLESHEET_EXT}'")

##ISSUE: this script should always be executed by the ateambot user (and not for chaperone with the dm user solely to write the logs)
if [[ "${#sampleSheetsFolder[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No samplesheets found at ${samplesheetsServerLocation} ${samplesheetsLocation}/*.${SAMPLESHEET_EXT}."
else
	for sampleSheet in "${sampleSheetsFolder[@]}"
	do
		#
		# Process this samplesheet / run 
		#
		project="$(basename "${sampleSheet%."${SAMPLESHEET_EXT}"}")"
		controlFileBase="${WORKING_DIR}/logs/${project}/"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}/${project}.${SCRIPT_NAME}"
		printf '%s\n' "Rsyncing ${project} dir ..." >> "${lockFile}"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${WORKING_DIR}/logs/${project}/"
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already processed run ${project}."
			continue
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing run ${project} ..."
		fi
		
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
		
		if [[ "${samplesheetsServerLocation}" == "localhost" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Samplesheet is on this machine"
			if [[ -f "${WORKING_DIR}/logs/${project}/${RAWDATAPROCESSINGFINISHED}" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${WORKING_DIR}/logs/${project}/${RAWDATAPROCESSINGFINISHED} present."
				##Check if array or NGS run
				# shellcheck disable=SC2029
				if ssh "${samplesheetsServerLocation}" "grep 'SentrixBarcode_A' \"${sampleSheet}\""
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "this is array data"
					## copy all the data from that run
					rsync -rlptDvc "${WORKING_DIR}/./rawdata/array/GTC/${filePrefix}" "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
				else		
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "this is NGS data"
					## copy all the data from that run
					rsync -rlptDvc "${WORKING_DIR}/./rawdata/ngs/${filePrefix}" "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/"
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${project} finished"
				fi
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${WORKING_DIR}/logs/${project}/${RAWDATAPROCESSINGFINISHED} absent."
				continue
			fi
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Samplesheet is on destination machine: ${DESTINATION_DIAGNOSTICS_CLUSTER}"
			# shellcheck disable=SC2029
			if ssh "${DATA_MANAGER}"@"${DESTINATION_DIAGNOSTICS_CLUSTER}" test -e "${TMP_ROOT_DIR}/logs/${project}/${project}.data.requested"
			then
				##Check if array or NGS run
				if ssh "${samplesheetsServerLocation}" "grep 'SentrixBarcode_A' \"${sampleSheet}\""
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "this is array data"
					## copy the requested file to the ${WORKING_DIR}
					rsync -vt "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/logs/${project}/${project}.data.requested" "${WORKING_DIR}/logs/${project}/"
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/logs/${project}/${project}.data.requested present, copying will start"
					rsyncArrayRuns "${WORKING_DIR}/logs/${project}/${project}.data.requested"
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "data transfer for ${project} is finished"
				else
					rsync -vt "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/logs/${project}/${project}.data.requested" "${WORKING_DIR}/logs/${project}/"
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DESTINATION_DIAGNOSTICS_CLUSTER}:${TMP_ROOT_DIR}/logs/${project}/${project}.data.requested present, copying will start"
					rsyncNGSRuns "${WORKING_DIR}/logs/${project}/${project}.data.requested"
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "data transfer for ${project} is finished"
				fi
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/logs/${project}/${project}.data.requested absent, it can be that the process already started (${TMP_ROOT_DIR}/logs/${project}/${project}.data.started)"
				continue
			fi
		fi
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully transferred the data from ${WORKING_DIR}/logs/${project}/${project}.data.requested to tmp."
		rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
		mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished.'
printf '%s\n' "Finished." >> "${lockFile}"

trap - EXIT
exit 0

