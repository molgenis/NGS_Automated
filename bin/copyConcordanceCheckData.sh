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
		if [ "${!i}" == "${value}" ]
		then
			echo 'y'
			return 0
		fi
	}
	echo 'n'
	return 1
}


function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished run from tmp to prm storage.
Usage:
	$(basename "${0}") OPTIONS
Options:
	-h   Show this help.
	-g   Group.
	-n   Dry-run: Do not perform actual sync, but only list changes instead.
	-l   Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

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
declare email='false'
declare dryrun=''
while getopts "g:l:hn" opt
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
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
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
declare -a sampleSheetsFromSourceServer=($(ssh ${DATA_MANAGER}@${HOSTNAME_TMP} "find ${TMP_ROOT_DIAGNOSTICS_DIR}/concordance/samplesheets/ -mindepth 1 -maxdepth 1 \( -type l -o -type f \) -name *.sampleId.txt"))

mkdir -p "/groups/${GROUP}/${DAT_LFS}/ConcordanceCheckOutput/"

if [[ "${#sampleSheetsFromSourceServer[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No sample sheets found at ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/concordance/samplesheets/*.sampleId.txt."
else
	for sampleSheet in "${sampleSheetsFromSourceServer[@]}"
	do
		#
		# Process this sample sheet / run.
		#
		filePrefix="$(basename "${sampleSheet%%.*}")"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${filePrefix} ..."
		ngsVcfId=$(ssh ${DATA_MANAGER}@${HOSTNAME_TMP} "awk '{if (NR>1){print \$2}}' ${sampleSheet}")

		if ssh "${DATA_MANAGER}@${HOSTNAME_TMP}" test -e "${TMP_ROOT_DIAGNOSTICS_DIR}/concordance/logs/${filePrefix}.ConcordanceCheck.finished"
		then
			touch "${PRM_ROOT_DIR}/concordance/logs/${ngsVcfId}.copyConcordanceCheckData.started"
			rsync -av ${DATA_MANAGER}@${HOSTNAME_TMP}:/${TMP_ROOT_DIAGNOSTICS_DIR}/concordance/results/${filePrefix}.* "${PRM_ROOT_DIR}/concordance/results/" 
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "removing ${PRM_ROOT_DIR}/concordance/ngs/${ngsVcfId}.final.vcf.gz and ${sampleSheet} from prm"
			ssh ${DATA_MANAGER}@${HOSTNAME_TMP} "rm -f ${sampleSheet}"
			rm -f "${PRM_ROOT_DIR}/concordance/ngs/${ngsVcfId}.final.vcf.gz"

			
			cd "/groups/${GROUP}/${DAT_LFS}/ConcordanceCheckOutput/"
			windowsPathDelimeter="\\"
			#
			# Create link in file
			#
			for i in $(ls "${PRM_ROOT_DIR}/concordance/results/${filePrefix}."*)
			do
				fileName=$(basename ${i})
				echo "\\\\zkh\appdata\medgen\leucinezipper${i//\//$windowsPathDelimeter}" > "${fileName}"
				unix2dos "${fileName}"
			done

			mv "${PRM_ROOT_DIR}/concordance/logs/${ngsVcfId}.copyConcordanceCheckData."{started,finished}
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "concordanceCheck for ${filePrefix} not finished (yet)"
		fi
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'

trap - EXIT
exit 0

