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
	exit 1
fi

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script that runs nanopore pipeline for new sample sheets

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-r	Run number / runID (default is run01)
	-g	Group.
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

function executePreVip () {
	local -r _project="${1}"
	local -r _run="${2}"
	local _controlFileBase="${3}"
	local _controlFileBaseForFunction="${_controlFileBase}.${SCRIPT_NAME}_${FUNCNAME[0]}"

	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi

	local -r _pipeline_software_dir="${TMP_ROOT_DIR}/software/nanopore"
	local -r _project_rawdata_dir="${TMP_ROOT_DIR}/rawdata/nanopore/${_project}/${_project}"
	local -r _project_tmp_dir="${TMP_ROOT_DIR}/tmp/nanopore/${_project}/${_run}/pre_vip"
	mkdir -p "${_project_tmp_dir}"

	#
	# step 1: merge and decompress the passed fastq files
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "merge and decompress the passed fastq files"
	local -r _merged_fastq_file="${_project_tmp_dir}/${_project}.fastq"
	local -r _merged_fastq_gz_file="${_merged_fastq_file}.gz"
	cat "${_project_rawdata_dir}/"*"/fastq_pass/"*".fastq.gz" > "${_merged_fastq_gz_file}"
	gunzip -f "${_merged_fastq_gz_file}"

	#
	# step 2: extract read IDs of interest based on decision in csv file
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "extract read IDs of interest based on decision in csv file"
	local -r _adaptive_sampling_files=( "${_project_rawdata_dir}/"*"/other_reports/adaptive_sampling_"*".csv" )
	local -r _adaptive_sampling_file="${_adaptive_sampling_files[0]}"
	local -r _read_ids_file="${_project_tmp_dir}/stop_receiving_read_ids.txt"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "adaptive_sampling_file: ${_adaptive_sampling_files[0]}"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "_read_ids_file: ${_read_ids_file}"
	grep stop_receiving "${_adaptive_sampling_file}" | cut -d , -f 5 > "${_read_ids_file}"

	#
	# step 3: extract reads and save to new file
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "extract reads and save to new file"
	local -r _seqtk_image_file="${_pipeline_software_dir}/images/seqtk-1.4.sif"
	local -r _stop_receiving_fastq_file="${_project_tmp_dir}/${_project}_stop_receiving.fastq"
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "COMMAND to EXECUTE: apptainer exec --no-mount home --bind \"${TMP_ROOT_DIR}\" \"${_seqtk_image_file}\" seqtk subseq \"${_merged_fastq_file}\" \"${_read_ids_file}\" > \"${_stop_receiving_fastq_file}\""
	apptainer exec --no-mount home --bind "${TMP_ROOT_DIR}" "${_seqtk_image_file}" seqtk subseq "${_merged_fastq_file}" "${_read_ids_file}" > "${_stop_receiving_fastq_file}"
	gzip -f "${_stop_receiving_fastq_file}"


	rm -f "${_controlFileBaseForFunction}.failed"
	mv "${_controlFileBaseForFunction}."{started,finished}

	}

	function executeVip () {
	local -r _project="${1}"
	local -r _run="${2}"
	local _controlFileBase="${3}"
	local _controlFileBaseForFunction="${_controlFileBase}.${SCRIPT_NAME}_${FUNCNAME[0]}"

	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."

		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi

	local -r _pipeline_software_dir="${TMP_ROOT_DIR}/software/nanopore"
	local -r _project_preprocessed_data_dir="${TMP_ROOT_DIR}/tmp/nanopore/${_project}/${_run}/pre_vip"
	local -r _project_tmp_dir="${TMP_ROOT_DIR}/tmp/nanopore/${_project}/${_run}/vip"
	mkdir --parents "${_project_tmp_dir}"

	#
	# step 1: create sample sheet
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "create VIP sample sheet"
	local -r _project_vip_samplesheet_file="${_project_tmp_dir}/sample_sheet.tsv"
	local -r _project_id="${_project}"
	local -r _family_id=""
	local -r _individual_id="sample"
	local -r _paternal_id=""
	local -r _maternal_id=""
	local -r _sex=""
	local -r _affected="true"
	local -r _proband="true"
	local -r _hpo_ids=""
	local -r _sequencing_method=""
	local -r _sequencing_platform="nanopore"
	local -r _fastq="${_project_preprocessed_data_dir}/${_project}_stop_receiving.fastq.gz"
	echo -e "project_id\tfamily_id\tindividual_id\tpaternal_id\tmaternal_id\tsex\taffected\tproband\thpo_ids\tsequencing_method\tsequencing_platform\tfastq" > "${_project_vip_samplesheet_file}"
	echo -e "${_project_id}\t${_family_id}\t${_individual_id}\t${_paternal_id}\t${_maternal_id}\t${_sex}\t${_affected}\t${_proband}\t${_hpo_ids}\t${_sequencing_method}\t${_sequencing_platform}\t${_fastq}" >> "${_project_vip_samplesheet_file}"

	#
	# step 2: execute vip
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "execute VIP"
	local -r _vip_version="v7.7.1"
	local -r _vip_dir="${_pipeline_software_dir}/vip/${_vip_version}"
	local -r _vip_config_file="${_pipeline_software_dir}/resources/run.cfg"
	local -r _vip_output_dir="${TMP_ROOT_DIR}/projects/nanopore/${_project}/${_run}/results"

	local args=()
	args+=("--workflow" "fastq")
	args+=("--input" "${_project_vip_samplesheet_file}")
	args+=("--output" "${_vip_output_dir}")
	args+=("--config" "${_vip_config_file}")

	module load Java/11.0.20
	NXF_HOME="${_project_tmp_dir}/.nxf.home" NXF_TEMP="${_project_tmp_dir}/.nxf.tmp" NXF_WORK="${_project_tmp_dir}/.nxf.work" "${_vip_dir}/vip" "${args[@]}"

	#
	# step 3: cleanup results
	#
	rm -rf "${_vip_output_dir}/.nextflow"

	rm -f "${_controlFileBaseForFunction}.failed"
	mv "${_controlFileBaseForFunction}."{started,finished}
}

