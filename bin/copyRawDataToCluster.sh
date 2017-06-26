#!/bin/bash

set -e
set -u

GAT=$1
groupname=$2
gattacaAddress="${GAT}.gcc.rug.nl"
echo $gattacaAddress
MYINSTALLATIONDIR=$( cd -P "$( dirname "$0" )" && pwd )

#
# Source config files.
#
HOSTNAME_SHORT=$(hostname -s)
. ${MYINSTALLATIONDIR}/${groupname}.cfg
. ${MYINSTALLATIONDIR}/${HOSTNAME_SHORT}.cfg
. ${MYINSTALLATIONDIR}/sharedConfig.cfg

### VERVANG DOOR UMCG-ATEAMBOT USER
if ls ${TMP_ROOT_DIR}/Samplesheets/*.csv 1> /dev/null 2>&1
then
ssh ${groupname}-ateambot@${gattacaAddress} "ls ${SCR_ROOT_DIR}/Samplesheets/*.csv" > ${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_${GAT}.txt

gattacaSamplesheets=()

while read line 
do
	gattacaSamplesheets+=("${line} ")
done<${TMP_ROOT_DIR}/Samplesheets/allSampleSheets_${GAT}.txt

echo "Logfiles will be written to ${TMP_ROOT_DIR}/logs"

for line in ${gattacaSamplesheets[@]}
do
echo "working on $line"
	csvFile=$(basename $line)
	if [[ $csvFile == *"dummy"* ]]
        then
                continue
        fi
	filePrefix="${csvFile%.*}"
	LOGGER=${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToCluster.logger

	trap finish HUP INT QUIT TERM EXIT ERR

	FINISHED="no"
	OLDIFS=$IFS
	IFS=_
	set $filePrefix
	sequencer=$2
	run=$3
	IFS=$OLDIFS

	if ssh ${groupname}-ateambot@${gattacaAddress} ls ${SCR_ROOT_DIR}/logs/${filePrefix}_Demultiplexing.finished 1> /dev/null 2>&1 
	then
		### Demultiplexing is finished
		if [ ! -d ${TMP_ROOT_DIR}/logs/${filePrefix}/ ]
		then
			mkdir ${TMP_ROOT_DIR}/logs/${filePrefix}/
		fi
 
		printf ""
	else
		continue;
	fi

	function finish {
        	if [ -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToCluster.locked ]
                then
                	echo "${filePrefix} TRAPPED"
                        rm ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToCluster.locked
                	exit 1
		fi
			
                }

	if [ -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToCluster ]
	then
		continue;
	fi

	if [ -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToCluster.locked ]
	then
		exit 0
	fi
	touch ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToCluster.locked

	## Check if samplesheet is copied
	copyRawGatToCluster="${groupname}-ateambot@${gattacaAddress}:${SCR_ROOT_DIR}/runs/run_${run}_${sequencer}/results/${filePrefix}* ${TMP_ROOT_DIR}/rawdata/ngs/$filePrefix"

	if [[ ! -f ${TMP_ROOT_DIR}/Samplesheets/$csvFile || ! -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.SampleSheetCopied ]]
        then
                scp ${groupname}-ateambot@${gattacaAddress}:${SCR_ROOT_DIR}/Samplesheets/${csvFile} ${TMP_ROOT_DIR}/Samplesheets
                touch ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.SampleSheetCopied
        fi
	## Check if data is already copied to Cluster

	if [ ! -d ${TMP_ROOT_DIR}/rawdata/ngs/$filePrefix ]
	then
		mkdir -p ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/Info
		echo "Copying data to Cluster.." >> $LOGGER
		rsync -r -a ${copyRawGatToCluster}
	fi


	if [[ -d ${TMP_ROOT_DIR}/rawdata/ngs/$filePrefix  && ! -f ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToCluster ]]
	then
		##Compare how many files are on both the servers in the directory
		countFilesRawDataDirTmp=$(ls ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/${filePrefix}* | wc -l)
		countFilesRawDataDirGattaca=$(ssh ${groupname}-ateambot@${gattacaAddress} "ls ${SCR_ROOT_DIR}/runs/run_${run}_${sequencer}/results/${filePrefix}* | wc -l ")

		rsync -r ${groupname}-ateambot@${gattacaAddress}:/groups/umcg-lab/scr01/sequencers/${filePrefix}/InterOp ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/Info/
		rsync ${groupname}-ateambot@${gattacaAddress}:/groups/umcg-lab/scr01/sequencers/${filePrefix}/RunInfo.xml ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/Info/
		rsync ${groupname}-ateambot@${gattacaAddress}:/groups/umcg-lab/scr01/sequencers/${filePrefix}/*unParameters.xml ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/Info/

		if [ ${countFilesRawDataDirTmp} -eq ${countFilesRawDataDirGattaca} ]
		then
			cd ${TMP_ROOT_DIR}/rawdata/ngs/${filePrefix}/
			for i in $(ls *.fq.gz.md5 )
			do
				if md5sum -c $i
				then		
					
					awk '{print $2" CHECKED, and is correct"}' $i >> $LOGGER
				else
					echo "md5sum check failed, the copying will start again" >> $LOGGER
					rsync -r -a ${copyRawGatToCluster}
					echo -e "data copied to Cluster \n" >> $LOGGER
		
				fi
			done
			touch ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.dataCopiedToCluster

		else
			echo "Retry: Copying data to Cluster" >> $LOGGER
			rsync -r -a ${copyRawGatToCluster}
			echo "data copied to Cluster" >> $LOGGER
		fi
	fi
rm ${TMP_ROOT_DIR}/logs/${filePrefix}/${filePrefix}.copyToCluster.locked
done

trap - EXIT
exit 0
