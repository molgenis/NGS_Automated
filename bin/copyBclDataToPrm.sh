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
while getopts ":g:l:p:s:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		p)
			prm_dir="${OPTARG}"
			;;
		s)
			sourceServerFQDN="${OPTARG}"
			sourceServer="${sourceServerFQDN%%.*}"
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

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/${sourceServer##*+}.cfg"
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
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Overrule group's PRM_ROOT_DIR if necessary.
#
if [[ -z "${prm_dir:-}" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "default (${PRM_ROOT_DIR})"
else
	# shellcheck disable=SC2153
	PRM_ROOT_DIR="/groups/${GROUP}/${prm_dir}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "PRM_ROOT_DIR is set to ${PRM_ROOT_DIR}"
	if test -e "/groups/${GROUP}/${prm_dir}/"
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${PRM_ROOT_DIR} is available"
		
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "${PRM_ROOT_DIR} does not exist, exit!"
	fi
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
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs ..."

declare -a sampleSheetsFromSourceServer
# shellcheck disable=SC2029
readarray -t sampleSheetsFromSourceServer< <(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "find \"${SCR_ROOT_DIR}/Samplesheets/\" -mindepth 1 -maxdepth 1 -type f -name '*.${SAMPLESHEET_EXT}'")

if [[ "${#sampleSheetsFromSourceServer[@]}" -eq '0' ]]
then
	
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No sample sheets found at ${DATA_MANAGER}@${sourceServerFQDN}:${SCR_ROOT_DIR}/Samplesheets/*.${SAMPLESHEET_EXT}."
else
	for sampleSheet in "${sampleSheetsFromSourceServer[@]}"
	do
		#
		# Process this sample sheet / run and find how out how many raw data items it contains.
		#
		filePrefix="$(basename "${sampleSheet%."${SAMPLESHEET_EXT}"}")"
		controlFileBase="${PRM_ROOT_DIR}/logs/${filePrefix}/"

		export JOB_CONTROLE_FILE_BASE="${controlFileBase}/${filePrefix}.${SCRIPT_NAME}"
		logDir="${PRM_ROOT_DIR}/logs/${filePrefix}/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${logDir}"
		
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${JOB_CONTROLE_FILE_BASE}.finished is present -> Skipping."
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already transferred ${filePrefix}."
			continue
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${JOB_CONTROLE_FILE_BASE}.finished not present -> Continue..."
			printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
		fi	
		
		#
		# Determine whether an rsync is required for this run, which is the case when
		# raw data production has finished successfully and this copy script has not.
		#
		if ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" test -e "${SEQ_DIR}/${filePrefix}/RunCompletionStatus.xml"
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SEQ_DIR}/${filePrefix}/RunCompletionStatus.xml present."
			finished="true"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DATA_MANAGER}@${sourceServerFQDN}:${SEQ_DIR}/${filePrefix}/RunCompletionStatus.xml absent."
			continue
		fi

		if [[ "${finished}" == "true" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing everything from ${filePrefix}"
			/usr/bin/rsync -vrltD \
				--log-file="${JOB_CONTROLE_FILE_BASE}.log" \
				--chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' \
				--omit-dir-times \
				--omit-link-times \
				"${DATA_MANAGER}@${sourceServerFQDN}:${SEQ_DIR}/${filePrefix}" \
				"${PRM_ROOT_DIR}/rawdata/bcls/"
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Sequencer is busy producing data: skipping ${filePrefix}."
			continue	
		fi
		# shellcheck disable=SC2029
		countFilesRunDirScr="$(ssh "${DATA_MANAGER}"@"${sourceServerFQDN}" "find \"${SEQ_DIR}/${filePrefix}/\"* -type f | wc -l")"
		countFilesRunDirPrm="$(find "${PRM_ROOT_DIR}/rawdata/bcls/${filePrefix}/"* -type f | wc -l)"
		if [[ "${countFilesRunDirScr}" -ne "${countFilesRunDirPrm}" ]]; then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files on tmp (${countFilesRunDirScr}) and prm (${countFilesRunDirPrm}) is NOT the same!"
				mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			return
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Amount of files on tmp and prm is the same for ${filePrefix}."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "The data is available at ${PRM_ROOT_DIR}/rawdata/bcls/${filePrefix}/"
			mountedCifsDevice="$(awk -v mountpoint="${PRM_ROOT_DIR}" '$2==mountpoint && $3=="cifs" {print $1}' /proc/mounts)"
			if [[ -n "${mountedCifsDevice:-}" ]]; then
				printf 'file:%s/rawdata/bcls/%s/\n' \
					"${mountedCifsDevice}" "${filePrefix}" \
					>> "${JOB_CONTROLE_FILE_BASE}.started"
			fi
			mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
		fi
		
	done 
fi	


# Clean exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0