function executePostVip () {
	local -r _project="${1}"
	local -r _run="${2}"
	local _controlFileBase="${3}"
	local _controlFileBaseForFunction="${_controlFileBase}.${SCRIPT_NAME}_${FUNCNAME[0]}"

	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi

	local -r _vip_version="v7.7.1"
	local -r _pipeline_software_dir="${TMP_ROOT_DIR}/software/nanopore"
	local -r _vip_dir="${_pipeline_software_dir}/vip/${_vip_version}"
	local -r _reference_fasta="${_vip_dir}/resources/GRCh38/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz"
	local -r _vip_output_dir="${TMP_ROOT_DIR}/projects/nanopore/${_project}/${_run}/results"
	local -r _cram="${_vip_output_dir}/intermediates/${_project}_fam0_sample.cram"

	module load SAMtools/1.16.1-GCCcore-11.3.0
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "creating coverage file"
	local -r _coverage_file="${_vip_output_dir}/${_project}_coverage.tsv"
	samtools coverage --reference "${_reference_fasta}" "${_cram}" > "${_coverage_file}"
	gzip -f "${_coverage_file}"
	
	rsync -v "${TMP_ROOT_DIR}/Samplesheets/nanopore/${_project}.csv" "${TMP_ROOT_DIR}/projects/nanopore/${_project}/${_run}/results/"
	
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "creating depth file"
	local -r _depth_file="${_vip_output_dir}/${_project}_depth.tsv"
	samtools depth --reference "${_reference_fasta}" "${_cram}" > "${_depth_file}"
	gzip -f "${_depth_file}"
	
	
	rm -f "${_controlFileBaseForFunction}.failed"
	mv "${_controlFileBaseForFunction}."{started,finished}
	
}


#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Parsing commandline arguments ..."
declare group=''
while getopts ":g:l:r:h" opt; do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		r)
			pipelineRun="${OPTARG}"
			;;
		l)
			# shellcheck disable=SC2034
			l4b_log_level="${OPTARG^^}"
			# shellcheck disable=SC2034
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
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' 'Must specify a group with -g.'
fi

if [[ -z "${pipelineRun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' 'no runID is given, default is taken (run01).'
	pipelineRun="run01"
fi
#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config files ..."
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
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
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
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."
dateTime=$(date '+%Y-%m-%dT%H:%M:%S')
printf 'Started at %s.\n' "${dateTime}" > "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"

#
# Fetch (new) sample sheets from tmp.
#
declare -a sampleSheets

#
# Parse sample sheets.
#
readarray -t sampleSheets < <(find "${TMP_ROOT_DIR}/Samplesheets/nanopore/" -maxdepth 1 -mindepth 1 -type f -name "*.${SAMPLESHEET_EXT}")

if [[ "${#sampleSheets[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No samplesheets found in ${TMP_ROOT_DIR}/Samplesheets/nanopore/"
else
	for sampleSheet in "${sampleSheets[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing sample sheet: ${sampleSheet} ..."
		project="$(basename "${sampleSheet}" ".${SAMPLESHEET_EXT}")"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing: ${project} ..."
		#
		# Configure logging for this project.
		#
		controlFileBase="${TMP_ROOT_DIR}/logs/${project}/${pipelineRun}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		#
		# Check if we should (re)start the pipeline.
		#
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Skipping already started ${project}/${pipelineRun}."
			continue
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing ${project}/${pipelineRun} ..."
		fi
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${project}/"
		
		printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
		
		executePreVip "${project}" "${pipelineRun}" "${controlFileBase}"
		
		if [[ -e "${JOB_CONTROLE_FILE_BASE}_executePreVip.finished" ]]
		then
			executeVip "${project}" "${pipelineRun}" "${controlFileBase}"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${JOB_CONTROLE_FILE_BASE}_executePreVip.finished absent -> sanityChecking failed."
		fi
		if [[ -e "${JOB_CONTROLE_FILE_BASE}_executeVip.finished" ]]
		then
			executePostVip "${project}" "${pipelineRun}" "${controlFileBase}"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${JOB_CONTROLE_FILE_BASE}_executeVip.finished absent -> sanityChecking failed."
		fi

		if [[ -e "${JOB_CONTROLE_FILE_BASE}_executePostVip.finished" ]]
		then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${JOB_CONTROLE_FILE_BASE}_executePostVip.finished present -> processing completed for project ${project}."
			rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing project ${project}."
			mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
			
			touch "${TMP_ROOT_DIR}/logs/${project}/run01.pipeline.finished"
			touch "${TMP_ROOT_DIR}/logs/${project}/run01.rawDataCopiedToPrm.finished"
		else
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${JOB_CONTROLE_FILE_BASE}_executePostVip.finished absent -> processing failed for project ${project}."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process project ${project}}."
		fi
	done
fi
dateTime=$(date '+%Y-%m-%dT%H:%M:%S')
printf 'Done at %s.\n' "${dateTime}" >> "${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.processing"
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished successfully."
trap - EXIT
exit 0