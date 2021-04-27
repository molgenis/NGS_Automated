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

function processBatch() {
	local _batch="${1}"
	local _batchDirFromSourceServer="${2}"
	local _controlFileBase="${3}"
	local _controlFileBaseForFunction
	_controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${_batch} ..."
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already processed ${_batch}."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue ..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	#
	# Step 1: Find how out how many flowcells this batch contains.
	# NGS flowcell dirs consist of 4 values separated by underscores.
	# E.g. 210419_A00379_0361_H3C3GDSX2
	#
	readarray -t _flowcellDirsFromSourceServer< <(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "find \"${_batchDirFromSourceServer}\" -maxdepth 1 -mindepth 1 -type d -name '[^_]*_[^_]*_[^_]*_[^_]*'")
	if [[ "${#_flowcellDirsFromSourceServer[@]:-0}" -eq '0' ]]
	then
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No flowcell directories found at ${DATA_MANAGER}@${sourceServerFQDN}:${_batchDirFromSourceServer}/[^_]*_[^_]*_[^_]*_[^_]*."
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found at least one flowcell dir at ${DATA_MANAGER}@${sourceServerFQDN}:${_batchDirFromSourceServer}/[^_]*_[^_]*_[^_]*_[^_]*."
	fi
	#
	# Step 2: check if flowcells were already successfully transferred to prm by copyRawDataToPrm.sh
	#
	local _flowcellDirFromSourceServer
	for _flowcellDirFromSourceServer in "${_flowcellDirsFromSourceServer[@]}"
	do
		local _flowcell
		_flowcell="$(basename "${_flowcellDirFromSourceServer}")"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if flowcell ${_flowcell} was already successfully transferred to prm ..."
		if [[ -e "${PRM_ROOT_DIR}/logs/${_flowcell}/${_flowcell}.copyRawDataToPrm.finished" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "    ${PRM_ROOT_DIR}/logs/${_flowcell}/${_flowcell}.copyRawDataToPrm.finished present."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "    ${_flowcell} was transferred to prm."
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "    ${PRM_ROOT_DIR}/logs/${_flowcell}/${_flowcell}.copyRawDataToPrm.finished MISSING."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "    ${_flowcell} is not yet transferred to prm -> Skipping batch ${_batch}."
			return
		fi
	done
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "All flowcells present on prm -> rsync samplesheets for all projects in this batch to prm to trigger downstream analysis."
	#
	# Rsync samplesheets to prm samplesheets folder.
	# Select all *.csv files, but exclude the CSV_UMCG_*.csv file from GenomeScan,
	# which is in the wrong format for starting downstream analysis
	#
	rsync -vlt "${dryrun:---progress}" \
		--log-file="${_controlFileBaseForFunction}.started" \
		--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
		--exclude='CSV_*' \
		"${DATA_MANAGER}@${sourceServerFQDN}:${_batchDirFromSourceServer}/*.${SAMPLESHEET_EXT}" \
		"${PRM_ROOT_DIR}/Samplesheets/" \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Failed to rsync samplesheets from ${DATA_MANAGER}@${sourceServerFQDN}:${_batchDirFromSourceServer}/*.${SAMPLESHEET_EXT}. See ${_controlFileBaseForFunction}.failed for details."
		mv -v "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully rsynct samplesheets for batch ${_batch} to prm." \
		&& rm -f "${_controlFileBaseForFunction}.failed" \
		&& mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) samplesheets per project for a batch of data succesfully transferred to prm storage.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-n	Dry-run: Do not perform actual sync, but only list changes instead.
	-g [group]
		Group for which to process data.
	-l [level]
		Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.
	-s [server]
		Source server address from where the raw data was fetched and from which we will now fetch samplesheets.
		Must be a Fully Qualified Domain Name (FQDN).
		E.g. gattaca01.gcc.rug.nl or gattaca02.gcc.rug.nl
	-r [root]
		Root dir on the server specified with -s and from where the samplesheets will be fetched (optional).
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
declare dryrun=''
declare sourceServerFQDN=''
declare sourceServerRootDir=''
while getopts ":g:l:s:r:hn" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		n)
			dryrun='-n'
			;;
		s)
			sourceServerFQDN="${OPTARG}"
			sourceServer="${sourceServerFQDN%%.*}"
			;;
		r)
			sourceServerRootDir="${OPTARG}"
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
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
# Overrule group's SCR_ROOT_DIR if necessary.
#
if [[ -n "${sourceServerRootDir:-}" ]]
then
	SCR_ROOT_DIR="${sourceServerRootDir}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi

#
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]; then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously
# per data collection we want to copy to prm -> one copy per group per combination of ${sourceServer} and ${SCR_ROOT_DIR}.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
# As servernames and folders may contain various characters that would require escaping in (lock) file names,
# we compute a hash for the combination of ${sourceServer} and ${SCR_ROOT_DIR} to append to the ${SCRIPT_NAME}
# for creating unique lock file. We write the combination of ${sourceServer} and ${SCR_ROOT_DIR} in the lock file
# to make it easier to detect which combination of ${sourceServer} and ${SCR_ROOT_DIR} the lock file is for.
#
hashedSource="$(printf '%s:%s' "${sourceServer}" "${SCR_ROOT_DIR}" | md5sum | awk '{print $1}')"
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}_${hashedSource}.lock"
thereShallBeOnlyOne "${lockFile}"
printf 'Lock file for %s instance that fetches data from %s:%s\n' "${SCRIPT_NAME}" "${sourceServer}" "${SCR_ROOT_DIR}" > "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs ..."

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
# Get a list of all batches for this group on the specified sourceServer, where the raw data was generated, and
#	1. Find all flowcells that are part of that batch.
#	2. Determine if those flowcells were all successfully processed by copyRarDataToPrm.sh.
#	3. If yes, then rsync the per project samplesheets for this batch to prm, so they will trigger analysis
#	   with a pipeline like NGS_DNA or NGS_RNA or ...
#
declare -a batchDirsFromSourceServer
# shellcheck disable=SC2029
readarray -t batchDirsFromSourceServer< <(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "find \"${SCR_ROOT_DIR}/\" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*-[0-9]*'")

if [[ "${#batchDirsFromSourceServer[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batch directories found at ${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/[0-9]*-[0-9]*."
else
	for batchDirFromSourceServer in "${batchDirsFromSourceServer[@]}"
	do
		#
		# Process this batch.
		#
		batch="$(basename "${batchDirFromSourceServer}")"
		controlFileBase="${PRM_ROOT_DIR}/logs/${batch}/"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}/${batch}.${SCRIPT_NAME}"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${batch}/"
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already processed ${batch}."
			continue
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${batch} ..."
		fi
		#
		# Let's start.
		#
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
		processBatch "${batch}" "${batchDirFromSourceServer}" "${controlFileBase}"
		#
		# Signal success or failure for complete process.
		#
		if [[ -e "${controlFileBase}/${batch}.processBatch.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}/${batch}.processBatch.finished present."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing ${batch}."
			rm -f "${JOB_CONTROLE_FILE_BASE}.failed" \
			&& mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}/${batch}.processBatch.finished absent -> processBatch failed."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process ${batch}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		fi
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished.'
printf '%s\n' "Finished." >> "${lockFile}"

trap - EXIT
exit 0

