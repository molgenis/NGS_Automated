#!/bin/bash

set -e
set -u

MYINSTALLATIONDIR=$( cd -P "$( dirname "$0" )" && pwd )

groupname=$1

#
# Source config files.
#
HOSTNAME_SHORT=$(hostname -s)
. ${MYINSTALLATIONDIR}/${groupname}.cfg
. ${MYINSTALLATIONDIR}/${HOSTNAME_SHORT}.cfg
. ${MYINSTALLATIONDIR}/sharedConfig.cfg

### VERVANG DOOR UMCG-ATEAMBOT USER
ls ${TMP_ROOT_DIR}/Samplesheets/*.csv > ${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_DiagnosticsCluster.txt
pipeline="dna"

trap finish HUP INT QUIT TERM EXIT ERR

ARR=()
while read i
do
ARR+=($i)
done<${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_DiagnosticsCluster.txt

echo "Logfiles will be written to ${TMP_ROOT_DIR}/logs"
for line in ${ARR[@]}
do
        csvFile=$(basename $line)
        filePrefix="${csvFile%.*}"
        LOGGER=${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToPrm.logger

        FINISHED="no"
        OLDIFS=$IFS
        IFS=_
        set $filePrefix
        sequencer=$2
        run=$3
        IFS=$OLDIFS

        if [ -f ${TMP_ROOT_DIR}/logs/copyDataToPrm.sh.locked ]
        then
		echo "copyToPrm is locked"
            	exit 0
	else
		touch ${TMP_ROOT_DIR}/logs/copyDataToPrm.sh.locked
        fi

	##get header to decide later which column is project
        HEADER=$(head -1 ${line})

	##Remove header, only want to keep samples
        sed '1d' $line > ${TMP_ROOT_DIR}/logs/TMP/${filePrefix}.utmp
        OLDIFS=$IFS
        IFS=','
        array=($HEADER)
        IFS=$OLDIFS
        count=1
        for j in "${array[@]}"
        do
          	if [ "${j}" == "project" ]
                then
                    	awk -F"," '{print $'$count'}' ${TMP_ROOT_DIR}/logs/TMP/${filePrefix}.utmp > ${TMP_ROOT_DIR}/logs/TMP/${filePrefix}.utmp2
                fi
                count=$((count + 1))
        done
	cat ${TMP_ROOT_DIR}/logs/TMP/${filePrefix}.utmp2 | sort -V | uniq > ${TMP_ROOT_DIR}/logs/TMP/${filePrefix}.unique.projects

        PROJECTARRAY=()
        while read line
        do
          	PROJECTARRAY+="${line} "

        done<${TMP_ROOT_DIR}/logs/TMP/${filePrefix}.unique.projects

	function finish {
	echo "${filePrefix} TRAPPED"
		rm -f ${TMP_ROOT_DIR}/logs/copyDataToPrm.sh.locked
	}

	
	copyRawDiagnosticsClusterToPrm=""
        makeRawDataDir=""

	if [ ${HOSTNAME_SHORT} == "calculon" ]
	then
		copyRawDiagnosticsClusterToPrm="${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/* ${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}"
		makeRawDataDir=$(sh ${PRM_ROOT_DIR}/rawdata/ngs/../checkRawData.sh ${PRM_ROOT_DIR}/rawdata/ngs ${filePrefix})
	else
		copyRawDiagnosticsClusterToPrm="${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/* ${groupname}-dm@calculon.hpc.rug.nl:${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}"
	        makeRawDataDir=$(ssh ${groupname}-dm@calculon.hpc.rug.nl "sh ${PRM_ROOT_DIR}/rawdata/ngs/../checkRawData.sh ${PRM_ROOT_DIR}/rawdata/ngs ${filePrefix}")
	fi
	if [[ -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToCluster || -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToDiagnosticsCluster ]] && [ ! -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToPrm ]
	then
		echo "working on ${filePrefix}"
		countFilesRawDataDirTmp=$(ls ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}* | wc -l)
		if [ "${makeRawDataDir}" == "f" ]
		then
			echo "copying data from DiagnosticsCluster to prm" >> ${LOGGER}
                        rsync -r -av ${copyRawDiagnosticsClusterToPrm} >> $LOGGER
			makeRawDataDir="t"
		fi
		if [ "${makeRawDataDir}" == "t" ]
                then
			countFilesRawDataDirPrm=""
			if [ ${HOSTNAME_SHORT} == "calculon" ]
        		then
				countFilesRawDataDirPrm=$(ls ${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}* | wc -l)                    
			else			
				countFilesRawDataDirPrm=$(ssh ${groupname}-dm@calculon.hpc.rug.nl "ls ${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}* | wc -l")                    
			fi
                        if [ ${countFilesRawDataDirTmp} -eq ${countFilesRawDataDirPrm} ]
                        then
				COPIEDTOPRM=""
				if [ ${HOSTNAME_SHORT} == "calculon" ]
                	        then
                        	        COPIEDTOPRM=$(sh ${PRM_ROOT_DIR}/rawdata/ngs/../check.sh ${PRM_ROOT_DIR}/rawdata/ngs ${filePrefix})
				else
					COPIEDTOPRM=$(ssh ${groupname}-dm@calculon.hpc.rug.nl "sh ${PRM_ROOT_DIR}/rawdata/ngs/../check.sh ${PRM_ROOT_DIR}/rawdata/ngs ${filePrefix}")
				fi	
				
				if [[ "${COPIEDTOPRM}" == *"FAILED"* ]]
                                then
                                        echo "md5sum check failed, the copying will start again" >> ${LOGGER}
                                        rsync -r -av ${copyRawDiagnosticsClusterToPrm} >> $LOGGER 2>&1
					echo "copy failed" >> ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.failed
                                elif [[ "${COPIEDTOPRM}" == *"PASS"* ]]
                                then
					if [ ${HOSTNAME_SHORT} == "calculon" ]
					then	
						scp ${TMP_ROOT_DIR}/Samplesheets/${csvFile} ${groupname}-dm@localhost:${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}/
						scp ${TMP_ROOT_DIR}/Samplesheets/${csvFile} ${groupname}-dm@localhost:${PRM_ROOT_DIR}/rawdata/Samplesheets
					else
						scp ${TMP_ROOT_DIR}/Samplesheets/${csvFile} ${groupname}-dm@calculon.hpc.rug.nl:${PRM_ROOT_DIR}/rawdata/ngs/${filePrefix}/
						scp ${TMP_ROOT_DIR}/Samplesheets/${csvFile} ${groupname}-dm@calculon.hpc.rug.nl:${PRM_ROOT_DIR}/rawdata/Samplesheets
					
					fi
					echo "finished copying data to calculon" >> ${LOGGER}
					
					echo "finished with rawdata" >> ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToPrm.logger

					if ls ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}*.log 1> /dev/null 2>&1
					then
						logFileStatistics=$(cat ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}*.log)
						if [ ${groupname} == "umcg-gaf" ]
						then
							echo -e "Demultiplex statistics ${filePrefix}: \n\n ${logFileStatistics}" | mail -s "Demultiplex statistics ${filePrefix}" ${EMAIL_TO}
						else
						    echo -e "De data voor project ${filePrefix} is gekopieerd naar ${PRM_ROOT_DIR}/rawdata/ngs" | mail -s "${filePrefix} copied to permanent storage" ${EMAIL_TO}
						fi
						touch ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToPrm
					fi
						rm -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.failed
                                fi
                        else
				echo "$filePrefix: $countFilesRawDataDirTmp | $countFilesRawDataDirPrm"
				echo "copying data..." >> $LOGGER
                                rsync -r -av ${copyRawDiagnosticsClusterToPrm} >> $LOGGER 2>&1
                        fi
                fi
        fi

	if [ -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.failed ]
	then
		COUNT=$(cat ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.failed | wc -l)
		if [ $COUNT == 10  ]
		then
			HOSTNA=$(hostname)
			echo -e "De md5sum checks voor project ${filePrefix} op ${PRM_ROOT_DIR}/rawdata/ngs zijn mislukt.De originele data staat op ${HOSTNA}:${TMP_ROOT_DIR}/rawdata/ngs\n\nDeze mail is verstuurd omdat er al 10 pogingen zijn gedaan om de data te kopieren/md5summen" | mail -s "${filePrefix} failing to copy to permanent storage" ${EMAIL_TO}
		fi
	fi
	rm -f ${TMP_ROOT_DIR}/logs/copyDataToPrm.sh.locked
done<${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_DiagnosticsCluster.txt

trap - EXIT
exit 0
