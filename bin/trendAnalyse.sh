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
	local _rawdata_job_controle_line_base="${2}"
	local _sequencer
	_sequencer=$(echo "${_rawdata}" | cut -d '_' -f2)
	CHRONQC_TMP="${TMP_TRENDANALYSE_DIR}/tmp/"
	CHRONQC_DATABASE_NAME="${TMP_TRENDANALYSE_DIR}/database/"
	TMP_RAWDATA_DIR="${TMP_TRENDANALYSE_DIR}/rawdata/${_rawdata}/"
	LOGS_DIR="${TMP_ROOT_DIR}/logs/trendanalysis/"
	
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Removing files from ${CHRONQC_TMP} ..."
	rm -rf "${CHRONQC_TMP:-missing}"/*

	if [[ -e "${TMP_RAWDATA_DIR}/SequenceRun_run_date_info.csv" ]]
	then
		cp "${TMP_RAWDATA_DIR}/SequenceRun_run_date_info.csv" "${CHRONQC_TMP}/${_rawdata}.SequenceRun_run_date_info.csv"
		cp "${TMP_RAWDATA_DIR}/SequenceRun.csv" "${CHRONQC_TMP}/${_rawdata}.SequenceRun.csv"
		if [[ -e "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "found ${TMP_RAWDATA_DIR}/SequenceRun_run_date_info.csv . Updating ChronQC database with ${_rawdata}."
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Importing ${_rawdata}.SequenceRun.csv"
			chronqc database --update --db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
				"${CHRONQC_TMP}/${_rawdata}.SequenceRun.csv" \
				--db-table SequenceRun \
				--run-date-info "${CHRONQC_TMP}/${_rawdata}.SequenceRun_run_date_info.csv" \
				"${_sequencer}" || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to import ${_rawdata} with ${_sequencer} stored to Chronqc database." 
					sed -i "/${_rawdata_job_controle_line_base}/d" "${LOGS_DIR}/process.rawdata_trendanalysis.started"
					echo "${_rawdata_job_controle_line_base}" >> "${LOGS_DIR}/process.rawdata_trendanalysis.failed"
					return
				}
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_rawdata} with ${_sequencer} stored to Chronqc database." 
			sed -i "/${_rawdata_job_controle_line_base}/d" "${LOGS_DIR}/process.rawdata_trendanalysis.failed"
			sed -i "/${_rawdata_job_controle_line_base}/d" "${LOGS_DIR}/process.rawdata_trendanalysis.started"
			echo "${_rawdata_job_controle_line_base}" >> "${LOGS_DIR}/process.rawdata_trendanalysis.finished"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Added ${_rawdata_job_controle_line_base} to rawdata.finished."
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Create database for project ${_rawdata}."
			chronqc database --create \
				-o "${CHRONQC_DATABASE_NAME}" \
				"${CHRONQC_TMP}/${_rawdata}.SequenceRun.csv" \
				--run-date-info "${CHRONQC_TMP}/${_rawdata}.SequenceRun_run_date_info.csv" \
				--db-table SequenceRun \
				"${_sequencer}" -f || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_rawdata} with ${_sequencer} stored to Chronqc database." 
					sed -i "/${_rawdata_job_controle_line_base}/d" "${LOGS_DIR}/process.rawdata_trendanalysis.started"
					echo "${_rawdata_job_controle_line_base}" >> "${LOGS_DIR}/process.rawdata_trendanalysis.failed"
					return
				}
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_rawdata} with ${_sequencer} was stored in Chronqc database."
			sed -i "/${_rawdata_job_controle_line_base}/d" "${LOGS_DIR}/process.rawdata_trendanalysis.failed"
			sed -i "/${_rawdata_job_controle_line_base}/d" "${LOGS_DIR}/process.rawdata_trendanalysis.started"
			echo "${_rawdata_job_controle_line_base}" >> "${LOGS_DIR}/process.rawdata_trendanalysis.finished"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "The line ${_rawdata_job_controle_line_base} added to rawdata.finished."
		fi
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} for sequence run ${_rawdata}, no sequencer statistics were stored "
	fi

}


function processProjectToDB() {
	local _project="${1}"
	local _processprojecttodb_controle_line_base="${2}"
	
	CHRONQC_TMP="${TMP_TRENDANALYSE_DIR}/tmp/"
	CHRONQC_PROJECTS_DIR="${TMP_TRENDANALYSE_DIR}/projects/${_project}/"
	CHRONQC_DATABASE_NAME="${TMP_TRENDANALYSE_DIR}/database/"

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Removing files from ${CHRONQC_TMP} ..."
#	rm -rf "${CHRONQC_TMP:-missing}"/*

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "__________processing ${_project}.run_date_info.csv_____________"
	if [[ -e "${CHRONQC_PROJECTS_DIR}/${_project}.run_date_info.csv" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "found ${CHRONQC_PROJECTS_DIR}/${_project}.run_date_info.csv. Updating ChronQC database with ${_project}."
		cp "${CHRONQC_PROJECTS_DIR}/${_project}.run_date_info.csv" "${CHRONQC_TMP}/${_project}.run_date_info.csv"
		cp "${CHRONQC_PROJECTS_DIR}/multiqc_sources.txt" "${CHRONQC_TMP}/${_project}.multiqc_sources.txt"
		for multiQC in "${MULTIQC_METRICS_TO_PLOT[@]}"
		do
			local _metrics="${multiQC%:*}"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "using _metrics: ${_metrics}"
			if [[ "${_metrics}" == multiqc_picard_insertSize.txt ]]
			then
				cp "${CHRONQC_PROJECTS_DIR}/${_metrics}" "${CHRONQC_TMP}/${_project}.${_metrics}"
#				awk 'BEGIN{FS=OFS="\t"}{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25}' "${CHRONQC_TMP}/${_project}.${_metrics}" > "${CHRONQC_TMP}/${_project}.1.${_metrics}"
#				perl -pe 's|SAMPLE_NAME\t|Sample\t|' "${CHRONQC_TMP}/${_project}.1.${_metrics}" > "${CHRONQC_TMP}/${_project}.3.${_metrics}"
				awk '{$1=""}1' "${CHRONQC_TMP}/${_project}.${_metrics}" | awk '{$1=$1}{OFS="\t"}1' > "${CHRONQC_TMP}/${_project}.1.${_metrics}"
				perl -pe 's|SAMPLE_NAME\t|Sample\t|' "${CHRONQC_TMP}/${_project}.1.${_metrics}" > "${CHRONQC_TMP}/${_project}.3.${_metrics}"
				perl -pe 's|SAMPLE\t|SAMPLE_NAME2\t|' "${CHRONQC_TMP}/${_project}.3.${_metrics}" > "${CHRONQC_TMP}/${_project}.2.${_metrics}"
			elif [[ "${_metrics}" == multiqc_fastqc.txt ]]
			then
				cp "${CHRONQC_PROJECTS_DIR}/${_metrics}" "${CHRONQC_TMP}/${_project}.${_metrics}"
				# This part will make a run_date_info.csv for only the lane information
				echo -e 'Sample,Run,Date' >> "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv"
				IFS=$'\t' read -ra perLaneSample <<< "$(awk '$1 ~ /.recoded/ {print $1}' "${CHRONQC_TMP}/${_project}.${_metrics}" | tr '\n' '\t')"

				for laneSample in "${perLaneSample[@]}"
				do
					runDate=$(echo "${laneSample}" | cut -d "_" -f 1)
					echo -e "${laneSample},${_project},${runDate}" >> "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv"
				done
				cp "${CHRONQC_TMP}/${_project}.${_metrics}" "${CHRONQC_TMP}/${_project}.2.${_metrics}"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "using _metrics: ${_metrics} to create ${_project}.lane.run_date_info.csv"

			else
				cp "${CHRONQC_PROJECTS_DIR}/${_metrics}" "${CHRONQC_TMP}/${_project}.${_metrics}"
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
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "_checkdate:${_checkdate}"
		mv "${CHRONQC_TMP}/${_project}.2.run_date_info.csv.tmp" "${CHRONQC_TMP}/${_project}.2.run_date_info.csv"
		_checkdate=$(awk 'BEGIN{FS=OFS=","} NR==2 {print $3}' "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv.tmp")
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "_checkdate:${_checkdate}"
		mv "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv.tmp" "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv"

		#
		# Get panel information from $_project} based on column 'capturingKit'.
		#
		_panel=$(awk -F "${SAMPLESHEET_SEP}" 'NR==1 { for (i=1; i<=NF; i++) { f[$i] = i}}{if(NR > 1) print $(f["capturingKit"]) }' "${CHRONQC_PROJECTS_DIR}/${_project}.csv" | sort -u | cut -d'/' -f2)
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
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "PANEL= ${_panel}"
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
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "________________${_metrics}________${_table}_____________"
					if [[ "${_metrics}" == multiqc_fastqc.txt ]]
					then
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "updating  database using _metrics ${_metrics} and _table ${_table}"
						chronqc database --update --db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
							"${CHRONQC_TMP}/${_project}.2.${_metrics}" \
							--db-table "${_table}" \
							--run-date-info "${CHRONQC_TMP}/${_project}.lane.run_date_info.csv" \
							"${_panel}" || {
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to import ${_project}: panel: ${_panel} metrics: ${_metrics} stored to Chronqc database." 
								sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.started"
								echo "${_processprojecttodb_controle_line_base}" >> "${LOGS_DIR}/process.project_trendanalysis.failed"
								return
							}
					elif [[ -f "${CHRONQC_TMP}/${_project}.2.${_metrics}" ]]
					then
						chronqc database --update --db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
							"${CHRONQC_TMP}/${_project}.2.${_metrics}" \
							--db-table "${_table}" \
							--run-date-info "${CHRONQC_TMP}/${_project}.2.run_date_info.csv" \
							"${_panel}" || {
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to import ${_project}: panel: ${_panel} stored to Chronqc database." 
								sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.started"
								echo "${_processprojecttodb_controle_line_base}" >> "${LOGS_DIR}/process.project_trendanalysis.failed"
								return
							}
					else
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "The file ${CHRONQC_TMP}/${_project}.2.${_metrics} does not exist, so can't be added to the database"
						continue
					fi
				done
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_project}: panel: ${_panel} stored to Chronqc database." 
				sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.failed"
				sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.started"
				echo "${_processprojecttodb_controle_line_base}" >> "${LOGS_DIR}/process.project_trendanalysis.finished"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Added ${_processprojecttodb_controle_line_base} to the .finished file."

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
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_project}: panel: ${_panel} stored to Chronqc database." 
								sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.started"
								echo "${_processprojecttodb_controle_line_base}" >> "${LOGS_DIR}/process.project_trendanalysis.failed"
								return
							}
					elif [[ -f "${CHRONQC_TMP}/${_project}.2.${_metrics}" ]]
					then
						chronqc database --create \
							-o "${CHRONQC_DATABASE_NAME}" \
							"${CHRONQC_TMP}/${_project}.2.${_metrics}" \
							--run-date-info "${CHRONQC_TMP}/${_project}.2.run_date_info.csv" \
							--db-table "${_table}" \
							"${_panel}" -f || {
								log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_project}: panel: ${_panel} stored to Chronqc database." 
								sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.started"
								echo "${_processprojecttodb_controle_line_base}" >> "${LOGS_DIR}/process.project_trendanalysis.failed"
								return
							}
					else
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "The file ${CHRONQC_TMP}/${_project}.2.${_metrics} does not exist, so can't be added to the database"
						continue
					fi
				done
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} ${_project}: panel: ${_panel} was stored in Chronqc database."
					sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.failed"
					sed -i "/${_processprojecttodb_controle_line_base}/d" "${LOGS_DIR}/process.project_trendanalysis.started"
					echo "${_processprojecttodb_controle_line_base}" >> "${LOGS_DIR}/process.project_trendanalysis.finished"
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Added ${_processprojecttodb_controle_line_base} to the .finished file."
			fi
		else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_project}: panel: ${_panel} has date ${_checkdate} this is not fit for chronQC." 
				echo "${_processprojecttodb_controle_line_base}.incorrectDate" >> "${LOGS_DIR}/process.project_trendanalysis.failed"
				return
		fi
	elif grep -Fxq "${_processprojecttodb_controle_line_base}" "${LOGS_DIR}/process.project_trendanalysis.finished"
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_processprojecttodb_controle_line_base} in the .finished file. :)."
	fi
}

function processDarwinToDB() {
	local _runinfo="${1}"
	local _tablefile="${2}"
	local _filetype="${3}"
	local _fileDate="${4}"
	local _darwin_job_controle_line_base="${5}"
	CHRONQC_TMP="${TMP_TRENDANALYSE_DIR}/tmp/"

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Removing files from ${CHRONQC_TMP} ..."
	rm -rf "${CHRONQC_TMP:-missing}"/*
	
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "local variables generateChronQCOutput:_runinfo=${_runinfo},_tablefile=${_tablefile}, _filetype=${_filetype}, _fileDate=${_fileDate}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "starting to fille the trendanalysis database with :${_runinfo} and ${_tablefile}}"

	if [[ "${_filetype}"  == 'ArrayInzetten' ]]
	then

		head -1 "${_runinfo}" > "${CHRONQC_TMP}/ArrayInzettenLabpassed_runinfo_${_fileDate}.csv"
		head -1 "${_tablefile}" > "${CHRONQC_TMP}/ArrayInzettenLabpassed_${_fileDate}.csv"
		
		grep labpassed "${_runinfo}" >> "${CHRONQC_TMP}/ArrayInzettenLabpassed_runinfo_${_fileDate}.csv"
		grep labpassed "${_tablefile}" >> "${CHRONQC_TMP}/ArrayInzettenLabpassed_${_fileDate}.csv"
		

		if [[ -e "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "updating database with ${CHRONQC_TMP}/${_filetype}_${_fileDate}.csv"
			chronqc database -f --update \
				--db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
				--run-date-info "${_runinfo}" \
				-o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}All" \
				"${_tablefile}" all || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
				
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "updating database with ${CHRONQC_TMP}/${_filetype}Labpassed_${_fileDate}.csv"
			chronqc database -f --update \
				--db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
				--run-date-info "${CHRONQC_TMP}/ArrayInzettenLabpassed_runinfo_${_fileDate}.csv" \
				-o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}Labpassed" \
				"${CHRONQC_TMP}/ArrayInzettenLabpassed_${_fileDate}.csv" labpassed || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.failed"
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
				echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.finished"
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "creating database starting with ${CHRONQC_TMP}/${_filetype}_${_fileDate}.csv"
			chronqc database -f --create \
				--run-date-info "${_runinfo}" \
				--o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}All" \
				"${_tablefile}" all || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
			
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "creating database starting with ${CHRONQC_TMP}/${_filetype}Labpassed_${_fileDate}.csv"
			chronqc database -f --create \
				--run-date-info "${CHRONQC_TMP}/ArrayInzettenLabpassed_runinfo_${_fileDate}.csv" \
				--o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}Labpassed" \
				"${CHRONQC_TMP}/ArrayInzettenLabpassed_${_fileDate}.csv" labpassed || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.failed"
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
				echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.finished"
		fi
		
	elif [[ "${_filetype}" == 'Concentratie' ]]
	then
		# for now the database will be filled with only the concentration information from the Nimbus2000	

		head -1 "${_runinfo}" > "${CHRONQC_TMP}/ConcentratieNimbus_runinfo_${_fileDate}.csv"
		head -1 "${_tablefile}" > "${CHRONQC_TMP}/ConcentratieNimbus_${_fileDate}.csv"

		grep Nimbus "${_runinfo}" >> "${CHRONQC_TMP}/ConcentratieNimbus_runinfo_${_fileDate}.csv"
		grep Nimbus "${_tablefile}" >> "${CHRONQC_TMP}/ConcentratieNimbus_${_fileDate}.csv"
		
		if [[ -e "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "updating database with ${CHRONQC_TMP}/${_filetype}Nimbus_${_fileDate}.csv"
			chronqc database -f --update \
				--db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
				--run-date-info "${CHRONQC_TMP}/ConcentratieNimbus_runinfo_${_fileDate}.csv" \
				-o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}" \
				"${CHRONQC_TMP}/ConcentratieNimbus_${_fileDate}.csv" Nimbus || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.failed"
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
				echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.finished"
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "creating database starting with ${CHRONQC_TMP}/${_filetype}Nimbus_${_fileDate}.csv"
			chronqc database -f --create \
				--run-date-info "${CHRONQC_TMP}/ConcentratieNimbus_runinfo_${_fileDate}.csv" \
				--o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}" \
				"${CHRONQC_TMP}/ConcentratieNimbus_${_fileDate}.csv" Nimbus || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.failed"
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
				echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.finished"
		fi

		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "database filled with ConcentratieNimbus_${_fileDate}.csv"
	else
		if [[ -e "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "updating database with ${CHRONQC_TMP}/${_filetype}_${_fileDate}.csv"
			chronqc database -f --update \
				--db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
				--run-date-info "${_runinfo}" \
				-o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}" \
				"${_tablefile}" NGSlab || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database."
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.failed"
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
				echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.finished"

		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "creating database starting with ${CHRONQC_TMP}/${_filetype}_${_fileDate}.csv"
			chronqc database -f --create \
				--run-date-info "${_runinfo}" \
				--o "${CHRONQC_DATABASE_NAME}" \
				--db-table "${_filetype}" \
				"${_tablefile}" NGSlab || {
					log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database."
					sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
					echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.failed"
					return
					}
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.failed"
				sed -i "/${_darwin_job_controle_line_base}/d" "${LOGS_DIR}/process.darwin_trendanalysis.started"
				echo "${_darwin_job_controle_line_base}" >> "${LOGS_DIR}/process.darwin_trendanalysis.finished"
		fi
	fi

}


function processDragenToDB() {

	local _runinfo="${1}"
	local _tablefile="${2}"
	local _dragen_job_controle_line_base="${3}"
	CHRONQC_TMP="${TMP_TRENDANALYSE_DIR}/tmp/"
	
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Removing files from ${CHRONQC_TMP} ..."
	rm -rf "${CHRONQC_TMP:-missing}"/*

	
	if [[ -e "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" ]]
	then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "updating database with ${_runinfo}.csv"
		chronqc database -f --update \
			--db "${CHRONQC_DATABASE_NAME}/chronqc_db/chronqc.stats.sqlite" \
			--run-date-info "${_runinfo}" \
			-o "${CHRONQC_DATABASE_NAME}" \
			--db-table Dragen \
			"${_tablefile}" Dragen || {
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
				sed -i "/${_dragen_job_controle_line_base}/d" "${LOGS_DIR}/process.dragen_trendanalysis.started"
				echo "${_dragen_job_controle_line_base}" >> "${LOGS_DIR}/process.dragen_trendanalysis.failed"
				return
				}
			sed -i "/${_dragen_job_controle_line_base}/d" "${LOGS_DIR}/process.dragen_trendanalysis.failed"
			sed -i "/${_dragen_job_controle_line_base}/d" "${LOGS_DIR}/process.dragen_trendanalysis.started"
			echo "${_dragen_job_controle_line_base}" >> "${LOGS_DIR}/process.dragen_trendanalysis.finished"

	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "creating database starting with ${CHRONQC_TMP}/${_runinfo}.csv"
		chronqc database -f --create \
			--run-date-info "${_runinfo}" \
			--o "${CHRONQC_DATABASE_NAME}" \
			--db-table Dragen \
			"${_tablefile}" Dragen || {
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create database and import ${_runinfo} to Chronqc database." 
				sed -i "/${_dragen_job_controle_line_base}/d" "${LOGS_DIR}/process.dragen_trendanalysis.started"
				echo "${_dragen_job_controle_line_base}" >> "${LOGS_DIR}/process.dragen_trendanalysis.failed"
				return
				}
			sed -i "/${_dragen_job_controle_line_base}/d" "${LOGS_DIR}/process.dragen_trendanalysis.failed"
			sed -i "/${_dragen_job_controle_line_base}/d" "${LOGS_DIR}/process.dragen_trendanalysis.started"
			echo "${_dragen_job_controle_line_base}" >> "${LOGS_DIR}/process.dragen_trendanalysis.finished"
	fi

}


function generateReports() {

	local _job_controle_file_base="${1}"
	# shellcheck disable=SC1091
	source "${CHRONQC_TEMPLATE_DIRS}/reports.sh" || { 
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to create all reports from the Chronqc database." \
			2>&1 | tee -a "${_job_controle_file_base}.started"
		mv "${_job_controle_file_base}."{started,failed}
		return
	}

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "ChronQC reports finished."
	mv "${_job_controle_file_base}."{started,finished}
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

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
#MULTIPLE_PRMS

TMP_TRENDANALYSE_DIR="${TMP_ROOT_DIR}/trendanalysis/"
LOGS_DIR="${TMP_ROOT_DIR}/logs/trendanalysis/"
mkdir -p "${TMP_ROOT_DIR}/logs/trendanalysis/"

readarray -t rawdataArray < <(find "${TMP_TRENDANALYSE_DIR}/rawdata/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_TRENDANALYSE_DIR}/rawdata/||")
if [[ "${#rawdataArray[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_TRENDANALYSE_DIR}/rawdata/."
else
	for rawdata in "${rawdataArray[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing rawdata ${rawdata} ..."
		echo "Working on ${rawdata}" > "${lockFile}"
		RAWDATA_JOB_CONTROLE_LINE_BASE="${rawdata}.${SCRIPT_NAME}_processRawdatatoDB"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs line: ${RAWDATA_JOB_CONTROLE_LINE_BASE}"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${rawdata} ..."
		touch "${LOGS_DIR}/process.rawdata_trendanalysis.finished"
		touch "${LOGS_DIR}/process.rawdata_trendanalysis.failed"
		touch "${LOGS_DIR}/process.rawdata_trendanalysis.started"
		
		if grep -Fxq "${RAWDATA_JOB_CONTROLE_LINE_BASE}" "${LOGS_DIR}/process.rawdata_trendanalysis.finished"
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${rawdata}."
		else
			echo "${RAWDATA_JOB_CONTROLE_LINE_BASE}" >> "${LOGS_DIR}/process.rawdata_trendanalysis.started"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "New batch ${rawdata} will be processed."
			processRawdataToDB "${rawdata}" "${RAWDATA_JOB_CONTROLE_LINE_BASE}"
		fi
	done
fi


#
## Loops over all runs and projects and checks if it is already in chronQC database. If not than call function 'processProjectToDB "${project}" "${run}" to process this project.'
#


readarray -t projects < <(find "${TMP_TRENDANALYSE_DIR}/projects/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_TRENDANALYSE_DIR}/projects/||")
if [[ "${#projects[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_TRENDANALYSE_DIR}/projects/."
else
	for project in "${projects[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project} ..."
		echo "Working on ${project}" > "${lockFile}"
		PROCESSPROJECTTODB_CONTROLE_LINE_BASE="${project}.${SCRIPT_NAME}_processProjectToDB"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs line: ${PROCESSPROJECTTODB_CONTROLE_LINE_BASE}"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project}/ ..."
		touch "${LOGS_DIR}/process.project_trendanalysis.finished"
		touch "${LOGS_DIR}/process.project_trendanalysis.failed"
		touch "${LOGS_DIR}/process.project_trendanalysis.started"
		if grep -Fxq "${PROCESSPROJECTTODB_CONTROLE_LINE_BASE}" "${LOGS_DIR}/process.project_trendanalysis.finished"
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed project ${project}."
		else
			echo "${PROCESSPROJECTTODB_CONTROLE_LINE_BASE}" >> "${LOGS_DIR}/process.project_trendanalysis.started"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "New project ${project} will be processed."
			processProjectToDB "${project}" "${PROCESSPROJECTTODB_CONTROLE_LINE_BASE}"
		fi
	done
fi


#
## Checks for new Darwin import files. Than calls function 'processDarwinToDB'
## to add the new files to the database
#


readarray -t darwindata < <(find "${TMP_TRENDANALYSE_DIR}/darwin/" -maxdepth 1 -mindepth 1 -type f -name "*runinfo*" | sed -e "s|^${TMP_TRENDANALYSE_DIR}/darwin/||")
if [[ "${#darwindata[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_TRENDANALYSE_DIR}/darwin/."
else
	for darwinfile in "${darwindata[@]}"
	do
		runinfoFile=$(basename "${darwinfile}" .csv)
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "files to be processed:${runinfoFile}"
		fileType=$(cut -d '_' -f1 <<< "${runinfoFile}")
		fileDate=$(cut -d '_' -f3 <<< "${runinfoFile}")
		tableFile="${fileType}_${fileDate}.csv"
		DARWIN_JOB_CONTROLE_LINE_BASE="${fileType}_${fileDate}.${SCRIPT_NAME}_processDarwinToDB"
		touch "${LOGS_DIR}/process.darwin_trendanalysis.finished"
		touch "${LOGS_DIR}/process.darwin_trendanalysis.failed"
		touch "${LOGS_DIR}/process.darwin_trendanalysis.started"
		if grep -Fxq "${DARWIN_JOB_CONTROLE_LINE_BASE}" "${LOGS_DIR}/process.darwin_trendanalysis.finished"
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed darwin data from ${fileDate}."
		else
			echo "${DARWIN_JOB_CONTROLE_LINE_BASE}" >> "${LOGS_DIR}/process.darwin_trendanalysis.started"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "New darwin data from ${fileDate} will be processed."
			processDarwinToDB "${TMP_TRENDANALYSE_DIR}/darwin/${darwinfile}" "${TMP_TRENDANALYSE_DIR}/darwin/${tableFile}" "${fileType}" "${fileDate}" "${DARWIN_JOB_CONTROLE_LINE_BASE}"
		fi
	done
fi



#
## Checks dragen data, and adds the new files to the database
#

readarray -t dragendata < <(find "${TMP_TRENDANALYSE_DIR}/dragen/" -maxdepth 1 -mindepth 1 -type d -name "[!.]*" | sed -e "s|^${TMP_TRENDANALYSE_DIR}/dragen/||")
if [[ "${#dragendata[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_TRENDANALYSE_DIR}/dragen/."
else
	for dragenProject in "${dragendata[@]}"
	do
		runinfoFile="${dragenProject}".Dragen_runinfo.csv
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "files to be processed:${runinfoFile}"
		tableFile="${dragenProject}".Dragen.csv
		DRAGEN_JOB_CONTROLE_LINE_BASE="${dragenProject}.${SCRIPT_NAME}_processDragenToDB"
		touch "${LOGS_DIR}/process.dragen_trendanalysis.finished"
		touch "${LOGS_DIR}/process.dragen_trendanalysis.failed"
		touch "${LOGS_DIR}/process.dragen_trendanalysis.started"
		if grep -Fxq "${DRAGEN_JOB_CONTROLE_LINE_BASE}" "${LOGS_DIR}/process.dragen_trendanalysis.finished"
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed dragen project ${dragenProject}."
		else
			echo "${DRAGEN_JOB_CONTROLE_LINE_BASE}" >> "${LOGS_DIR}/process.dragen_trendanalysis.started"
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "New dragen project ${dragenProject} will be processed."
			processDragenToDB "${TMP_TRENDANALYSE_DIR}/dragen/${dragenProject}/${runinfoFile}" "${TMP_TRENDANALYSE_DIR}/dragen/${dragenProject}/${tableFile}" "${DRAGEN_JOB_CONTROLE_LINE_BASE}"
		fi
	done
fi

CHRONQC_TMP="${TMP_TRENDANALYSE_DIR}/tmp/"
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "cleanup ${CHRONQC_TMP}* ..."
#rm -rf "${CHRONQC_TMP:-missing}"/*

#
## Function for generating a list of ChronQC plots.
#


today=$(date '+%Y%m%d')
JOB_CONTROLE_FILE_BASE="${LOGS_DIR}/generate_plots.${today}_${SCRIPT_NAME}"

if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
then
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already generated plots on ${today}."
else
	touch "${JOB_CONTROLE_FILE_BASE}.started"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "New trendanalysis plots will be generated on ${today}."
	generateReports "${JOB_CONTROLE_FILE_BASE}"
fi




trap - EXIT
exit 0
