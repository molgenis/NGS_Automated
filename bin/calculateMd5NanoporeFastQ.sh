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

function copybed(){
        local type='copybed'
        touch "${LOGS_DIR}/${sample}/${type}.calculateMd5s.started"
        ## Navigate to folder with ${type} files
        cd "${fullPath}/" || {
                echo "${fullPath} is not existing" >> "${LOGS_DIR}/${sample}/${type}.calculateMd5s.started"
                mv "${LOGS_DIR}/${sample}/${type}.calculateMd5s."{started,failed}
                exit 1
        }

regex='\"bed_file=\\"(.*)\\"\",'

report=$(cat report_*.json | /home/grid/jq-linux-amd64 -r '.protocol_run_info | .args')
if [[ "${report}" =~ ${regex} ]];then
  bedfile_path="${BASH_REMATCH[1]}"
  mkdir -p bedfile
  cp -v "${bedfile_path}" bedfile/
else
  echo "${report} doesn't match" >&2 # this could get noisy if there are a lot of non-matching files
fi
        cd -
        mv "${LOGS_DIR}/${sample}/${type}.calculateMd5s."{started,finished}
}

function calculate() {
	local type="$1"
	touch "${LOGS_DIR}/${sample}/${type}.calculateMd5s.started"
	## Navigate to folder with ${type} files
	cd "${fullPath}/${type}/" || {
		echo "${fullPath}/${type}/ is not existing" >> "${LOGS_DIR}/${sample}/${type}.calculateMd5s.started" 
		mv "${LOGS_DIR}/${sample}/${type}.calculateMd5s."{started,failed} 
		exit 1
	}
	type_short=$(echo "${type}" | cut -d "_" -f 1)

	readarray -t _array< <(find . -maxdepth 1 -mindepth 1 -name "*.${type_short}*")

	if [[ "${#_array[@]}" -eq '0' ]]
	then
		echo "There are no correct files in the folder ${fullPath}/${type}"
		return
	else
		echo "Start checksumming ${type}"
		for arrayFile in "${_array[@]}"
		do
			md5sum "${arrayFile}" >> checksums.md5 || {
				echo "Something went wrong calculating the checksums" \
				2>&1 | tee -a "${LOGS_DIR}/${sample}/${type}.calculateMd5s.started"
				mv "${LOGS_DIR}/${sample}/${type}.calculateMd5s."{started,failed} 
				exit 1
			}
		done
	fi
	cd -
	mv "${LOGS_DIR}/${sample}/${type}.calculateMd5s."{started,finished}
}

SOURCE_DIR="/data/Diagnostiek"
LOGS_DIR="/data/logs/Diagnostiek"

readarray -t samples < <(find "${SOURCE_DIR}" -maxdepth 1 -mindepth 1 -type d)

for samplePath in "${samples[@]}"
do
	sample="$(basename "${samplePath}")"
	pathToFiles="${samplePath}/${sample}/"
	missingPart=$(ls "${samplePath}/${sample}/")
	fullPath="${pathToFiles}/${missingPart}/"
	#
	## Check if run is finished
	#
	if ls "${fullPath}/sample_sheet"* > /dev/null 2>&1	
	then
		echo "sample_sheet is there, ${sample} is finished, proceed"
	else
		echo "sample_sheet is not (yet) there, skipping unfinished run(${sample})"
		continue
	fi
	
	#
	## check if checksums are calculated  
	#	
	if [[ -e "${LOGS_DIR}/${sample}/calculateMd5s.finished" ]]
	then
		echo "calculateMd5s for sample ${sample} already finished, skipping"
		continue
	else
		if [[ -e "${LOGS_DIR}/${sample}/calculateMd5s.started" ]]
		then
			echo "sample ${sample} is already being processed, skipping"
			continue
		fi
		mkdir -p "${LOGS_DIR}/${sample}/"
		touch "${LOGS_DIR}/${sample}/calculateMd5s.started"
		echo "Processing ${sample}.."
		echo "logging can be found in: ${LOGS_DIR}/${sample}/"

		if [[ -e "${LOGS_DIR}/${sample}/copybed.calculateMd5s.finished" ]]
		then
			echo "Bed file already copied."
		else
			copybed
		fi
		
		if [[ -e "${LOGS_DIR}/${sample}/fastq.calculateMd5s.finished" ]]
		then
			echo "checksums for fastQ files already calculated"
		else
			calculate "fastq_pass"
		fi
		
		if [[ -e "${LOGS_DIR}/${sample}/pod5.calculateMd5s.finished" ]]
		then
			echo "checksums for pod5 files already calculated"
		else
			calculate "pod5"
		fi
		
		mv "${LOGS_DIR}/${sample}/calculateMd5s."{started,finished}
	fi	
done
