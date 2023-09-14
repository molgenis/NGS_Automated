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

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished analysis project from tmp to prm storage.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g	Group.
	-d	DAT_DIR
	-p	[pipeline]
		Pipeline that produced the project data that needs to be transferred to prm. (NGS_Demultiplexing, GAP)
	-n	Dry-run: Do not perform actual sync, but only list changes instead.
	-r	[root]
		Root dir on the server specified with -s and from where the project data will be fetched (optional).
		By default this is the SCR_ROOT_DIR variable, which is compiled from variables specified in the
		<group>.cfg, <source_host>.cfg and sharedConfig.cfg config files (see below.)
		You need to override SCR_ROOT_DIR when the data is to be fetched from a non default path,
		which is for example the case when fetching data from another group.
	-l	Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

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

function rsyncProjectRun() {
	local _project="${1}"
	local _run="${2}"
	local _controlFileBase="${3}"	
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"

	#
	# Determine whether an rsync is required for this run, which is the case when
	#  1. either the pipeline has finished and this copy script has not
	#  2. or when a pipeline has updated the results after a previous execution of this script. 
	#
	# Temporarily check for "${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished"
	#        in addition to "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished"
	# for backwards compatibility with old NGS_Automated 1.x.
	#
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already transferred ${_project}."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	
	# shellcheck disable=SC2174
	mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${_project}/"

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_project}/${_run} ..." \
	2>&1 | tee -a "${_controlFileBaseForFunction}.started"
	echo "started: $(date +%FT%T%z)" > "${_controlFileBaseForFunction}.totalRunTime"
	
	
	# Perform rsync.
	#  1. For ${_run} dir: recursively with "default" archive (-a),
	#     which checks for differences based on file size and modification times.
	#     No need to use checksums here as we will verify checksums later anyway.
	#  2. For ${_run}.md5 list of checksums with archive (-a) and -c to determine 
	#     differences based on checksum instead of file size and modification time.
	#     It is vitally important (and computationally cheap) to make sure 
	#     the list of checksums is complete and up-to-date!
	#
	# ToDo: Do we need to add --delete to get rid of files that should no longer be there 
	#       if an analysis run got updated?
	#

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run} dir ..." \
		2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started" 
	rsync -av --progress --log-file="${_controlFileBaseForFunction}.started" --chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' "${dryrun:---progress}" \
		"${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${_project}/${_run}" \
		"${PRM_ROOT_DIR}/projects/${_project}/" \
	|| {
		mv "${JOB_CONTROLE_FILE_BASE}."{started,failed} 
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to rsync ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${_project}/${_run} dir. See ${_controlFileBaseForFunction}.failed for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_controlFileBaseForFunction}.failed for details." >> "${JOB_CONTROLE_FILE_BASE}.failed" 
	}
	
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run}.md5 checksums ..."
	rsync -acv --progress --log-file="${_controlFileBaseForFunction}.started" --chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' "${dryrun:---progress}" \
		"${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${_project}/${_run}.md5" \
		"${PRM_ROOT_DIR}/projects/${_project}/" \
	|| {
		mv "${_controlFileBaseForFunction}."{started,failed}
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to rsync ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${_project}/${_run}.md5. See ${_controlFileBaseForFunction}.failed for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${_controlFileBaseForFunction}.failed for details." \
			>> "${_controlFileBaseForFunction}.failed" 
	}
	rm -f "${_controlFileBaseForFunction}.failed"
	mv "${_controlFileBaseForFunction}."{started,finished}
}
	
