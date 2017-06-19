#!/bin/bash

set -e
set -u

MYINSTALLATIONDIR=$( cd -P "$( dirname "$0" )" && pwd )

groupname=$1

##source config file (zinc-finger.gcc.rug.nl.cfg, leucine-zipper.gcc.rug.nl OR gattaca.cfg)
HOSTNAME_SHORT=$(hostname -s)
. ${MYINSTALLATIONDIR}/${groupname}.cfg
. ${MYINSTALLATIONDIR}/${HOSTNAME_SHORT}.cfg
. ${MYINSTALLATIONDIR}/sharedConfig.cfg
. /home/${groupname}-dm/molgenis.cfg
### VERVANG DOOR UMCG-ATEAMBOT USER
ls ${SAMPLESHEETSDIR}/*.csv > ${SAMPLESHEETSDIR}/allSampleSheets_DiagnosticsCluster.txt
pipeline="dna"

trap finish HUP INT QUIT TERM EXIT ERR

ARR=()
while read i
do
ARR+=($i)
done<${SAMPLESHEETSDIR}/allSampleSheets_DiagnosticsCluster.txt

echo "Logfiles will be written to $LOGDIR"
for line in ${ARR[@]}
do
        csvFile=$(basename $line)
        filePrefix="${csvFile%.*}"
        LOGGER=${LOGDIR}/${filePrefix}/${filePrefix}.copyToPrm.logger

        FINISHED="no"
        OLDIFS=$IFS
        IFS=_
        set $filePrefix
        sequencer=$2
        run=$3
        IFS=$OLDIFS

        if [ -f ${LOGDIR}/copyDataToPrm.sh.locked ]
        then
		echo "copyToPrm is locked"
            	exit 0
	else
		touch ${LOGDIR}/copyDataToPrm.sh.locked
        fi

	##get header to decide later which column is project
        HEADER=$(head -1 ${line})

	##Remove header, only want to keep samples
        sed '1d' $line > ${LOGDIR}/TMP/${filePrefix}.utmp
        OLDIFS=$IFS
        IFS=','
        array=($HEADER)
        IFS=$OLDIFS
        count=1
        for j in "${array[@]}"
        do
          	if [ "${j}" == "project" ]
                then
                    	awk -F"," '{print $'$count'}' ${LOGDIR}/TMP/${filePrefix}.utmp > ${LOGDIR}/TMP/${filePrefix}.utmp2
                fi
                count=$((count + 1))
        done
	cat ${LOGDIR}/TMP/${filePrefix}.utmp2 | sort -V | uniq > ${LOGDIR}/TMP/${filePrefix}.unique.projects

        PROJECTARRAY=()
        while read line
        do
          	PROJECTARRAY+="${line} "

        done<${LOGDIR}/TMP/${filePrefix}.unique.projects

function join_by { local IFS="$1"; shift; echo "$*"; }
        allProjects=$(join_by , $PROJECTARRAY)

         ## create project entity
        for PROJECT in ${PROJECTARRAY[@]}
        do
                echo "project,run_id,pipeline,url,copy_results_prm,date" >  ${LOGDIR}/${PROJECT}/project.csv
                myUrl="https://${MOLGENISSERVER}/menu/main/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${PROJECT}"
                echo "${PROJECT},${filePrefix},DNA,${myUrl},," >>  ${LOGDIR}/${PROJECT}/project.csv

                CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
                TOKEN=${CURLRESPONSE:10:32}
                curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${LOGDIR}/${PROJECT}/project.csv" -FentityName='status_projects' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile
                echo "curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${LOGDIR}/${PROJECT}/project.csv" -FentityName='status_projects' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile"
        done

        function finish {
        echo "${filePrefix} TRAPPED"
                rm -f ${LOGDIR}/copyDataToPrm.sh.locked
        }


        copyRawDiagnosticsClusterToPrm=""
        makeRawDataDir=""


        printf "run_id\tgroup\tdemultiplexing\tcopy_raw\tprojects\tcopy_raw_prm\tdate\n" > $LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading.tsv
  	printf "${filePrefix}\t${groupname}\tfinished\tfinished\t${allProjects}\trunning\t" >> $LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading.tsv
        CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
        TOKEN=${CURLRESPONSE:10:32}
        echo "curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@$LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading.tsv" -FentityName='status_overview' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile"
        curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@$LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading.tsv" -FentityName='status_overview' -Faction=add -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile

	if [ ${HOSTNAME_SHORT} == "calculon" ]
	then
		copyRawDiagnosticsClusterToPrm="${RAWDATADIR}/${filePrefix}/* ${RAWDATADIRPRM}/${filePrefix}"
		makeRawDataDir=$(sh ${RAWDATADIRPRM}/../checkRawData.sh ${RAWDATADIRPRM} ${filePrefix})
	else
		copyRawDiagnosticsClusterToPrm="${RAWDATADIR}/${filePrefix}/* ${groupname}-dm@calculon.hpc.rug.nl:${RAWDATADIRPRM}/${filePrefix}"
	        makeRawDataDir=$(ssh ${groupname}-dm@calculon.hpc.rug.nl "sh ${RAWDATADIRPRM}/../checkRawData.sh ${RAWDATADIRPRM} ${filePrefix}")
	fi
	if [[ -f $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToCluster || -f $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToDiagnosticsCluster ]] && [ ! -f $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToPrm ]
	then
		echo "working on ${filePrefix}"
		countFilesRawDataDirTmp=$(ls ${RAWDATADIR}/${filePrefix}/${filePrefix}* | wc -l)
		if [ "${makeRawDataDir}" == "f" ]
		then
			echo "copying data from DiagnosticsCluster to prm" >> ${LOGGER}
			printf "run_id,group,demultiplexing,copy_raw,projects,date\n" > $LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading
                	printf "${filePrefix}\t${group}\tfinished\tfinished\trunning\t${allProjects}," >> $LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading
		
                	CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
                	TOKEN=${CURLRESPONSE:10:32}

	                curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@$LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading" -FentityName='status_overview' -Faction=update -Fnotify=false https://${MOLGENISSERVER}/plugin/importwizard/importFile
                	
		        rsync -r -av ${copyRawDiagnosticsClusterToPrm} >> $LOGGER
			makeRawDataDir="t"
		fi
		if [ "${makeRawDataDir}" == "t" ]
                then
			countFilesRawDataDirPrm=""
			if [ ${HOSTNAME_SHORT} == "calculon" ]
        		then
				countFilesRawDataDirPrm=$(ls ${RAWDATADIRPRM}/${filePrefix}/${filePrefix}* | wc -l)                    
			else			
				countFilesRawDataDirPrm=$(ssh ${groupname}-dm@calculon.hpc.rug.nl "ls ${RAWDATADIRPRM}/${filePrefix}/${filePrefix}* | wc -l")                    
			fi
                        if [ ${countFilesRawDataDirTmp} -eq ${countFilesRawDataDirPrm} ]
                        then
				COPIEDTOPRM=""
				if [ ${HOSTNAME_SHORT} == "calculon" ]
                	        then
                        	        COPIEDTOPRM=$(sh ${RAWDATADIRPRM}/../check.sh ${RAWDATADIRPRM} ${filePrefix})
				else
					COPIEDTOPRM=$(ssh ${groupname}-dm@calculon.hpc.rug.nl "sh ${RAWDATADIRPRM}/../check.sh ${RAWDATADIRPRM} ${filePrefix}")
				fi	
				
				if [[ "${COPIEDTOPRM}" == *"FAILED"* ]]
                                then
                                        echo "md5sum check failed, the copying will start again" >> ${LOGGER}
                                        rsync -r -av ${copyRawDiagnosticsClusterToPrm} >> $LOGGER 2>&1
					echo "copy failed" >> $LOGDIR/${filePrefix}/${filePrefix}.failed
                                elif [[ "${COPIEDTOPRM}" == *"PASS"* ]]
                                then
					if [ ${HOSTNAME_SHORT} == "calculon" ]
					then	
						scp ${SAMPLESHEETSDIR}/${csvFile} ${groupname}-dm@localhost:${RAWDATADIRPRM}/${filePrefix}/
						scp ${SAMPLESHEETSDIR}/${csvFile} ${groupname}-dm@localhost:${SAMPLESHEETSPRMDIR}
					else
						scp ${SAMPLESHEETSDIR}/${csvFile} ${groupname}-dm@calculon.hpc.rug.nl:${RAWDATADIRPRM}/${filePrefix}/
						scp ${SAMPLESHEETSDIR}/${csvFile} ${groupname}-dm@calculon.hpc.rug.nl:${SAMPLESHEETSPRMDIR}
					
					fi
					echo "finished copying data to calculon" >> ${LOGGER}
					
					echo "finished with rawdata" >> ${LOGDIR}/${filePrefix}/${filePrefix}.copyToPrm.logger

					if ls ${RAWDATADIR}/${filePrefix}/${filePrefix}*.log 1> /dev/null 2>&1
					then
						logFileStatistics=$(cat ${RAWDATADIR}/${filePrefix}/${filePrefix}*.log)
						if [ ${groupname} == "umcg-gaf" ]
						then
							echo -e "Demultiplex statistics ${filePrefix}: \n\n ${logFileStatistics}" | mail -s "Demultiplex statistics ${filePrefix}" ${GAFmail}
						fi
						echo -e "De data voor project ${filePrefix} is gekopieerd naar ${RAWDATADIRPRM}" | mail -s "${filePrefix} copied to permanent storage" ${ONTVANGER}
					fi

					touch $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToPrm

					printf "run_id,group,demultiplexing,copy_raw,projects,date\n" > $LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading
			                printf "${filePrefix}\t${group}\tfinished\tfinished\tfinished\t${allProjects}," >> $LOGDIR/${filePrefix}/${filePrefix}.ToPrm.uploading
		
					rm -f $LOGDIR/${filePrefix}/${filePrefix}.failed
                                fi
                        else
				echo "$filePrefix: $countFilesRawDataDirTmp | $countFilesRawDataDirPrm"
				echo "copying data..." >> $LOGGER
                                rsync -r -av ${copyRawDiagnosticsClusterToPrm} >> $LOGGER 2>&1
                        fi
                fi
        fi

	if [ -f $LOGDIR/${filePrefix}/${filePrefix}.failed ]
	then
		COUNT=$(cat $LOGDIR/${filePrefix}/${filePrefix}.failed | wc -l)
		if [ $COUNT == 10  ]
		then
			echo -e "De md5sum checks voor project ${filePrefix} op ${RAWDATADIRPRM} zijn mislukt.De originele data staat op ${HOSTNAME_SHORT}:${RAWDATADIR}\n\nDeze mail is verstuurd omdat er al 10 pogingen zijn gedaan om de data te kopieren/md5summen" | mail -s "${filePrefix} failing to copy to permanent storage" ${ONTVANGER}
		fi
	fi
	rm -f ${LOGDIR}/copyDataToPrm.sh.locked
done<${SAMPLESHEETSDIR}/allSampleSheets_DiagnosticsCluster.txt

trap - EXIT
exit 0
