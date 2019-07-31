#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename ${0})"
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
	source "${LIB_DIR}/sharedFunctions.bash"
else
	printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
	trap - EXIT
	exit 1
fi

#
# Determine if samplesheet merging is possible for this sequence run, which is the case when
#  1. Corresponding samplesheets are present in the Samplesheets dir.
#  2. Samplesheets are Ok.
#  3. Integrity of the FastQ files is Ok as determined using validation of their checksums.
#
function sanityChecking() {
	#
	local _batch="${1}"
	local _controlFileBase="${2}"
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME}"
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing batch ${_batch}..."
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${FUNCNAME} ${_batch}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	#
	# Check if one sane GS samplesheet is present.
	#
	local _numberOfSamplesheets=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/CSV_UMCG_"*".${SAMPLESHEET_EXT}" 2>/dev/null | wc -l)
	local _gsSampleSheet
	if [[ "${_numberOfSamplesheets}" -eq 1 ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found: one ${TMP_ROOT_DIR}/${_batch}/CSV_UMCG_*.${SAMPLESHEET_EXT} samplesheet."
		_gsSampleSheet=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/CSV_UMCG_"*".${SAMPLESHEET_EXT}")
		#
		# Make sure:
		#  1. The last line ends with a line end character.
		#  2. We have the right line end character: convert any carriage return (\r) to newline (\n).
		#  3. We remove empty lines: lines containing only white space and/or field separators are considered empty too.
		#
		cp "${_gsSampleSheet}"{,.converted} \
			2>> "${_controlFileBaseForFunction}.started" \
			&& printf '\n' \
			2>> "${_controlFileBaseForFunction}.started" \
			>> "${_gsSampleSheet}.converted" \
			&& sed -i 's/\r/\n/g' "${_gsSampleSheet}.converted" \
			2>> "${_controlFileBaseForFunction}.started" \
			&& sed -i "/^[\s${SAMPLESHEET_SEP}]*$/d" "${_gsSampleSheet}.converted" \
			2>> "${_controlFileBaseForFunction}.started" \
			&& mv -f "${_gsSampleSheet}"{.converted,} \
			2>> "${_controlFileBaseForFunction}.started" \
		|| { log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "Failed to convert line end characters and/or remove empty lines for ${_gsSampleSheet}." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
	elif [[ "${_numberOfSamplesheets}" -gt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "More than one CSV_UMCG_*.${SAMPLESHEET_EXT} GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	elif [[ "${_numberOfSamplesheets}" -lt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "No GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Count FastQ files present on disk for each read of a pair.
	#
	local _countFastQ1FilesOnDisk=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/"*'_R1.fastq.gz' | wc -l)
	local _countFastQ2FilesOnDisk=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/"*'_R2.fastq.gz' | wc -l)
	if [[ "${_countFastQ1FilesOnDisk}" -ne "${_countFastQ2FilesOnDisk}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Amount of R1 FastQ files (${_countFastQ1FilesOnDisk}) is not the same as R2 FastQ files (${_countFastQ2FilesOnDisk})." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Check if checksum file is present and if we have enough checksums for the amount of FastQ files received.
	# (No need to waist a lot of time on computing checksums for a partially failed transfer).
	#
	local _checksumFile="${TMP_ROOT_DIR}/${_batch}/checksums.md5"
	local _countFastQFilesInChecksumFile='0'
	if [[ -e "${_checksumFile}" && -r "${_checksumFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_checksumFile}."
		_countFastQFilesInChecksumFile=$(grep '_R[1-2].fastq.gz' "${_checksumFile}" | wc -l)
		if [[ "${_countFastQFilesInChecksumFile}" -ne "$((${_countFastQ1FilesOnDisk} + ${_countFastQ2FilesOnDisk}))" ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Mismatch: found ${_countFastQFilesInChecksumFile} FastQ files in checksum file, but ${_countFastQ1FilesOnDisk} *_R1.fastq.gz and ${_countFastQ2FilesOnDisk} *_R2.fastq.gz files on disk." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Amount of FastQ files in checksum file and amount of *_R[1|2].fastq.gz files on disk is the same for ${_batch}: ${_countFastQFilesInChecksumFile}."
		fi
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "No ${_checksumFile} file present in ${TMP_ROOT_DIR}/${_batch}/." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Count and make sure all samples for which we received FastQ files on disk are present in the samplesheet and vice versa.
	# _insaneSamples is a string of sample IDs only present either on disk or on the samplesheet.
	#
	declare -a _samplesOnDisk=($(ls -1 "${TMP_ROOT_DIR}/${_batch}/"*'.fastq.gz' | grep -o "${_batch}-[0-9][0-9]*" | sort -u))
	declare -a _samplesInSamplesheet=($(grep -o "${_batch}-[0-9][0-9]*" "${TMP_ROOT_DIR}/${_batch}/CSV_UMCG_"*".${SAMPLESHEET_EXT}" | sort -u))
	local _insaneSamples="$(echo ${_samplesOnDisk[@]} ${_samplesInSamplesheet[@]} | tr ' ' '\n' | sort | uniq -u | tr '\n' ' ')"
	if [[ ! -z "${_insane_samples:-}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Mismatch: sample(s) ${_insaneSamples} are either present in the samplesheet, but missing on disk or vice versa." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "All samples present in the samplesheet are also present on disk and vice versa."
	fi
	#
	# Verify checksums for the transfered data.
	#
	local _checksumVerification='unknown'
	if [[ -e "${_controlFileBaseForFunction}.md5.PASS" ]]
	then
		_checksumVerification='PASS'
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBaseForFunction}.md5.PASS absent -> start checksum verification..."
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Started verification of checksums by ${ATEAMBOTUSER}@${HOSTNAME_SHORT} using checksums from ${TMP_ROOT_DIR}/${_batch}/${_checksumFile}"
		_checksumVerification=$(cd ${TMP_ROOT_DIR}/${_batch}/
			if md5sum -c "${_checksumFile}" >> "${_controlFileBaseForFunction}.started" 2>&1
			then
				echo 'PASS'
				touch "${_controlFileBaseForFunction}.md5.PASS"
			else
				echo 'FAILED'
			fi
		)
	fi
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "_checksumVerification = ${_checksumVerification}"
	if [[ "${_checksumVerification}" != 'PASS' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${_controlFileBaseForFunction}.failed for details." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Parse GS samplesheet to get a list of project values.
	#
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_gsSampleSheet}"))
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	#
	# Check if GS samplesheet contains required project column.
	#
	if [[ ! -z "${_sampleSheetColumnOffsets['Sample_ID']+isset}" ]]
	then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets['Sample_ID']} + 1))
		IFS=$'\n' _projects=($(tail -n +2 "${_gsSampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sort | uniq ))
		if [[ "${#_projects[@]:-0}" -lt '1' ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_gsSampleSheet} does not contain at least one project value." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "project column missing in ${_gsSampleSheet}." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Initialize (and potentially reset/truncate) files with values for columns that are only allowed to contain a single value for all rows.
	#
	local _requiredColumnName
	for _requiredColumnName in "${!requiredSamplesheetColumns[@]}"
	do
		if [[ "${requiredSamplesheetColumns[${_requiredColumnName}]}" == 'single' ]]
		then
			printf '' > "${_controlFileBase}.${_requiredColumnName}"
		fi
	done
	#
	# Check if project samplesheet is present and sane for all projects.
	#
	local _project
	for _project in "${_projects[@]}"
	do
		#
		# ToDo: change location of sample sheet per project back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
		local _sampleSheet="${TMP_ROOT_DIR}/Samplesheets/new/${_project}.${SAMPLESHEET_EXT}"
		if [[ -f "${_sampleSheet}" && -r "${_sampleSheet}" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} is present."
			#
			# Make sure
			#  1. The last line ends with a line end character.
			#  2. We have the right line end character: convert any carriage return (\r) to newline (\n).
			#  3. We remove empty lines: lines containing only white space and/or field separators are considered empty too.
			#
			cp "${_sampleSheet}"{,.converted} \
				2>> "${_controlFileBaseForFunction}.started" \
				&& printf '\n' \
				2>> "${_controlFileBaseForFunction}.started" \
				>> "${_sampleSheet}.converted" \
				&& sed -i 's/\r/\n/g' "${_sampleSheet}.converted" \
				2>> "${_controlFileBaseForFunction}.started" \
				&& sed -i "/^[\s${SAMPLESHEET_SEP}]*$/d" "${_sampleSheet}.converted" \
				2>> "${_controlFileBaseForFunction}.started" \
				&& mv -f "${_sampleSheet}"{.converted,} \
				2>> "${_controlFileBaseForFunction}.started" \
			|| { log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "Failed to convert line end characters and/or remove empty lines for ${_sampleSheet}." \
					2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
					&& mv "${_controlFileBaseForFunction}."{started,failed}
				return
			}
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} is missing or not accessible." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
		#
		# Get fields (columns) from samplesheet.
		#
		declare -a _sampleSheetColumnNames=()
		declare -A _sampleSheetColumnOffsets=()
		IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_sampleSheet}"))
		for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
		do
			_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
		done
		#
		# Get number of lines/rows with values (e.g. all lines except the header line).
		#
		_sampleSheetNumberOfRows=$(tail -n +2 "${_sampleSheet}" | wc -l)
		#
		# Check if required columns contain the expected amount of values:
		#    either 'any' value
		#    or the same value for all rows/samples
		#    or no value.
		#
		for _requiredColumnName in "${!requiredSamplesheetColumns[@]}"
		do
			local _requiredColumnValueState="${requiredSamplesheetColumns[${_requiredColumnName}]}"
			declare -a _requiredColumnValues=()
			local      _requiredColumnIndex
			
			if [[ -z "${_sampleSheetColumnOffsets[${_requiredColumnName}]+isset}" ]]
			then
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Required column ${_requiredColumnName} missing in ${_sampleSheet} -> Skipping ${_batch} due to error in samplesheet." \
					2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
					&& mv "${_controlFileBaseForFunction}."{started,failed}
				return
			else
				_requiredColumnIndex=$((${_sampleSheetColumnOffsets["${_requiredColumnName}"]} + 1))
				if [[ "${_requiredColumnValueState}" == 'present' ]]
				then
					IFS=$'\n' _requiredColumnValues=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_requiredColumnIndex}"))
					if [[ "${#_requiredColumnValues[@]:-0}" -ne "${_sampleSheetNumberOfRows}" ]]
					then
						log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Column ${_requiredColumnName} in ${_sampleSheet} does NOT contain the expected amount of values: ${_sampleSheetNumberOfRows}." \
							2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
							&& mv "${_controlFileBaseForFunction}."{started,failed}
						return
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Column ${_requiredColumnName} contains the right amount of values: ${_sampleSheetNumberOfRows}."
					fi
				elif [[ "${_requiredColumnValueState}" == 'single' ]]
				then
					IFS=$'\n' _requiredColumnValues=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_requiredColumnIndex}" | sort | uniq ))
					if [[ "${#_requiredColumnValues[@]:-0}" -ne '1' ]]
					then
						log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Column ${_requiredColumnName} in ${_sampleSheet} must contain the same value for all samples/rows." \
							2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
							&& mv "${_controlFileBaseForFunction}."{started,failed}
						return
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Column ${_requiredColumnName} contains the right amount of values: 1."
						printf '%s\n' "${_requiredColumnValues[0]}" >> "${_controlFileBase}.${_requiredColumnName}"
					fi
				elif [[ "${_requiredColumnValueState}" == 'empty' ]]
				then
					IFS=$'\n' _requiredColumnValues=($(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_requiredColumnIndex}"))
					if [[ "${#_requiredColumnValues[@]:-0}" -ne '0' ]]
					then
						log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Column ${_requiredColumnName} in ${_sampleSheet} must be empty for all samples/rows." \
							2>&1 | tee -a "${_controlFileBaseForFunction}.started"
							mv "${_controlFileBaseForFunction}."{started,failed}
						return
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Column ${_requiredColumnName} contains the right amount of values: 0."
					fi
				fi
			fi
		done
	done
	#
	# Get sequencingStartDate from time stamp of file used to signal that the data upload finished successfully.
	#
	# Technically both the "data transfer finished" date as well as the "sample prep finished + samplesheet created" date are not correct 
	# when used as "sequencingStartDate" as the former one is too late and the latter one too early, 
	# but the sample prep finished + samplesheet created dates may differ for the projects located in the same batch / on the same flowcell.
	# A flowcell can only have one sequencingStartDate though.
	# Therefore we overwrite the "sequencingStartDate" value from the samplesheets per project with the "data upload finished" date.
	#
	local _sequencingStartDateFile="${_controlFileBase}.sequencingStartDate"
	if [[ -e "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished" ]]
	then
		$(date -d "@$(stat -c '%Y' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished")" +'%y%m%d' > "${_sequencingStartDateFile}")
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Fetched sequencingStartDate from last modification time stamp of ${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished."
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished is missing or not accessible." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# All is well; add new status info to *.started file and
	# delete any previously created *.failed file if present,
	# then move the *.started file to *.finished.
	# (Note: the content of *.finished will get inserted in the body of email notification messages,
	# when enabled in <group>.cfg for use by notifications.sh)
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${FUNCNAME} succeeded for batch ${_batch}. See ${_controlFileBaseForFunction}.finished for details." \
		2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
		&& rm -f "${_controlFileBaseForFunction}.failed" \
		&& mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function renameFastQs() {
	local _batch="${1}"
	local _controlFileBase="${2}"
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME}"
	local _batchDir="${TMP_ROOT_DIR}/${_batch}/"
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${FUNCNAME} ${_batch}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	#
	# Get the sequencingStartDate.
	#
	local      _sequencingStartDateFile="${_controlFileBase}.sequencingStartDate"
	if [[ -e "${_sequencingStartDateFile}" ]]
	then
		local _sequencingStartDate="$(<"${_sequencingStartDateFile}")"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsed ${_sequencingStartDateFile} and found _sequencingStartDate: ${_sequencingStartDate}."
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sequencingStartDateFile} is missing or not accessible." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Load ngs-utils.
	#
	module load ngs-utils/"${NGS_UTILS_VERSION}" \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
		&& module list \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "Cannot load ngs-utils/${NGS_UTILS_VERSION}. See ${_controlFileBaseForFunction}.failed for details." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	#
	# Rename FastQ files.
	#
	# N.B.: batch may contain FastQ files from more than one flowcell / sequence run!
	#
	renameFastQs.bash \
		-s "${_sequencingStartDate}" \
		-f "${_batchDir}/"'*_'"${_batch}"'-*.fastq.gz' \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "renameFastQs failed. See ${_controlFileBaseForFunction}.failed for details." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${FUNCNAME} succeeded for batch ${_batch}. See ${_controlFileBaseForFunction}.finished for details." \
		2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
		&& rm -f "${_controlFileBaseForFunction}.failed" \
		&& mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function processSamplesheetsAndMoveCovertedData() {
	local _batch="${1}"
	local _controlFileBase="${2}"
	local _controlFileBaseForFunction="${_controlFileBase}.${FUNCNAME}"
	local _logFile="${_controlFileBaseForFunction}.log"
	#
	# Check if function previously finished successfully for this data.
	#
	if [[ -e "${_controlFileBaseForFunction}.finished" ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBaseForFunction}.finished is present -> Skipping."
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${FUNCNAME} ${_batch}. OK"
		return
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${_controlFileBaseForFunction}.finished not present -> Continue..."
		printf '' > "${_controlFileBaseForFunction}.started"
	fi
	#
	# Convert log4bash log levels to Python logging levels where necessary
	#
	declare _pythonLogLevel='INFO' # default fallback.
	if [[ "${l4b_log_level}" == 'TRACE' ]]
	then
		_pythonLogLevel='DEBUG'
	elif [[ "${l4b_log_level}" == 'WARN' ]]
	then
		_pythonLogLevel='WARNING'
	elif [[ "${l4b_log_level}" == 'FATAL' ]]
	then
		_pythonLogLevel='CRITICAL'
	else
		_pythonLogLevel="${l4b_log_level}"
	fi
	#
	# Combine GenomeScan samplesheet per batch with inhouse samplesheet(s) per project.
	#
	createInhouseSamplesheetFromGS.py \
		--genomeScanInputDir "${TMP_ROOT_DIR}/${_batch}/" \
		--inhouseSamplesheetsInputDir "${TMP_ROOT_DIR}/Samplesheets/new/" \
		--samplesheetsOutputDir "${TMP_ROOT_DIR}/${_batch}/" \
		--logLevel "${_pythonLogLevel}" \
		>> "${_logFile}" 2>&1 \
	|| {
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "createInhouseSamplesheetFromGS.py failed. See ${_logFile} for details." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	#
	# Get a list of projects listed in the GenomeScan samplesheet.
	#
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	_gsSampleSheet=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/CSV_UMCG_"*".${SAMPLESHEET_EXT}")
	IFS="${SAMPLESHEET_SEP}" _sampleSheetColumnNames=($(head -1 "${_gsSampleSheet}"))
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]:-0} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	_projectFieldIndex=$((${_sampleSheetColumnOffsets['Sample_ID']} + 1))
	IFS=$'\n' _projects=($(tail -n +2 "${_gsSampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sort | uniq ))
	#
	# Get a list of sequencing run dirs (created by renameFastQs.bash)
	# and in format ${sequencingStartdate}_${sequencer}_${run}_${flowcell}
	#
	declare -a _runDirs=($(cd "${TMP_ROOT_DIR}/${_batch}/" && find ./ -maxdepth 1 -mindepth 1 -type d -name '*[0-9][0-9]*_[A-Z0-9][A-Z0-9]*_[0-9][0-9]*_[A-Z0-9][A-Z0-9]*' -exec basename {} \;))
	if [[ "${#_runDirs[@]:-0}" -lt '1' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Did not find any sequence run dirs in ${TMP_ROOT_DIR}/${_batch}/." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${#_runDirs[@]} sequence run dirs."
	fi
	#
	# Create samplesheet(s) per sequencing runDir, which may be more than one!
	#
	local _runDir
	local _regex='[0-9]+_[A-Z0-9]+_[0-9]+_([A-Z0-9]+)'
	for _runDir in "${_runDirs[@]}"
	do
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating ${TMP_ROOT_DIR}/${_batch}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}..."
		#
		# Get flowcell for this run.
		#
		if [[ "${_runDir}" =~ ${_regex} ]]
		then
			local _flowcell="${BASH_REMATCH[1]}"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found flowcell ${_flowcell} in sequence run dir ${_runDir}."
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to parse flowcell from sequence run dir ${_runDir}." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
		#
		# Create header line for new sequencing run samplesheet based on the one from the first project samplesheet.
		#
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating header ${TMP_ROOT_DIR}/${_batch}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}..."
		head -1 "${TMP_ROOT_DIR}/${_batch}/${_projects[0]}.${SAMPLESHEET_EXT}" > "${TMP_ROOT_DIR}/${_batch}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}"
		#
		# Extract lines for this sequencing run from all project samplesheets based on the flowcell ID.
		#
		for _project in "${_projects[@]}"
		do
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Appending rows for ${_flowcell} from project ${_project} to ${TMP_ROOT_DIR}/${_batch}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}..."
			if grep "${_flowcell}" "${TMP_ROOT_DIR}/${_batch}/${_project}.${SAMPLESHEET_EXT}" >/dev/null
			then
				grep "${_flowcell}" "${TMP_ROOT_DIR}/${_batch}/${_project}.${SAMPLESHEET_EXT}" >> "${TMP_ROOT_DIR}/${_batch}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}"
			fi
		done
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished creating ${TMP_ROOT_DIR}/${_batch}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}."
	done
	#
	# Sanity check: count if the amount of sample lines in the GenomeScan samplesheet 
	#               is the same or higher as the flowcell+lane+barcode lines in the combined sequencing run samplesheet(s).
	#
	local _sampleLinesGS=$(tail -n +2 "${_gsSampleSheet}" | wc -l)
	local _flowcellLaneBarcodeLinesRuns=0
	for _runDir in "${_runDirs[@]}"
	do
		_flowcellLaneBarcodeLinesRuns=$(( ${_flowcellLaneBarcodeLinesRuns} + $(tail -n +2 "${TMP_ROOT_DIR}/${_batch}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}" | wc -l) ))
	done
	if [[ "${_flowcellLaneBarcodeLinesRuns}" -lt "${_sampleLinesGS}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
			"Number of flowcell+lane+barcode lines in the samplesheets per sequencing run (${_flowcellLaneBarcodeLinesRuns}) is too low for the number of samples in the GenomeScan samplesheet (${_sampleLinesGS})." \
			2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
			&& mv "${_controlFileBaseForFunction}."{started,failed}
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${_flowcellLaneBarcodeLinesRuns} flowcell+lane+barcode lines in the samplesheets per sequencing run for ${_sampleLinesGS} samples in the GenomeScan samplesheet."
	fi
	#
	# Move/copy converted FastQs with accompanying samplesheets to their destination.
	#
	for _runDir in "${_runDirs[@]}"
	do
		#
		# Move converted FastQs with accompanying samplesheets per sequencing run to .../runs/${_runDir}/results/
		#
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Moving ${TMP_ROOT_DIR}/${_batch}/${_runDir}/* -> ${TMP_ROOT_DIR}/runs/${_runDir}/results/ ..."
		mkdir -p "${TMP_ROOT_DIR}/runs/${_runDir}/results/" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
			&& mv -f -v "${TMP_ROOT_DIR}/${_batch}/${_runDir}/"* \
			         "${TMP_ROOT_DIR}/runs/${_runDir}/results/" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
			&& printf '%s\n' "Demultplex statistics not present. See external QC report." \
			2>> "${_controlFileBaseForFunction}.started" \
			> "${TMP_ROOT_DIR}/runs/${_runDir}/results/${_runDir}.log" \
		|| {
			log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "Failed to move ${_runDir}. See ${_controlFileBaseForFunction}.failed for details." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		#
		# Copy samplesheets per sequencing run to .../Samplesheets/ dir,
		# so the next step of NGS_Automated will pick it up for further processing.
		#
		cp -v "${TMP_ROOT_DIR}/runs/${_runDir}/results/${_runDir}.${SAMPLESHEET_EXT}" \
		      "${TMP_ROOT_DIR}/Samplesheets/" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
		|| {
			log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "Failed to copy sequencing run samplesheet to ${TMP_ROOT_DIR}/Samplesheets/. See ${_controlFileBaseForFunction}.failed for details." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		mkdir -p "${TMP_ROOT_DIR}/logs/${_runDir}" \
			&& touch "${TMP_ROOT_DIR}/logs/${_runDir}/run01.demultiplexing.finished" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
		|| {
			log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" '0' "Failed to touch ${TMP_ROOT_DIR}/logs/${_runDir}_Demultiplexing.finished. See ${_controlFileBaseForFunction}.failed for details." \
				2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
				&& mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
	done
	#
	# Cleanup uploaded samplesheets per project.
	#
	mkdir -p "${TMP_ROOT_DIR}/Samplesheets/archive/"
	for _project in "${_projects[@]}"
	do
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Moving ${TMP_ROOT_DIR}/Samplesheets/new/${_project}.${SAMPLESHEET_EXT} -> ${TMP_ROOT_DIR}/Samplesheets/archive/ ..."
		mv -v "${TMP_ROOT_DIR}/Samplesheets/new/${_project}.${SAMPLESHEET_EXT}" "${TMP_ROOT_DIR}/Samplesheets/archive/"
	done
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${FUNCNAME} succeeded for batch ${_batch}. See ${_controlFileBaseForFunction}.finished for details." \
		2>&1 | tee -a "${_controlFileBaseForFunction}.started" \
		&& rm -f "${_controlFileBaseForFunction}.failed" \
		&& mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to process GenomeScan data:
	1. Convert FastQ files to format required by NGS_DNA / NGS_RNA piplines.
	2. Supplement samplesheets with meta-data from the sequencing experiment.
Usage:
	$(basename $0) OPTIONS
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
while getopts "g:l:h" opt
do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		l)
			l4b_log_level="${OPTARG^^}"
			l4b_log_level_prio="${l4b_log_levels[${l4b_log_level}]}"
			;;
		\?)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Invalid option -${OPTARG}. Try $(basename $0) -h for help."
			;;
		:)
			log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename $0) -h for help."
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
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
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile}..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		mixed_stdouterr=$(source ${configFile} 2>&1) || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot source ${configFile}."
		source ${configFile}  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done


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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."

#
# List of required columns in sample sheets and whether they may not or must be empty.
#  hash key = column name
#  hash val = present|single|empty for whether the column must contain a value for every row, 
#             must contain the same value in every row or must be empty.
#
declare -A requiredSamplesheetColumns=(
	['externalSampleID']='present'
	['project']='present'
	['sequencingStartDate']='single'
	['seqType']='present'
	['prepKit']='present'
	['capturingKit']='present'
	['barcode']='present'
	['barcode2']='present'
	['barcodeType']='present'
	['sequencer']='empty'
	['run']='empy'
	['flowcell']='empy'
	['lane']='empy'
)

#
# Get a list of all GenomeScan batch directories.
#
declare -a gsBatchDirs=($(find "${TMP_ROOT_DIR}/" -maxdepth 1 -mindepth 1 -type d -name "[0-9]*-[0-9]*"))
log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Found gsBatchDirs: ${gsBatchDirs[@]}"

if [[ "${#gsBatchDirs[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batch directories found in ${TMP_ROOT_DIR}/"
else
	for gsBatchDir in "${gsBatchDirs[@]}"
	do
		#
		# Process this batch.
		#
		gsBatch="$(basename "${gsBatchDir}")"
		controlFileBase="${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		#
		# ToDo: change location of log files back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster
		#       instead of on a research cluster.
		#
		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${gsBatch}."
		else
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing batch ${gsBatch}..."
			mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${gsBatch}/"
			printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
			#
			# Step 1: Sanity Check if transfer of raw data has finished.
			#
			if [[ -e "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished present -> Data transfer completed; let's process batch ${gsBatch}..."
				sanityChecking "${gsBatch}" "${controlFileBase}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished absent -> Data transfer not yet completed; skipping batch ${gsBatch}."
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Data transfer not yet completed; skipping batch ${gsBatch}." \
					2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
				continue
			fi
			#
			# Step 2: Rename FastQs if Sanity check has finished.
			#
			if [[ -e "${controlFileBase}.sanityChecking.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${controlFileBase}.sanityChecking.finished present -> sanityChecking completed; let's renameFastQs for batch ${gsBatch}..."
				renameFastQs "${gsBatch}" "${controlFileBase}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${controlFileBase}.sanityChecking.finished absent -> sanityChecking failed."
			fi
			#
			# Step 3: Process samplesheets and move converted data if renaming of FastQs has finished.
			#
			if [[ -e "${controlFileBase}.renameFastQs.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${controlFileBase}.renameFastQs.finished present -> renameFastQs completed; let's mergeSamplesheetPerProject for batch ${gsBatch}..."
				processSamplesheetsAndMoveCovertedData "${gsBatch}" "${controlFileBase}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${controlFileBase}.renameFastQs.finished absent -> renameFastQs failed."
			fi
			#
			# Signal success or failure for complete process.
			#
			if [[ -e "${controlFileBase}.processSamplesheetsAndMoveCovertedData.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${controlFileBase}.processSamplesheetsAndMoveCovertedData.finished present -> processing completed for batch ${gsBatch}..."
				rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Finished processing batch ${gsBatch}." \
					2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
				mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "${controlFileBase}.processSamplesheetsAndMoveCovertedData.finished absent -> processing failed for batch ${gsBatch}."
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Failed to process batch ${gsBatch}." \
					2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
				mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			fi
		fi
	done
fi

log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished processing all batches.'

trap - EXIT
exit 0