function checkRawdata(){
	local _project="${1}"
	local _run="${2}"
	local _controlFileBase="${3}"	
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
#RAWDATATYPES nog dir in bakken
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already checked ${_project}."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	
	# shellcheck disable=SC2174
	mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${_project}/"

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_project}/${_run} ..." \
	2>&1 | tee -a "${_controlFileBaseForFunction}.started"
	echo "started: $(date +%FT%T%z)" > "${_controlFileBaseForFunction}.totalRunTime"
	
	# shellcheck disable=SC2029
	mapfile -t fqfiles < <(ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" "find -type l -maxdepth 1 - mindepth 1 -name *.fq.gz \"${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${_project}/${_run}/rawdata/${PRMRAWDATA}/\"")
	if [[ "${#fqfiles[@]}" -eq '0' ]]
	then
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No fastQ files found @ /groups/umcg-atd/projects/."
	else
		for fqfile in "${fqfiles[@]}"
		do

			fqfile=$(basename "${fqfile}")
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${fqfile} on ${TMP_ROOT_DIAGNOSTICS_DIR}, check if it is present on ${PRM_ROOT_DIR}"
			sequenceRun=$(echo "${fqfile}" | cut -d "_" -f 1-4 --output-delimiter="_")
			fqavail='false'
			for prm_dir in "${ALL_PRM[@]}"
			do
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "looping through ${prm_dir}"
				
				export PRM_ROOT_DIR="/groups/${group}/${prm_dir}/"
				if [[ -e "${PRM_ROOT_DIR}/rawdata/${PRMRAWDATA}/${sequenceRun}/${fqfile}" ]]
				then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Great, the fastQ file ${fqfile} is stored on ${PRM_ROOT_DIR}"
					fqavail='true'
					continue
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "the fastQ file ${fqfile} is not stored on ${PRM_ROOT_DIR}"
				fi
			done
			if [[ "${fqavail}" == 'false' ]]
			then
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "the fastQ file ${fqfile} is not stored on ${ALL_PRM[*]}, please make sure all the data of project ${_project} is stored proper"
				mv "${_controlFileBaseForFunction}."{started,failed}
				exit
			fi
		done
	fi
	
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Perfect! all the files for project ${project} are on PRM, time to make a run01.rawDataCopiedToPrm.finished"
	ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" touch "${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/run01.rawDataCopiedToPrm.finished"
	mv "${_controlFileBaseForFunction}."{started,finished}

}
	
	
	
