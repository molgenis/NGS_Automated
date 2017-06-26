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
if ls ${SAMPLESHEETSDIR}/*.csv 1> /dev/null 2>&1
then
ssh ${groupname}-ateambot@${gattacaAddress} "ls ${GATTACA}/Samplesheets/*.csv" > ${SAMPLESHEETSDIR}/allSampleSheets_${GAT}.txt

gattacaSamplesheets=()

while read line 
do
	gattacaSamplesheets+=("${line} ")
done<${SAMPLESHEETSDIR}/allSampleSheets_${GAT}.txt

echo "Logfiles will be written to $LOGDIR"

for line in ${gattacaSamplesheets[@]}
do
echo "working on $line"
	csvFile=$(basename $line)
	if [[ $csvFile == *"dummy"* ]]
        then
                continue
        fi
	filePrefix="${csvFile%.*}"
	LOGGER=${LOGDIR}/${filePrefix}/${filePrefix}.copyToCluster.logger

	trap finish HUP INT QUIT TERM EXIT ERR

	FINISHED="no"
	OLDIFS=$IFS
	IFS=_
	set $filePrefix
	sequencer=$2
	run=$3
	IFS=$OLDIFS

	if ssh ${groupname}-ateambot@${gattacaAddress} ls ${GATTACA}/logs/${filePrefix}_Demultiplexing.finished 1> /dev/null 2>&1 
	then
		### Demultiplexing is finished
		if [ ! -d ${LOGDIR}/${filePrefix}/ ]
		then
			mkdir ${LOGDIR}/${filePrefix}/
		fi
 
		printf ""
	else
		continue;
	fi

	function finish {
        	if [ -f ${LOGDIR}/${filePrefix}/${filePrefix}.copyToCluster.locked ]
                then
                	echo "${filePrefix} TRAPPED"
                        rm ${LOGDIR}/${filePrefix}/${filePrefix}.copyToCluster.locked
                	exit 1
		fi
			
                }

	if [ -f $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToCluster ]
	then
		continue;
	fi

	if [ -f ${LOGDIR}/${filePrefix}/${filePrefix}.copyToCluster.locked ]
	then
		exit 0
	fi
	touch ${LOGDIR}/${filePrefix}/${filePrefix}.copyToCluster.locked

	## Check if samplesheet is copied
	copyRawGatToCluster="${groupname}-ateambot@${gattacaAddress}:${GATTACA}/runs/run_${run}_${sequencer}/results/${filePrefix}* ${RAWDATADIR}/$filePrefix"

	if [[ ! -f ${SAMPLESHEETSDIR}/$csvFile || ! -f $LOGDIR/${filePrefix}/${filePrefix}.SampleSheetCopied ]]
        then
                scp ${groupname}-ateambot@${gattacaAddress}:${GATTACA}/Samplesheets/${csvFile} ${SAMPLESHEETSDIR}
                touch $LOGDIR/${filePrefix}/${filePrefix}.SampleSheetCopied
        fi
	## Check if data is already copied to Cluster

	if [ ! -d ${RAWDATADIR}/$filePrefix ]
	then
		mkdir -p ${RAWDATADIR}/${filePrefix}/Info
		echo "Copying data to Cluster.." >> $LOGGER
		rsync -r -a ${copyRawGatToCluster}
	fi


	if [[ -d ${RAWDATADIR}/$filePrefix  && ! -f $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToCluster ]]
	then
		##Compare how many files are on both the servers in the directory
		countFilesRawDataDirTmp=$(ls ${RAWDATADIR}/${filePrefix}/${filePrefix}* | wc -l)
		countFilesRawDataDirGattaca=$(ssh ${groupname}-ateambot@${gattacaAddress} "ls ${GATTACA}/runs/run_${run}_${sequencer}/results/${filePrefix}* | wc -l ")

		rsync -r ${groupname}-ateambot@${gattacaAddress}:/groups/umcg-lab/scr01/sequencers/${filePrefix}/InterOp ${RAWDATADIR}/${filePrefix}/Info/
		rsync ${groupname}-ateambot@${gattacaAddress}:/groups/umcg-lab/scr01/sequencers/${filePrefix}/RunInfo.xml ${RAWDATADIR}/${filePrefix}/Info/
		rsync ${groupname}-ateambot@${gattacaAddress}:/groups/umcg-lab/scr01/sequencers/${filePrefix}/*unParameters.xml ${RAWDATADIR}/${filePrefix}/Info/

		if [ ${countFilesRawDataDirTmp} -eq ${countFilesRawDataDirGattaca} ]
		then
			cd ${RAWDATADIR}/${filePrefix}/
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
			touch $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToCluster

		else
			echo "Retry: Copying data to Cluster" >> $LOGGER
			rsync -r -a ${copyRawGatToCluster}
			echo "data copied to Cluster" >> $LOGGER
		fi
	fi
rm ${LOGDIR}/${filePrefix}/${filePrefix}.copyToCluster.locked
done

trap - EXIT
exit 0
