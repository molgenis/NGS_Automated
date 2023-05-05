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

#
# Determine if samplesheet merging is possible for this sequence run, which is the case when
#  1. Corresponding samplesheets are present in the Samplesheets dir.
#  2. Samplesheets are Ok.
#  3. Integrity of the FastQ files is Ok as determined using validation of their checksums.
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
	
	mv "${_controlFileBaseForFunction}."{started,finished}
}

function sanityChecking() {
	#
	local _batch="${1}"
	local _controlFileBase="${2}"
	local _dataType="${3}"
	local _controlFileBaseForFunction="${_controlFileBase}.${_dataType}_${FUNCNAME[0]}"
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing batch ${_batch}..."
	#
	# Check if function previously finished successfully for this data.
	#
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
	# Check if one sane GS samplesheet is present.
	#
	local _numberOfSamplesheets
	_numberOfSamplesheets=$(find "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/" -maxdepth 1 -mindepth 1 -name 'UMCG_CSV_*.'"${SAMPLESHEET_EXT}" 2>/dev/null | wc -l)
	if [[ "${_numberOfSamplesheets}" -eq 1 ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found: one ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/UMCG_CSV_*.${SAMPLESHEET_EXT} samplesheet."
		local _gsSampleSheet
		_gsSampleSheet=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/UMCG_CSV_"*".${SAMPLESHEET_EXT}")
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
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to convert line end characters and/or remove empty lines for ${_gsSampleSheet}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		#
		# Continue with converted samplesheet.
		#
		_gsSampleSheet="${_gsSampleSheet}.converted"
	elif [[ "${_numberOfSamplesheets}" -gt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "More than one UMCG_CSV_*.${SAMPLESHEET_EXT} GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	elif [[ "${_numberOfSamplesheets}" -lt 1 ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No GS samplesheet present in ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Count FastQ files present on disk for each read of a pair.
	#
	local _countFastQ1FilesOnDisk
	local _countFastQ2FilesOnDisk
	_countFastQ1FilesOnDisk=$(find "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/" -maxdepth 1 -mindepth 1 -name '*_R1.fastq.gz' | wc -l)
	_countFastQ2FilesOnDisk=$(find "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/" -maxdepth 1 -mindepth 1 -name '*_R2.fastq.gz' | wc -l)
	if [[ "${_countFastQ1FilesOnDisk}" -ne "${_countFastQ2FilesOnDisk}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Amount of R1 FastQ files (${_countFastQ1FilesOnDisk}) is not the same as R2 FastQ files (${_countFastQ2FilesOnDisk})."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Check if checksum file is present and if we have enough checksums for the amount of FastQ files received.
	# (No need to waist a lot of time on computing checksums for a partially failed transfer).
	#
	local _checksumFile
	local _countFastQFilesInChecksumFile
	_checksumFile="${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/checksums.md5"
	_countFastQFilesInChecksumFile='0'
	if [[ -e "${_checksumFile}" && -r "${_checksumFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found ${_checksumFile}."
		_countFastQFilesInChecksumFile=$(grep -c '_R[1-2].fastq.gz' "${_checksumFile}")
		if [[ "${_countFastQFilesInChecksumFile}" -ne "$((${_countFastQ1FilesOnDisk} + ${_countFastQ2FilesOnDisk}))" ]]
		then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' \
				"Mismatch: found ${_countFastQFilesInChecksumFile} FastQ files in checksum file, but ${_countFastQ1FilesOnDisk} *_R1.fastq.gz and ${_countFastQ2FilesOnDisk} *_R2.fastq.gz files on disk."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Amount of FastQ files in checksum file and amount of *_R[1|2].fastq.gz files on disk is the same for ${_batch}: ${_countFastQFilesInChecksumFile}."
		fi
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "No ${_checksumFile} file present in ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Count and make sure all samples for which we received FastQ files on disk are present in the samplesheet and vice versa.
	# _insaneSamples is a string of sample IDs only present either on disk or on the samplesheet.
	#
	readarray -t _samplesOnDisk < <(find "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/" -maxdepth 1 -mindepth 1 -name '*.fastq.gz' | grep -o "${_batch}-[0-9][0-9]*" | sort -u)
	readarray -t _samplesInSamplesheet < <(grep -o "${_batch}-[0-9][0-9]*" "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/UMCG_CSV_"*".${SAMPLESHEET_EXT}.converted" | sort -u)
	local _insaneSamples
	_insaneSamples="$(echo "${_samplesOnDisk[@]:-}" "${_samplesInSamplesheet[@]:-}" | tr ' ' '\n' | sort | uniq -u | tr '\n' ' ')"
	if [[ -n "${_insaneSamples:-}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' \
			"Mismatch: sample(s) ${_insaneSamples} are either present in the samplesheet, but missing on disk or vice versa."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "All samples present in the samplesheet are also present on disk and vice versa."
	fi
	#
	# Verify checksums for the transfered data.
	#
	local _checksumVerification
	_checksumVerification='unknown'
	if [[ -e "${_controlFileBaseForFunction}.md5.PASS" ]]
	then
		_checksumVerification='PASS'
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_controlFileBaseForFunction}.md5.PASS absent -> start checksum verification..."
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' \
			"Started verification of checksums by ${ATEAMBOTUSER}@${HOSTNAME_SHORT} using checksums from ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_checksumFile}"
		_checksumVerification=$(cd "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/"
			if md5sum -c "${_checksumFile}" >> "${_controlFileBaseForFunction}.started" 2>&1
			then
				echo 'PASS'
				touch "${_controlFileBaseForFunction}.md5.PASS"
			else
				echo 'FAILED'
			fi
		)
	fi
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "_checksumVerification = ${_checksumVerification}"
	if [[ "${_checksumVerification}" != 'PASS' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Checksum verification failed. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Parse GS samplesheet to get a list of project values.
	#
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${_gsSampleSheet}")"
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	#
	# Check if GS samplesheet contains required a combined project name + sampleProcessStepID column.
	# Sometimes GS used Sample_ID as column name and sometimes just ID;
	# we'll use whatever is present.
	#
	if [[ -n "${_sampleSheetColumnOffsets['ID']+isset}" ]]
	then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets['ID']} + 1))
	elif [[ -n "${_sampleSheetColumnOffsets['Sample_ID']+isset}" ]]
	then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets['Sample_ID']} + 1))
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column containing project name combined with sampleProcessStepID is missing in ${_gsSampleSheet}."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# The values in the 'Sample_ID' or 'ID' column are a combination of the project and sampleProcessStepID.
	# E.g. GS_2A-Exoom_v3-835385.
	# The 835385 is the sampleProcessStepID, which has to be removed to get the project value.
	#
	readarray -t _projects < <(tail -n +2 "${_gsSampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sed 's/-[0-9][0-9]*$//' | sort | uniq)
	if [[ "${#_projects[@]}" -lt '1' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_gsSampleSheet} does not contain at least one project value."
		mv "${_controlFileBaseForFunction}."{started,failed}
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
	local _sampleSheet
	local _archivedSampleSheet
	for _project in "${_projects[@]}"
	do
		#
		# ToDo: change location of sample sheet per project back to ${TMP_ROOT_DIR} once we have a 
		#       proper prm mount on the GD clusters and this script can run a GD cluster.
		#
		_sampleSheet="${TMP_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}"
		_archivedSampleSheet="${TMP_ROOT_DIR}/Samplesheets/archive/${_project}.${SAMPLESHEET_EXT}"
		if [[ -f "${_sampleSheet}" && -r "${_sampleSheet}" ]]
		then
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_sampleSheet} is present."
		elif [[ -f "${_archivedSampleSheet}" && -r "${_archivedSampleSheet}" ]]
		then
			#
			# This project was sequenced before, but most likely the yield was not high enough
			# or there were other QC issues and the samples were re-sequenced;
			# Check if we have a samplesheet from the previous sequence run in the archive.
			#
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Samplesheet for project ${_project} is missing from .../Samplesheets/, but we have one in .../Samplesheets/archive/ and will re-use that one."
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Moving ${_archivedSampleSheet} to ${_sampleSheet} ..."
			mv "${_archivedSampleSheet}" "${_sampleSheet}" \
				2>> "${_controlFileBaseForFunction}.started" \
			|| {
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to move ${_archivedSampleSheet} to ${_sampleSheet}."
				mv "${_controlFileBaseForFunction}."{started,failed}
				return
			}
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_sampleSheet} is missing or not accessible."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
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
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to convert line end characters and/or remove empty lines for ${_sampleSheet}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		#
		# Get fields (columns) from samplesheet.
		#
		declare -a _sampleSheetColumnNames=()
		declare -A _sampleSheetColumnOffsets=()
		IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${_sampleSheet}")"
		for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
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
			local _requiredColumnValueState
			declare -a _requiredColumnValues=()
			local      _requiredColumnIndex
			_requiredColumnValueState="${requiredSamplesheetColumns[${_requiredColumnName}]}"
			if [[ -z "${_sampleSheetColumnOffsets[${_requiredColumnName}]+isset}" ]]
			then
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Required column ${_requiredColumnName} missing in ${_sampleSheet} -> Skipping ${_batch} due to error in samplesheet."
				mv "${_controlFileBaseForFunction}."{started,failed}
				return
			else
				_requiredColumnIndex=$((${_sampleSheetColumnOffsets["${_requiredColumnName}"]} + 1))
				if [[ "${_requiredColumnValueState}" == 'present' ]]
				then
					readarray -t _requiredColumnValues < <(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_requiredColumnIndex}")
					if [[ "${#_requiredColumnValues[@]}" -ne "${_sampleSheetNumberOfRows}" ]]
					then
						log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column ${_requiredColumnName} in ${_sampleSheet} does NOT contain the expected amount of values: ${_sampleSheetNumberOfRows}."
						mv "${_controlFileBaseForFunction}."{started,failed}
						return
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column ${_requiredColumnName} contains the right amount of values: ${_sampleSheetNumberOfRows}."
					fi
				elif [[ "${_requiredColumnValueState}" == 'single' ]]
				then
					readarray -t _requiredColumnValues < <(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_requiredColumnIndex}" | sort | uniq )
					if [[ "${#_requiredColumnValues[@]}" -ne '1' ]]
					then
						log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column ${_requiredColumnName} in ${_sampleSheet} must contain the same value for all samples/rows."
						mv "${_controlFileBaseForFunction}."{started,failed}
						return
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column ${_requiredColumnName} contains the right amount of values: 1."
						printf '%s\n' "${_requiredColumnValues[0]}" >> "${_controlFileBase}.${_requiredColumnName}"
					fi
				elif [[ "${_requiredColumnValueState}" == 'empty' ]]
				then
					readarray -t _requiredColumnValues < <(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_requiredColumnIndex}" | sed '/^$/d')
					if [[ "${#_requiredColumnValues[@]}" -ne '0' ]]
					then
						log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column ${_requiredColumnName} in ${_sampleSheet} must be empty for all samples/rows."
						mv "${_controlFileBaseForFunction}."{started,failed}
						return
					else
						log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column ${_requiredColumnName} contains the right amount of values: 0."
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
	local _sequencingStartDateFile
	_sequencingStartDateFile="${_controlFileBase}.sequencingStartDate"
	if [[ -e "${TMP_ROOT_DIR}/${gsBatch}//${gsBatch}.finished" ]]
	then
		date -d "@$(stat -c '%Y' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished")" +'%y%m%d' > "${_sequencingStartDateFile}"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Fetched sequencingStartDate from last modification time stamp of ${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished."
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/${gsBatch}/${gsBatch}.finished is missing or not accessible."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# All is well; add new status info to *.started file and
	# delete any previously created *.failed file if present,
	# then move the *.started file to *.finished.
	# (Note: the content of *.finished will get inserted in the body of email notification messages,
	# when enabled in <group>.cfg for use by notifications.sh)
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for batch ${_batch}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function renameFastQs() {
	local _batch
	local _controlFileBase
	local _controlFileBaseForFunction
	local _batchDir
	local _dataType
	_batch="${1}"
	_controlFileBase="${2}"
	_dataType="${3}"
	_controlFileBaseForFunction="${_controlFileBase}.${_dataType}_${FUNCNAME[0]}"
	_batchDir="${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/"
	#
	# Check if function previously finished successfully for this data.
	#
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
	# Get the sequencingStartDate.
	#
	local _sequencingStartDateFile
	local _sequencingStartDate
	_sequencingStartDateFile="${_controlFileBase}.sequencingStartDate"
	if [[ -e "${_sequencingStartDateFile}" ]]
	then
		_sequencingStartDate="$(<"${_sequencingStartDateFile}")"
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Parsed ${_sequencingStartDateFile} and found _sequencingStartDate: ${_sequencingStartDate}."
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${_sequencingStartDateFile} is missing or not accessible."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	#
	# Load ngs-utils.
	#
	module load ngs-utils \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
		&& module list \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Cannot load ngs-utils. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
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
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "renameFastQs failed. See ${_controlFileBaseForFunction}.failed for details."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for batch ${_batch}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
}

function processSamplesheetsAndMoveConvertedData() {
	local _batch
	local _controlFileBase
	local _controlFileBaseForFunction
	local _dataType
	_batch="${1}"
	_controlFileBase="${2}"
	_dataType="${3}"
	_controlFileBaseForFunction="${_controlFileBase}.${_dataType}_${FUNCNAME[0]}"
	#
	# Check if function previously finished successfully for this data.
	#
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
	# Convert log4bash log levels to Python logging levels where necessary
	#
	local _pythonLogLevel
	_pythonLogLevel='INFO' # default fallback.
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
		--genomeScanInputDir "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/" \
		--inhouseSamplesheetsInputDir "${TMP_ROOT_DIR}/Samplesheets/" \
		--samplesheetsOutputDir "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/" \
		--logLevel "${_pythonLogLevel}" \
		>> "${_controlFileBaseForFunction}.started" 2>&1 \
	|| {
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "createInhouseSamplesheetFromGS.py failed."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	}
	#
	# Get a list of projects listed in the GenomeScan samplesheet.
	#
	declare -a _sampleSheetColumnNames=()
	declare -A _sampleSheetColumnOffsets=()
	local      _projectFieldIndex
	declare -a _projects=()
	_gsSampleSheet=$(ls -1 "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/UMCG_CSV_"*".${SAMPLESHEET_EXT}.converted")
	IFS="${SAMPLESHEET_SEP}" read -r -a _sampleSheetColumnNames <<< "$(head -1 "${_gsSampleSheet}")"
	for (( _offset = 0 ; _offset < ${#_sampleSheetColumnNames[@]} ; _offset++ ))
	do
		_sampleSheetColumnOffsets["${_sampleSheetColumnNames[${_offset}]}"]="${_offset}"
	done
	if [[ -n "${_sampleSheetColumnOffsets['ID']+isset}" ]]
	then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets['ID']} + 1))
	elif [[ -n "${_sampleSheetColumnOffsets['Sample_ID']+isset}" ]]
	then
		_projectFieldIndex=$((${_sampleSheetColumnOffsets['Sample_ID']} + 1))
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Column containing project name combined with sampleProcessStepID is missing in ${_gsSampleSheet}."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	fi
	readarray -t _projects < <(tail -n +2 "${_gsSampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${_projectFieldIndex}" | sed 's/-[0-9][0-9]*$//' | sort | uniq )
	#
	# Get a list of sequencing run dirs (created by renameFastQs.bash)
	# and in format ${sequencingStartdate}_${sequencer}_${run}_${flowcell}
	#
	readarray -t _runDirs < <(cd "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/" && find ./ -maxdepth 1 -mindepth 1 -type d -name '*[0-9][0-9]*_[A-Z0-9][A-Z0-9]*_[0-9][0-9]*_[A-Z0-9][A-Z0-9]*' -exec basename {} \;)
	if [[ "${#_runDirs[@]}" -lt '1' ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Did not find any sequence run dirs in ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found ${#_runDirs[@]} sequence run dirs."
	fi
	#
	# Create samplesheet(s) per sequencing runDir, which may be more than one!
	#
	local _runDir
	local _regex
	_regex='[0-9]+_[A-Z0-9]+_[0-9]+_([A-Z0-9]+)'
	for _runDir in "${_runDirs[@]}"
	do
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Creating ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}..."
		#
		# Get flowcell for this run.
		#
		if [[ "${_runDir}" =~ ${_regex} ]]
		then
			local _flowcell
			_flowcell="${BASH_REMATCH[1]}"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found flowcell ${_flowcell} in sequence run dir ${_runDir}."
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to parse flowcell from sequence run dir ${_runDir}."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		fi
		#
		# Create header line for new sequencing run samplesheet based on the one from the first project samplesheet.
		#
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Creating header ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}..."
		head -1 "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_projects[0]}.${SAMPLESHEET_EXT}" > "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}"
		#
		# Extract lines for this sequencing run from all project samplesheets based on the flowcell ID.
		#
		for _project in "${_projects[@]}"
		do
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Appending rows for ${_flowcell} from project ${_project} to ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}..."
			if grep "${_flowcell}" "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_project}.${SAMPLESHEET_EXT}" >/dev/null
			then
				grep "${_flowcell}" "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_project}.${SAMPLESHEET_EXT}" >> "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}"
			fi
		done
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished creating ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}."
	done
	#
	# Sanity check: count if the amount of sample lines in the GenomeScan samplesheet 
	#               is the same or higher as the flowcell+lane+barcode lines in the combined sequencing run samplesheet(s).
	#
	local _sampleLinesGS
	local _flowcellLaneBarcodeLinesRuns
	_sampleLinesGS=$(tail -n +2 "${_gsSampleSheet}" | wc -l)
	_flowcellLaneBarcodeLinesRuns='0'
	for _runDir in "${_runDirs[@]}"
	do
		_flowcellLaneBarcodeLinesRuns=$(( ${_flowcellLaneBarcodeLinesRuns} + $(tail -n +2 "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}" | wc -l) ))
	done
	if [[ "${_flowcellLaneBarcodeLinesRuns}" -lt "${_sampleLinesGS}" ]]
	then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' \
			"Number of flowcell+lane+barcode lines in the samplesheets per sequencing run (${_flowcellLaneBarcodeLinesRuns}) is too low for the number of samples in the GenomeScan samplesheet (${_sampleLinesGS})."
		mv "${_controlFileBaseForFunction}."{started,failed}
		return
	else
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Found ${_flowcellLaneBarcodeLinesRuns} flowcell+lane+barcode lines in the samplesheets per sequencing run for ${_sampleLinesGS} samples in the GenomeScan samplesheet."
	fi
	#
	# Move/copy converted FastQs with accompanying samplesheets to their destination.
	#
	for _runDir in "${_runDirs[@]}"
	do
		#
		# Move converted FastQs with accompanying samplesheets per sequencing run to .../rawdata/ngs/${_runDir}/
		#
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Moving ${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/* -> ${TMP_ROOT_DIR}/rawdata/ngs/${_runDir}/ ..."
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/rawdata/ngs/${_runDir}/" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
			&& mv -f -v "${TMP_ROOT_DIR}/${_batch}/${rawdataFolder}/${_runDir}/"* "${TMP_ROOT_DIR}/rawdata/ngs/${_runDir}/" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
			&& printf '%s\n' "Demultplex statistics not present. See external QC report." \
			2>> "${_controlFileBaseForFunction}.started" \
			> "${TMP_ROOT_DIR}/rawdata/ngs/${_runDir}/${_runDir}.log" \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to move ${_runDir}. See ${_controlFileBaseForFunction}.failed for details."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		#
		# Make symlinks from rawdata/ngs folder to ${TMP_ROOT_DIR}/runs/${_runDir}/results/
		#
		mkdir -p "${TMP_ROOT_DIR}/runs/${_runDir}/results/"
		cd "${TMP_ROOT_DIR}/runs/${_runDir}/results/"
		readarray -t files < <(find "${TMP_ROOT_DIR}/rawdata/ngs/${_runDir}/" -mindepth 1 -maxdepth 1 \( -type l -o -type f \) -name "*.fq.gz" -o -name "*.fq.gz.md5" -o -name "*.log" -o -name "*.csv")
		for i in "${files[@]}"
		do
			ln -sf "${i}" './'
		done
		#
		# Copy samplesheets per sequencing run to .../Samplesheets/ dir,
		# so the next step of NGS_Automated will pick it up for further processing.
		#
		cp -v "${TMP_ROOT_DIR}/rawdata/ngs/${_runDir}/${_runDir}.${SAMPLESHEET_EXT}" "${TMP_ROOT_DIR}/Samplesheets/DRAGEN/" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to copy sequencing run samplesheet to ${TMP_ROOT_DIR}/Samplesheets/DRAGEN/. See ${_controlFileBaseForFunction}.failed for details."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "creating: mkdir -m 2770 -p ${TMP_ROOT_DIR}/logs/${_runDir} and touch ${RAWDATAPROCESSINGFINISHED} in that folder"
		# shellcheck disable=SC2174
		mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${_runDir}" \
			&& touch "${TMP_ROOT_DIR}/logs/${_runDir}/${RAWDATAPROCESSINGFINISHED}" \
			>> "${_controlFileBaseForFunction}.started" 2>&1 \
		|| {
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to touch ${TMP_ROOT_DIR}/logs/${_runDir}/${RAWDATAPROCESSINGFINISHED}. See ${_controlFileBaseForFunction}.failed for details."
			mv "${_controlFileBaseForFunction}."{started,failed}
			return
		}
		#
		# Track and Trace.
		#
		timeStamp="$(date +%FT%T%z)"
		printf '%s\n' 'run_id,group,process_raw_data,copy_raw_prm,projects,date' \
			> "${TMP_ROOT_DIR}/logs/${_runDir}/run01.${SCRIPT_NAME}.trace_post_overview.csv"
		# shellcheck disable=SC2153
		printf '%s\n' "${_runDir},${GROUP},finished,,,${timeStamp}" \
			>> "${TMP_ROOT_DIR}/logs/${_runDir}/run01.${SCRIPT_NAME}.trace_post_overview.csv"
		touch "${TMP_ROOT_DIR}/logs/${_runDir}/run01.${SCRIPT_NAME}.finished"
	done

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${FUNCNAME[0]} succeeded for batch ${_batch}. See ${_controlFileBaseForFunction}.finished for details."
	rm -f "${_controlFileBaseForFunction}.failed"
	mv -v "${_controlFileBaseForFunction}."{started,finished}
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Created ${_controlFileBaseForFunction}.finished."
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
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Parsing commandline arguments..."
declare group=''
while getopts ":g:l:h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
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
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' 'Must specify a group with -g.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config files..."
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
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Sourcing config file ${configFile}..."
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
# Make sure only one copy of this script runs simultaneously per group.
# Therefore locking must be done after
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data transfers.
#
lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs..."

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
	#
	# Barcodes may now be absent when samples were prepped at GenomeScan.
	# Barcode columns will be added automatically when missing and
	# the barcodes from the GenomeScan samplesheet will be used no matter 
	# what is listed in the barcode columns from the in-house samplesheet.
	#
	#['barcode']='present'
	#['barcode1']='present'
	#['barcode2']='present'
	['barcodeType']='present'
	['sequencer']='empty'
	['run']='empty'
	['flowcell']='empty'
	['lane']='empty'
	['sampleProcessStepID']='present'
)

logTimeStamp="$(date "+%Y-%m-%d")"
logDir="${TMP_ROOT_DIR}/logs/${logTimeStamp}/"
# shellcheck disable=SC2174
mkdir -m 2770 -p "${logDir}"
touch "${logDir}"
export JOB_CONTROLE_FILE_BASE="${logDir}/${logTimeStamp}.${SCRIPT_NAME}"
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Pulling data from data staging server ${HOSTNAME_DATA_STAGING%%.*} using rsync to /groups/${GROUP}/${TMP_LFS}/ ..."
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "See ${logDir}/rsync-from-${HOSTNAME_DATA_STAGING%%.*}.log for details ..."
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
			#
			# ToDo: change location of log files back to ${TMP_ROOT_DIR} once we have a 
			#       proper prm mount on the GD clusters and this script can run a GD cluster
			#       instead of on a research cluster.
			#
			if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
			then
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gsBatch} already processed, no need to transfer the data again."
				continue
			else
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing batch ${gsBatch}..."
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${gsBatch}/"
				printf '' > "${JOB_CONTROLE_FILE_BASE}.started"

				#
				# Check if gsBatch is supposed to be complete (*.finished present).
				#
				gsBatchUploadCompleted='false'
				if rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished" 2>/dev/null
				then
					readarray -t testForEmptyDir < <(rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/")
					if [[ "${#testForEmptyDir[@]}" -gt 2 ]]
					then
						gsBatchUploadCompleted='true'
						logTimeStamp=$(date '+%Y-%m-%d-T%H%M')
						rsync -e 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${rawdataFolder}/" \
						> "${logDir}/${gsBatch}.uploadCompletedListing_${logTimeStamp}.log"
					else
						log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${gsBatch}/ is empty, nothing to do."
						continue
					fi
				else
					log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "${GENOMESCAN_HOME_DIR}/${gsBatch}/${gsBatch}.finished does not exist"
					continue
				fi
				
				# First parse samplesheet to see where the data should go
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing only the UMCG_CSV samplesheet file for ${gsBatch} to ${group}..."
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${rawdataFolder}/UMCG_CSV_*.csv"
				/usr/bin/rsync -e 'ssh -p 443' -vrltD \
					"${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${rawdataFolder}/UMCG_CSV_"*".csv" \
					"${TMP_ROOT_DIR}/${gsBatch}/"
		
				rsyncData "${gsBatch}" "${controlFileBase}" "${rawdataFolder}"
			fi
		done
	fi
else
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "server is down, there will be no data transfer!"
fi

#
##
### process Raw_data 
##
#


readarray -t gsBatches< <(rsync -f"+ */" -f"- *" "${TMP_ROOT_DIR}/" | awk '{if ($5 != "" && $5 != "." && $5 ~/-/){print $5}}')
if [[ "${#gsBatches[@]}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${TMP_ROOT_DIR}/"
else
	for gsBatch in "${gsBatches[@]}"
	do
		gsBatch="$(basename "${gsBatch}")"
		controlFileBase="${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}"
		export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Processing process analysis batch ${gsBatch}..."

		if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]
		then
			log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${gsBatch} already processed, no need process the data again."
			continue
		else
			# shellcheck disable=SC2174
			mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/"
			# shellcheck disable=SC2174
			mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${gsBatch}/"
			printf '' > "${JOB_CONTROLE_FILE_BASE}.started"
			#
			# Step 1: Sanity Check if transfer of raw data has finished.
			#
			if [[ -e "${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.${rawdataFolder}_rsyncData.finished" ]]
			then
				
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.${rawdataFolder}_rsyncData.finished present -> Data transfer completed; let's process batch ${gsBatch}..."
				sanityChecking "${gsBatch}" "${controlFileBase}" "${rawdataFolder}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.${rawdataFolder}_rsyncData.finished absent -> Data transfer not yet completed; skipping batch ${gsBatch}."
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Data transfer not yet completed; skipping batch ${gsBatch}."
				continue
			fi
			#
			# Step 2: Rename FastQs if Sanity check has finished.
			#
			if [[ -e "${controlFileBase}.${rawdataFolder}_sanityChecking.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${rawdataFolder}_sanityChecking.finished present -> sanityChecking completed; let's renameFastQs for batch ${gsBatch}..."
				renameFastQs "${gsBatch}" "${controlFileBase}" "${rawdataFolder}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${rawdataFolder}_sanityChecking.finished absent -> sanityChecking failed."
			fi
			#
			# Step 3: Process samplesheets and move converted data if renaming of FastQs has finished.
			#
			if [[ -e "${controlFileBase}.${rawdataFolder}_renameFastQs.finished" ]]
			then
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${rawdataFolder}_renameFastQs.finished present -> renameFastQs completed; let's mergeSamplesheetPerProject for batch ${gsBatch}..."
				processSamplesheetsAndMoveConvertedData "${gsBatch}" "${controlFileBase}" "${rawdataFolder}"
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${rawdataFolder}_renameFastQs.finished absent -> renameFastQs failed."
			fi
			#
			# Signal success or failure for complete process.
			#
			if [[ -e "${controlFileBase}.${rawdataFolder}_processSamplesheetsAndMoveConvertedData.finished" ]]
			then
				csvFile=$(ls -1 "${TMP_ROOT_DIR}/${gsBatch}/${rawdataFolder}/UMCG_CSV_"*".csv")
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${rawdataFolder}_processSamplesheetsAndMoveConvertedData.finished present -> processing completed for batch ${gsBatch}..."
				rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
				
				# Combine samplesheets 
				mapfile -t uniqProjects< <(awk 'BEGIN {FS=","}{if (NR>1){print $2}}' "${csvFile}" | awk 'BEGIN {FS="-"}{print $1"-"$2}' | sort -V  | uniq)
				projectName=$(echo "${uniqProjects[0]}" | grep -Eo 'GS_[0-9]+')
				# shellcheck disable=SC2174
				mkdir -m 2770 -p "${TMP_ROOT_DIR}/logs/${projectName}/"
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Creating ${TMP_ROOT_DIR}/logs/${projectName}/${RAWDATAPROCESSINGFINISHED}"
				touch "${TMP_ROOT_DIR}/logs/${projectName}/${RAWDATAPROCESSINGFINISHED}"
				rm -f "${JOB_CONTROLE_FILE_BASE}.failed"
				mv -v "${JOB_CONTROLE_FILE_BASE}."{started,finished}
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Finished processing batch ${gsBatch}."
			else
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "${controlFileBase}.${rawdataFolder}_processSamplesheetsAndMoveConvertedData.finished absent -> processing failed for batch ${gsBatch}."
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME[0]:-main}" '0' "Failed to process batch ${gsBatch}."
				mv -v "${JOB_CONTROLE_FILE_BASE}."{started,failed}
			fi
		fi
	done
fi

	log4Bash 'INFO' "${LINENO}" "${FUNCNAME[0]:-main}" '0' 'Finished processing all batches.'

if [[ "${CLEANUP}" == "false" ]]
then
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "this is a testgroup, data should not be removed after 14 days"
else
	#
	# Cleanup old data if data transfer with rsync finished successfully and the rawdata is on prm for at least 2 days.
	#
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Deleting data older than 2 days from ${HOSTNAME_DATA_STAGING%%.*}:/groups/${GROUP}/${SCR_LFS}/ ..."
	#
	# Get the batch name by parsing the ${GENOMESCAN_HOME_DIR} folder, directories only and no empty or '.'
	#
	readarray -t gsBatchesSourceServer< <(rsync -f"+ */" -f"- *" -r 'ssh -p 443' "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/" | awk '{if ($5 != "" && $5 != "."){print $5}}')
	if [[ "${#gsBatchesSourceServer[@]}" -eq '0' ]]
	then
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No batches found at ${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/"
	else
		for gsBatch in "${gsBatchesSourceServer[@]}"
		do
			gsBatch="$(basename "${gsBatch}")"
			#
			# Convert date to seconds for easier calculation of the date difference.
			# 86400 = 1 day in seconds.
			#
			# The copySamplesheetForBatchToPrm.sh will generate a log file when all flowcells of a genomescan batch ar copied to prm.
			# If this file is older than 2 days, the genomescan batch will be removed from the data staging machine.
			#
			if [[ -f "${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.copyBatchRawDataToPrm.finished" ]]
			then
				dateInSecRawData="$(date -d"$(rsync "${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.copyBatchRawDataToPrm.finished" | awk '{print $3}')" +%s)"
				dateInSecNow=$(date +%s)
				if [[ $(((dateInSecNow - dateInSecRawData) / 86400)) -gt 2 ]]
				then
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Deleting ${gsBatch} because the RawData is copied to prm and older than 2 days"
					#
					# Create an empty dir (source dir) to sync with the destination dir && then remove source dir.
					#
					mkdir -p "${HOME}/empty_dir/"
					rsync -a --delete -e 'ssh -p 443' "${HOME}/empty_dir/" "${HOSTNAME_DATA_STAGING}::${GENOMESCAN_HOME_DIR}/${gsBatch}/${rawdataFolder}"
					rmdir "${HOME}/empty_dir/"
				else
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "The rawdata of batch ${gsBatch} is only $(((dateInSecNow - dateInSecRawData) / 86400)) day(s) old. The rawdata needs to be at least 2 days old before it can be removed"
					continue
				fi
			else
				log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${TMP_ROOT_DIR}/logs/${gsBatch}/${gsBatch}.copyBatchRawDataToPrm.finished does not exist, skipping"
				continue
			fi
		done
	fi
fi


trap - EXIT
exit 0