function sanityCheck() {
	local _project="${1}"
	local _run="${2}"
	local _sampleType="${3}"
	local _controlFileBase="${4}"	
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME[0]}"
	
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already did a ${FUNCNAME[0]} for ${_project}."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	
	#
	# Count the number of all files produced in this analysis run.
	#
	local _countFilesProjectRunDirTmp
	# shellcheck disable=SC2029
	_countFilesProjectRunDirTmp=$(ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" "find \"${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${_project}/${_run}/results/\"* -type f -o -type l | wc -l")
	
	#
	# Sanity check.
	#
	#  1. Firstly do a quick count of the amount of files to make sure we are complete.
	#     (No need to waist a lot of time on computing checksums for a partially failed transfer).
	#  2. Secondly verify checksums on the destination.
	#
	
	local _countFilesProjectRunDirPrm
	_countFilesProjectRunDirPrm=$(find "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/"* -type f -o -type l | wc -l)
	if [[ "${_countFilesProjectRunDirTmp}" -ne "${_countFilesProjectRunDirPrm}" ]]
	then
		
		find "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/"* -type f -o -type l | sort -V > "${JOB_CONTROLE_FILE_BASE}.countPrmFiles.txt"
		# shellcheck disable=SC2029
		ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" "find \"${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${_project}/${_run}/results/\"* -type f -o -type l | sort -V" > "${_controlFileBaseForFunction}.countTmpFiles.txt"
		
		echo "diff -q ${_controlFileBaseForFunction}.countPrmFiles.txt ${_controlFileBaseForFunction}.countTmpFiles.txt" >> "${_controlFileBaseForFunction}.started"
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectRunDirTmp}) and prm (${_countFilesProjectRunDirPrm}) is NOT the same!" \
			>> "${_controlFileBaseForFunction}.started"
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectRunDirTmp}) and prm (${_countFilesProjectRunDirPrm}) is NOT the same!"
		
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Amount of files on tmp and prm is the same for ${_project}/${_run}: ${_countFilesProjectRunDirPrm}."
		#
		# Verify checksums on prm storage.
		#
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Started verification of checksums by using checksums from ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5."
		cd "${PRM_ROOT_DIR}/projects/${_project}/"
		if md5sum -c "${_run}.md5" > "${_run}.md5.log" 2>&1
		then
			if [[ "${_sampleType}" == 'GAP' ]]
			then
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "_sampleType is GAP. Making symlinks for DiagnosticOutput folder."
				# shellcheck disable=SC1003 # No, we are not escaping a '
				windowsPathDelimeter='\\'
				linuxPathDelimeter='/'
				#
				# Create symlinks for PennCNV files per sample (new style).
				#
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Checking if ${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/PennCNV_reports/ folder exists ..."
				if [[ -d "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/PennCNV_reports/" ]]
				then
					mapfile -t pennCNVFiles < <(find "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/PennCNV_reports/" -name "*.txt")
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Number of PennCNV files: ${#pennCNVFiles[@]}."
					#shellcheck disable=SC2153
					mkdir -p "/groups/${GROUP}/${DAT_LFS}/DiagnosticOutput/${_project}/"
					for pennCNV in "${pennCNVFiles[@]}"
					do
						name=$(basename "${pennCNV}")
						printf '%s%s\r\n' "${SMB_SHARE_NAMES["${GROUP}"]}" "${pennCNV//${linuxPathDelimeter}/${windowsPathDelimeter}}" \
							> "/groups/${GROUP}/${DAT_LFS}/DiagnosticOutput/${_project}/${name}"
					done
				fi
				#
				# Create symlink for call rate file last as this is the trigger for Darwin to start processing the data.
				# If any data is (still) missing after creating this symlink, processing will fail.
				#
				callrate=$(ls "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/Callrates_${_project}.txt")
				printf '%s%s\r\n' "${SMB_SHARE_NAMES["${GROUP}"]}" "${callrate//${linuxPathDelimeter}/${windowsPathDelimeter}}" \
					> "/groups/${GROUP}/${DAT_LFS}/DiagnosticOutput/Callrates_${_project}.txt"
			fi
			echo "The results can be found in: ${PRM_ROOT_DIR}." \
				>> "${_controlFileBaseForFunction}.started"
			echo "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details." \
				>> "${_controlFileBaseForFunction}.started" \
			&& rm -f "${_controlFileBaseForFunction}.failed" \
			&& mv "${_controlFileBaseForFunction}."{started,finished}
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
			rm -f "${PRM_ROOT_DIR}/Samplesheets/${project}.${SAMPLESHEET_EXT}"
		else
			mv "${_controlFileBaseForFunction}."{started,failed}
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${PRM_ROOT_DIR}/logs/${_project}/${_run}.md5.failed.log for details." \
			>> "${_controlFileBaseForFunction}.failed"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details."
		fi
		cd -
	fi
}

function getSampleType(){
	local  _sampleSheet="${1}"
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()
	declare    sampleType='DNA' # Default when not specified in sample sheet.
	declare    sampleTypeFieldIndex
	IFS="${SAMPLESHEET_SEP}"  read -r -a sampleSheetColumnNames <<<"$(head -1 "${_sampleSheet}")"
	for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]} ; offset++ ))
	do
		#
		# Backwards compatibility for "Sample Type" including - the horror - a space and optionally quotes :o.
		#
		regex='Sample Type'
		if [[ "${sampleSheetColumnNames[${offset}]}" =~ ${regex} ]]
		then
			columnName='sampleType'
		else
			columnName="${sampleSheetColumnNames[${offset}]}"
		fi
		sampleSheetColumnOffsets["${columnName}"]="${offset}"
	#	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${columnName} and sampleSheetColumnOffsets["${columnName}"] offset ${offset} "
	done
	
	if [[ -n "${sampleSheetColumnOffsets['sampleType']+isset}" ]]; then
		#
		# Get sampleType from sample sheet and check if all samples are of the same type.
		#
		sampleTypeFieldIndex=$((${sampleSheetColumnOffsets['sampleType']} + 1))
		sampleTypesCount=$(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}" | sort | uniq | wc -l)
		if [[ "${sampleTypesCount}" -eq '1' ]]
		then
			sampleType=$(tail -n 1 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}")
	#		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found sampleType: ${sampleType}."
			echo "${sampleType}"
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} contains multiple different sampleType values."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${project} due to error in sample sheet."
			return
		fi
	else
	#	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType column missing in sample sheet; will use default value: ${sampleType}."
		echo "${sampleType}"
	fi
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
while getopts ":g:l:p:d:r:hn" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		p)
			pipeline="${OPTARG}"
			;;
		n)
			dryrun='-n'
			;;
		d)
			dat_dir="${OPTARG}"
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
if [[ -n "${dryrun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Enabled dryrun option for rsync.'
fi
if [[ -z "${pipeline:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a pipeline with -p.'
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
# Overrule group's SCR_ROOT_DIR if necessary.
#
if [[ -n "${sourceServerRootDir:-}" ]]
then
	SCR_ROOT_DIR="${sourceServerRootDir}"
	TMP_ROOT_DIAGNOSTICS_DIR="${SCR_ROOT_DIR}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi

if [[ -z "${dat_dir:-}" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "default (${DAT_ROOT_DIR})"
else
	DAT_ROOT_DIR="/groups/${GROUP}/${dat_dir}/"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "DAT_ROOT_DIR is set to ${DAT_ROOT_DIR}"
	if test -e "/groups/${GROUP}/${dat_dir}/"
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${DAT_ROOT_DIR} is available"
		
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "${DAT_ROOT_DIR} does not exist, exit!"
	fi
fi

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

#
# Get a list of all projects for this group, loop over their run analysis ("run") sub dirs and check if there are any we need to rsync.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Searching for projects as ${DATA_MANAGER} on ${HOSTNAME_TMP} in ${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}"
# shellcheck disable=SC2029
mapfile -t projects < <(ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" "find \"${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/\" -maxdepth 1 -mindepth 1 -type d")
if [[ "${#projects[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/."
else
	for project in "${projects[@]}"
	do
		project=$(basename "${project}")
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project} ..."
		# shellcheck disable=SC2029
		mapfile -t runs < <(ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" "find \"${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${project}/\" -maxdepth 1 -mindepth 1 -type d")
		if [[ "${#runs[@]}" -eq '0' ]]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found for project ${project}."
		else
			for run in "${runs[@]}"
			do
				run=$(basename "${run}")
				controlFileBase="${PRM_ROOT_DIR}/logs/${project}/${run}"
				export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
				calculateProjectMd5sFinishedFile="ssh ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/${run}.calculateProjectMd5s.finished"
				rawDataCopiedToPrmFinishedFile="ssh ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/run01.rawDataCopiedToPrm.finished"
				if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]] 
				then
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${project}/${run}."
				else
					if ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" test -e "${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/run01.rawDataCopiedToPrm.finished"
					then
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "found: ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/run01.rawDataCopiedToPrm.finished"
						# shellcheck disable=SC2244	
						if ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" test -e "${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/${run}.calculateProjectMd5s.finished"
						then
							log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs folder: ${PRM_ROOT_DIR}/logs/${project}/"
							mkdir -p "${PRM_ROOT_DIR}/logs/${project}/"
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "found: ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/${run}.calculateProjectMd5s.finished"
							if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]] && [[ "${calculateProjectMd5sFinishedFile}" &&  "${rawDataCopiedToPrmFinishedFile}" -ot "${JOB_CONTROLE_FILE_BASE}.finished" ]]
							then
								log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${project}/${run}."
							else
								touch "${JOB_CONTROLE_FILE_BASE}.started"
								log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "archiving samplesheet in ${PRM_ROOT_DIR}/Samplesheets/archive/"
								rsync -av "${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${pipeline}/${project}/${run}/results/${project}.${SAMPLESHEET_EXT}" "${PRM_ROOT_DIR}/Samplesheets/archive/"
								sampleType="$(set -e; getSampleType "${PRM_ROOT_DIR}/Samplesheets/archive/${project}.${SAMPLESHEET_EXT}")"
								log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType =${sampleType}"
								log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project}/${run} ..."
								rsyncProjectRun "${project}" "${run}" "${controlFileBase}"
								if [[ -e "${controlFileBase}.rsyncProjectRun.finished" ]]
								then
									log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.rsyncProjectRun.finished present -> rsyncProjectRun completed; let's sanityCheck for project ${project}..."
									sanityCheck "${project}" "${run}" "${sampleType}" "${controlFileBase}"
								else
									log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.rsyncProjectRun.finished absent -> rsyncProjectRun failed."
								fi
								if [[ -e "${controlFileBase}.sanityCheck.finished" ]]
								then
									log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.sanityCheck.finished present -> sanityCheck completed; let's upload data to Track and Trace for project ${project}..."
									# shellcheck disable=SC2029
									if ssh "${DATA_MANAGER}@${HOSTNAME_TMP}" "rm -f ${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/${pipeline}/${project}.${SAMPLESHEET_EXT}"
									then
										log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/${pipeline}/${project}.${SAMPLESHEET_EXT} removed on ${HOSTNAME_TMP}"
									else
										log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Could not remove ${TMP_ROOT_DIAGNOSTICS_DIR}/Samplesheets/${pipeline}/${project}.${SAMPLESHEET_EXT} from ${HOSTNAME_TMP}"
										mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
										return
									fi
									#
									# Add info for colleagues that will process the results.
									# This will appear in the messeages send by notifications.sh
									#
									log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "The data is available at ${PRM_ROOT_DIR}/projects/${project}/${run}/."
									mountedCifsDevice="$(awk -v mountpoint="${PRM_ROOT_DIR}" '$2==mountpoint && $3=="cifs" {print $1}' /proc/mounts)"
									if [[ -n "${mountedCifsDevice:-}" ]]; then
										printf 'file:%s/projects/%s/%s/\n' \
											"${mountedCifsDevice}" "${project}" "${run}" \
											>> "${JOB_CONTROLE_FILE_BASE}.started"
									fi
									rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
									mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
									log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing project ${project}."
									log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.finished. Setting track & trace state to finished :)."
									dateFinished=$(date +%FT%T%z -r "${JOB_CONTROLE_FILE_BASE}.finished")
									printf '"%s"\n' "${dateFinished}" > "${JOB_CONTROLE_FILE_BASE}.trace_putFromFile_projects.csv"
									echo "finished: $(date +%FT%T%z)" >> "${JOB_CONTROLE_FILE_BASE}.totalRunTime"
								else
									log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.sanityCheck.finished absent -> rsyncProjectRun failed."
									log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process project ${project}."
									mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
									log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.failed. Setting track & trace state to failed :(."
								fi
							fi
						else
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${project}/${run} calculateProjectMd5s not yet finished."
						fi
					else
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Copying the rawdata of project ${project} is not yet finished."
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Cheking if the calculateProjectMd5s is finished, if so the pipeline started with only project data, copy the project data and the rawdata to prm"
						# shellcheck disable=SC2244	
						if ssh "${DATA_MANAGER}"@"${HOSTNAME_TMP}" test -e "${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/${run}.calculateProjectMd5s.finished"
						then
							log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "CalculateProjectMd5s is finished, the pipeline started with only project data, check if the rawdata is on PRM"
							log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs folder: ${PRM_ROOT_DIR}/logs/${project}/"
							mkdir -p "${PRM_ROOT_DIR}/logs/${project}/"
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "found: ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/${run}.calculateProjectMd5s.finished"
							touch "${JOB_CONTROLE_FILE_BASE}.started"
							log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "check if the rawdata is stored on PRM"
							checkRawdata "${project}" "${run}" "${controlFileBase}"
						else
							log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "CalculateProjectMd5s is not finished yet, the pipeline is still running"
						fi
					fi
				fi
			done
		fi
	done
fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'
trap - EXIT
exit 0
