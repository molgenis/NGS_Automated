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
Script to collect QC data from multiple sources and stores it in a ChronQC datatbase. This database is used to generate ChronQC reports.

Usage:

		$(basename "${0}") OPTIONS

Options:

		-h   Show this help.
		-g   Group.
		-l   Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

		This script needs 3 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg	   for the group specified with -g
		2. <host>.cfg		   for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
		3. sharedConfig.cfg  for all groups and all servers.
		In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================

EOH
		trap - EXIT
		exit 0
}

function processRawdataToDB() {
	local _rawdata="${1}"
	local _sequencer
	_sequencer=$(echo "${_rawdata}" | cut -d '_' -f2)
	CHRONQC_TMP="${TMP_TRENDANALYSE_DIR}/tmp/"
	CHRONQC_DATABASE_NAME="${TMP_TRENDANALYSE_DIR}/database/"
	PRM_RAWDATA_DIR="${PRM_ROOT_DIR}/rawdata/ngs/${_rawdata}/Info/"
	if [[ -e "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_rawdata}, which was already processed."
		return
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_rawdata} ..." \
			2>&1 | tee -a "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.started"
	fi
	if [[ -e "${PRM_RAWDATA_DIR}/SequenceRun_run_date_info.csv"  ]]
	then
		cp "${PRM_RAWDATA_DIR}/SequenceRun_run_date_info.csv" "${CHRONQC_TMP}/${_rawdata}.SequenceRun_run_date_info.csv"
		cp "${PRM_RAWDATA_DIR}/SequenceRun.csv" "${CHRONQC_TMP}/${_rawdata}.SequenceRun.csv"
		if [[ -e "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "found ${PRM_RAWDATA_DIR}/SequenceRun_run_date_info.csv . Updating ChronQC database with ${_rawdata}."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Importing ${_rawdata}.SequenceRun.csv"
			chronqc database --update --db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
				"${CHRONQC_TMP}/${_rawdata}.SequenceRun.csv" \
				--db-table SequenceRun \
				--run-date-info "${CHRONQC_TMP}/${_rawdata}.SequenceRun_run_date_info.csv" \
				"${_sequencer}" || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to import ${_rawdata} with ${_sequencer} stored to Chronqc database." \
						2>&1 | tee -a "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.started"
					mv "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}."{started,failed}
					return
				}
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_rawdata} with ${_sequencer} stored to Chronqc database." \
				2>&1 | tee -a "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.started"
			rm -f "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.failed"
			mv -v "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}."{started,finished}
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.finished."
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Create database for project ${_rawdata}."
			chronqc database --create \
				-o "${CHRONQC_DATABASE_NAME}" \
				"${CHRONQC_TMP}/${_rawdata}.SequenceRun.csv" \
				--run-date-info "${CHRONQC_TMP}/${_rawdata}.SequenceRun_run_date_info.csv" \
				--db-table "SequenceRun" \
				"${_sequencer}" -f || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_rawdata} with ${_sequencer} stored to Chronqc database." \
						2>&1 | tee -a "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.started"
					mv "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}."{started,failed}
					return
				}
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_rawdata} with ${_sequencer} was stored in Chronqc database."
			rm -f "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.failed" \
			mv -v "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}."{started,finished}
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.finished."
		fi
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} for sequence run ${_rawdata}, no sequencer statistics were stored "
	fi
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		echo "rawdata ${_rawdata} is ready. The data is available at ${PRM_ROOT_DIR}/projects/." \
			>> "${JOB_CONTROLE_FILE_BASE}.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.finished. Setting track & trace state to finished :)."
	fi
}


function processProjectToDB() {
	local _project="${1}"
	local _run="${2}"
	CHRONQC_TMP="${TMP_TRENDANALYSE_DIR}/tmp/"
	CHRONQC_DATABASE_NAME="${TMP_TRENDANALYSE_DIR}/database/"
	PRM_MULTIQCPROJECT_DIR="${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/multiqc_data"
	if [[ -e "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_project}/${_run} was already processed. return"
		return
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_project}/${_run} ..." \
			2>&1 | tee -a "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.started"
	fi
	echo "________________${PRM_MULTIQCPROJECT_DIR}/${_project}.run_date_info.csv_____________"
	if [[ -e "${PRM_MULTIQCPROJECT_DIR}/${_project}.run_date_info.csv" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "found ${PRM_MULTIQCPROJECT_DIR}/${_project}.run_date_info.csv. Updating ChronQC database with ${_project}."
		cp "${PRM_MULTIQCPROJECT_DIR}/${_project}.run_date_info.csv" "${CHRONQC_TMP}/${_project}.run_date_info.csv"
		cp "${PRM_MULTIQCPROJECT_DIR}/multiqc_sources.txt" "${CHRONQC_TMP}/${_project}.multiqc_sources.txt"
		for i in "${MULTIQC_METRICS_TO_PLOT[@]}"
		do
			local _metrics="${i%:*}"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "using _metrics: ${_metrics}"
			if [[ "${_metrics}" == multiqc_picard_insertSize.txt ]]
			then
				cp "${PRM_MULTIQCPROJECT_DIR}/${_metrics}" "${CHRONQC_TMP}/${_project}.${_metrics}"
				awk 'BEGIN{FS=OFS="\t"}{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23}' "${CHRONQC_TMP}/${_project}.${_metrics}" > "${CHRONQC_TMP}/${_project}.1.${_metrics}"
				perl -pe 's|SAMPLE_NAME\t|Sample\t|' "${CHRONQC_TMP}/${_project}.1.${_metrics}" > "${CHRONQC_TMP}/${_project}.3.${_metrics}"
				perl -pe 's|SAMPLE\t|SAMPLE_NAME2\t|' "${CHRONQC_TMP}/${_project}.3.${_metrics}" > "${CHRONQC_TMP}/${_project}.2.${_metrics}"
			elif [[ "${_metrics}" == multiqc_general_stats.txt ]]
			then
				cp "${PRM_MULTIQCPROJECT_DIR}/${_metrics}" "${CHRONQC_TMP}/${_project}.${_metrics}"
				head -1 "${CHRONQC_TMP}/${_project}.${_metrics}" > "${CHRONQC_TMP}/${_project}.${_metrics}.tmp"
				#for sample in $(grep HsMetrics "${CHRONQC_TMP}/${_project}.multiqc_sources.txt" | awk -v p="${_project}" '{print $3}'); do grep $sample "${CHRONQC_TMP}/${_project}.${_metrics}" >> "${CHRONQC_TMP}/${_project}.${_metrics}.tmp" ;done
				# to remove the per lane sample id from the ${project}.multiqc_general_stats.txt file
				while read -r sample
				do
					grep "${sample}" "${CHRONQC_TMP}/${_project}.${_metrics}" >> "${CHRONQC_TMP}/${_project}.${_metrics}.tmp"
				done < <(grep HsMetrics "${CHRONQC_TMP}/${_project}.multiqc_sources.txt" | awk -v p="${_project}" '{print $3}')
				mv "${CHRONQC_TMP}/${_project}.${_metrics}.tmp" "${CHRONQC_TMP}/${_project}.2.${_metrics}"
			#	cp "${CHRONQC_TMP}/${_project}.${_metrics}" "${CHRONQC_TMP}/${_project}.2.${_metrics}"
			elif [[ "${_metrics}" == multiqc_fastqc.txt ]]
			then
				cp "${PRM_MULTIQCPROJECT_DIR}/${_metrics}" "${CHRONQC_TMP}/${_project}.${_metrics}"
				# This part will make a run_date_info.csv for only the lane information
				echo -e 'Sample,Run,Date' >> "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv"
				IFS=$'\t' read -ra perLaneSample <<< "$(awk '$1 ~ /.recoded/ {print $1}' "${CHRONQC_TMP}/${_project}.${_metrics}" | tr '\n' '\t')"

				for i in "${perLaneSample[@]}"
				do
					runDate=$(echo "${i}" | cut -d "_" -f 1)
					#echo "${i}"
					#echo "${runDate}"
					echo -e "${i},${_project},${runDate}" >> "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv"
				done
				cp "${CHRONQC_TMP}/${_project}.${_metrics}" "${CHRONQC_TMP}/${_project}.2.${_metrics}"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "using _metrics: ${_metrics} to create ${_project}.lane.run_date_info.csv"

			else
				cp "${PRM_MULTIQCPROJECT_DIR}/${_metrics}" "${CHRONQC_TMP}/${_project}.${_metrics}"
				perl -pe 's|SAMPLE\t|SAMPLE_NAME2\t|' "${CHRONQC_TMP}/${_project}.${_metrics}" > "${CHRONQC_TMP}/${_project}.2.${_metrics}"
			fi
		done
		#
		# Rename one of the duplicated SAMPLE column names to make it work.
		#
		cp "${CHRONQC_TMP}/${_project}.run_date_info.csv" "${CHRONQC_TMP}/${_project}.2.run_date_info.csv"

		#
		# Get all the samples processed with FastQC form the MultiQC multi_source file,
		# because samplenames differ from regular samplesheet at that stage in th epipeline.
		# The Output is converted into standard ChronQC run_date_info.csv format.
		#
		#grep fastqc "${CHRONQC_TMP}/${_project}.multiqc_sources.txt" | awk -v p="${_project}" '{print $3","p","substr($3,1,6)}' >>"${CHRONQC_TMP}/${_project}.2.run_date_info.csv"
		awk 'BEGIN{FS=OFS=","} NR>1{cmd = "date -d \"" $3 "\" \"+%d/%m/%Y\"";cmd | getline out; $3=out; close("uuidgen")} 1' "${CHRONQC_TMP}/${_project}.2.run_date_info.csv" > "${CHRONQC_TMP}/${_project}.2.run_date_info.csv.tmp"
		awk 'BEGIN{FS=OFS=","} NR>1{cmd = "date -d \"" $3 "\" \"+%d/%m/%Y\"";cmd | getline out; $3=out; close("uuidgen")} 1' "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv" > "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv.tmp"

		#
		# Check if the date in the run_date_info.csv file is in correct format, dd/mm/yyyy
		#
		_checkdate=$(awk 'BEGIN{FS=OFS=","} NR==2 {print $3}' "${CHRONQC_TMP}/${_project}.2.run_date_info.csv.tmp")
		echo "_checkdate:${_checkdate}"
		mv "${CHRONQC_TMP}/${_project}.2.run_date_info.csv.tmp" "${CHRONQC_TMP}/${_project}.2.run_date_info.csv"
		_checkdate=$(awk 'BEGIN{FS=OFS=","} NR==2 {print $3}' "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv.tmp")
		echo "_checkdate:${_checkdate}"
		mv "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv.tmp" "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv"

		#
		# Get panel information from $_project} based on column 'capturingKit'.
		#
		_panel=$(awk -F "${SAMPLESHEET_SEP}" 'NR==1 { for (i=1; i<=NF; i++) { f[$i] = i}}{if(NR > 1) print $(f["capturingKit"]) }' "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/${_project}.csv" | sort -u | cut -d'/' -f2)
		IFS='_' read -r -a array <<< "${_panel}"
		if [[ "${array[0]}" == *"Exoom"* ]]
		then
			_panel='Exoom'
		elif [[ "${array[0]}" == *"ONCO"* ]]
		then
			_panel="ONCO"
		elif [[ "${array[0]}" == *"CARDIO"* ]]
		then
			_panel="CARDIO"
		elif [[ "${array[0]}" == *"SVP"* ]]
		then
			_panel="SVP"
		elif [[ "${array[0]}" == *"PCS"* ]]
		then
			_panel="PCS"
		else
			_panel="${array[0]}"
		fi
		echo "PANEL= ${_panel}"
		if [[ "${_checkdate}"  =~ [0-9] ]]
		then
			if [[ -e "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Update database for project ${_project}: panel: ${_panel}."
				for i in "${MULTIQC_METRICS_TO_PLOT[@]}"
				do
					local _metrics="${i%:*}"
					local _table="${i#*:}"
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Importing ${_project}.${_metrics}, and using table ${_table}"
					echo "________________${_metrics}________${_table}_____________"
					if [[ "${_metrics}" == multiqc_fastqc.txt ]]
					then
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "updating  database using _metrics ${_metrics} and _table ${_table}"
						chronqc database --update --db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
							"${CHRONQC_TMP}/${_project}.2.${_metrics}" \
							--db-table "${_table}" \
							--run-date-info "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv" \
							"${_panel}" || {
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to import ${_project}: panel: ${_panel} metrics: ${_metrics} stored to Chronqc database." \
									2>&1 | tee -a "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.started"
								mv "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}."{started,failed}
								return
							}
					else
						chronqc database --update --db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
							"${CHRONQC_TMP}/${_project}.2.${_metrics}" \
							--db-table "${_table}" \
							--run-date-info "${CHRONQC_TMP}/${_project}.2.run_date_info.csv" \
							"${_panel}" || {
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to import ${_project}: panel: ${_panel} stored to Chronqc database." \
									2>&1 | tee -a "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.started"
								mv "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}."{started,failed}
								return
							}
					fi
				done
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_project}: panel: ${_panel} stored to Chronqc database." \
					2>&1 | tee -a "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.started"
				rm -f "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.failed"
				mv -v "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}."{started,finished}
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.finished."

			else
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Create database for project ${_project}: panel: ${_panel}."
				for i in "${MULTIQC_METRICS_TO_PLOT[@]}"
				do

					local _metrics="${i%:*}"
					local _table="${i#*:}"
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "creating database using _metrics: ${_metrics} and _table ${_table}"
					if [[ "${_metrics}" == multiqc_fastqc.txt ]]
					then
						chronqc database --create \
							-o "${CHRONQC_DATABASE_NAME}" \
							"${CHRONQC_TMP}/${_project}.2.${_metrics}" \
							--run-date-info "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv" \
							--db-table "${_table}" \
							"${_panel}" -f || {
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_project}: panel: ${_panel} stored to Chronqc database." \
									2>&1 | tee -a "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.started"
								mv "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}."{started,failed}
								return
							}
					else
						chronqc database --create \
							-o "${CHRONQC_DATABASE_NAME}" \
							"${CHRONQC_TMP}/${_project}.2.${_metrics}" \
							--run-date-info "${CHRONQC_TMP}/${_project}.2.run_date_info.csv" \
							--db-table "${_table}" \
							"${_panel}" -f || {
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_project}: panel: ${_panel} stored to Chronqc database." \
									2>&1 | tee -a "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.started"
								mv "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}."{started,failed}
								return
							}
					fi
				done
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_project}: panel: ${_panel} was stored in Chronqc database."
					rm -f "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.failed"
					mv -v "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}."{started,finished}
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.finished."
			fi
		else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_project}: panel: ${_panel} has date ${_checkdate} this is not fit for chronQC." \
					2>&1 | tee -a "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.started"
				mv -v "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}."{started,incorrectDate}
				return
		fi
	elif [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
	then
		echo "Project/run ${_project}/${_run} is ready. The data is available at ${PRM_ROOT_DIR}/projects/." \
			>> "${JOB_CONTROLE_FILE_BASE}.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.finished. Setting track & trace state to finished :)."
	fi
}

function generateChronQCOutput() {
	local _runinfo="${1}"
	local _tablefile="${2}"
	local _filetype="${3}"
	chronqc database -f --create --run-date-info "${_runinfo}" -o "${CHRONQC_DATABASE_NAME}" --db-table "${_filetype}" "${_tablefile}" "${_filetype}"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "database filled with ${_runinfo}"
	mv "${_runinfo}" "${ARCHIVE_DIR}"
	mv "${_tablefile}" "${ARCHIVE_DIR}"
}


#
## Generates a QC report based in the '-p tablename', and a possible subselection of that table. This is done based on a panel, for example 'Exoom'.
## The layout of the report is configured by the given json config file.
#
function generate_plots() {
	declare configFile="${CHRONQC_TEMPLATE_DIRS}/reports.${HOSTNAME_SHORT}.cfg"
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config file ${configFile} ..."
		#include host specific report commands.
		#shellcheck disable=SC1090
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" "${?}" "Cannot source ${configFile}."
		#shellcheck disable=SC1090
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "ChronQC reports finished."
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
while getopts ":g:l:hn" opt
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
# but before doing the actual data trnasfers.
#

lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/trendanalysis/logs ..."

#
# Use multiplexing to reduce the amount of SSH connections created
# when rsyncing using the group's data manager account.
#
#  1. Become the "${DATA_MANAGER} user who will rsync the data to prm and
#  2. Add to ~/.ssh/config:
#								  ControlMaster auto
#								  ControlPath ~/.ssh/tmp/%h_%p_%r
#								  ControlPersist 5m
#  3. Create ~/.ssh/tmp dir:
#								  mkdir -p -m 700 ~/.ssh/tmp
#  4. Recursively restrict access to the ~/.ssh dir to allow only the owner/user:
#								  chmod -R go-rwx ~/.ssh
#

#
# Get a list of all projects for this group, loop over their run analysis ("run") sub dirs and check if there are any we need to rsync.
#
# shellcheck disable=SC2029

module load "chronqc/${CHRONQC_VERSION}"

#
## Loops over all rawdata folders and checks if it is already in chronQC database. If not than call function 'processRawdataToDB "${rawdata}" to process this project.'
#
readarray -t rawdata < <(find "${PRM_ROOT_DIR}/rawdata/ngs/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${PRM_ROOT_DIR}/rawdata/ngs/||")
if [[ "${#rawdata[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${PRM_ROOT_DIR}/rawdata/ngs/."
else
	for rawdat in "${rawdata[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing rawdat ${rawdat} ..."
		echo "Working on ${rawdat}" > "${lockFile}"
		export TMP_TRENDANALYSE_DIR="${TMP_ROOT_DIR}/trendanalysis"
		export TMP_TRENDANALYSE_LOGS_DIR="${TMP_TRENDANALYSE_DIR}/logs"
		controlFileBase="${TMP_TRENDANALYSE_DIR}/logs/${rawdat}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		export PROCESSRAWDATATODB_CONTROLE_FILE_BASE="${TMP_TRENDANALYSE_DIR}/logs/${rawdat}/${rawdat}.processRawdataToDB"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs folder: ${TMP_TRENDANALYSE_DIR}/logs/${rawdat}/"
		mkdir -p "${TMP_TRENDANALYSE_DIR}/logs/${rawdat}"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${rawdat} ..."
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]] && [[ "${PROCESSRAWDATATODB_CONTROLE_FILE_BASE}.finished" -ot "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${rawdat}."
		else
			processRawdataToDB "${rawdat}"
		fi
	done
fi

#
## Loops over all runs and projects and checks if it is already in chronQC database. If not than call function 'processProjectToDB "${project}" "${run}" to process this project.'
#
readarray -t projects < <(find "${PRM_ROOT_DIR}/projects/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${PRM_ROOT_DIR}/projects/||")
if [[ "${#projects[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${PRM_ROOT_DIR}/projects/."
else
	for project in "${projects[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project} ..."
		echo "Working on ${project}" > "${lockFile}"
		readarray -t runs < <(find "${PRM_ROOT_DIR}/projects/${project}/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${PRM_ROOT_DIR}/projects/${project}/||")
		if [[ "${#runs[@]:-0}" -eq '0' ]]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found for project ${project}."
		else
			for run in "${runs[@]}"
			do
				export TMP_TRENDANALYSE_DIR="${TMP_ROOT_DIR}/trendanalysis"
				export TMP_TRENDANALYSE_LOGS_DIR="${TMP_TRENDANALYSE_DIR}/logs"
				controlFileBase="${TMP_TRENDANALYSE_DIR}/logs/${project}/${run}"
				export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
				export PROCESSPROJECTTODB_CONTROLE_FILE_BASE="${TMP_TRENDANALYSE_DIR}/logs/${project}/${run}.processProjectToDB"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs folder: ${TMP_TRENDANALYSE_DIR}/logs/${project}/"
				mkdir -p "${TMP_TRENDANALYSE_DIR}/logs/${project}"
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project}/${run} ..."
				if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]] && [[ "${PROCESSPROJECTTODB_CONTROLE_FILE_BASE}.finished" -ot "${JOB_CONTROLE_FILE_BASE}.finished" ]]
				then
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${project}/${run}."
				else
					processProjectToDB "${project}" "${run}"
				fi
			done
		fi
	done
fi

#
## Checks directory ${IMPORT_DIR} for new Darwin import files. Than calls function 'generateChronQCOutput "${i}" "${importDir}/${tableFile}" "${fileType}"'
## to process files. After precession the files are moved to archive.
#
mkdir -p "${TMP_TRENDANALYSE_LOGS_DIR}/darwin/"
while read -r i
do
	if [[ -e "${i}" ]]
	then
		runinfoFile=$(basename "${i}" .csv)
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "files to be processed:${runinfoFile}"
		if [[ -e "${TMP_TRENDANALYSE_LOGS_DIR}/darwin/${runinfoFile}.finished" ]]
		then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${runinfoFile} data is already processed"
		else
			fileType=$(cut -d '_' -f1 <<< "${runinfoFile}")
			fileDate=$(cut -d '_' -f3 <<< "${runinfoFile}")
			tableFile="${fileType}_${fileDate}.csv"
			generateChronQCOutput "${i}" "${IMPORT_DIR}/${tableFile}" "${fileType}"
			touch "${TMP_TRENDANALYSE_LOGS_DIR}/darwin/${runinfoFile}.finished"
		fi
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "all files are processed"
	fi
done < <(find "${IMPORT_DIR}"/ -maxdepth 1 -type f -iname "*runinfo*.csv")

#
## Function for generating a list of ChronQC plots.
#
generate_plots

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "cleanup ${CHRONQC_TMP}* ..."
#rm "${CHRONQC_TMP}/"*

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'
echo "" > "${lockFile}"
trap - EXIT
exit 0
