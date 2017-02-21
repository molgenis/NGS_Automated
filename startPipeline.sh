#!/bin/bash

set -e 
set -u

groupname=$1

MYINSTALLATIONDIR=$( cd -P "$( dirname "$0" )" && pwd )
##source config file (zinc-finger.gcc.rug.nl.cfg, leucine-zipper.gcc.rug.nl, calculon.cfg OR gattaca.cfg)
myhost=$(hostname)
#echo "MYINSTALLDIR ${MYINSTALLATIONDIR}"
. ${MYINSTALLATIONDIR}/${groupname}.cfg
. ${MYINSTALLATIONDIR}/${myhost}.cfg
. ${MYINSTALLATIONDIR}/sharedConfig.cfg


NGS_DNA="3.3.1"
NGS_RNA="3.2.4"

count=0 
#echo "Logfiles will be written to $LOGDIR"
#echo "Samplesheets= ${SAMPLESHEETSDIR}"
counting==$(ls ${SAMPLESHEETSDIR}/*.csv | wc -l)
ehco "Checking $counting files "
echo "${SAMPLESHEETSDIR}/*.csv"
for i in $(ls ${SAMPLESHEETSDIR}/*.csv) 
do
  	csvFile=$(basename $i)
        filePrefix="${csvFile%.*}"

	if [ -f $LOGDIR/${filePrefix}/${filePrefix}.scriptsGenerated ]
	then
		continue
	fi

	##get header to decide later which column is project
	HEADER=$(head -1 ${i})

	##Remove header, only want to keep samples
	sed '1d' $i > ${LOGDIR}/TMP/${filePrefix}.tmp
	OLDIFS=$IFS
	IFS=','
	array=($HEADER)
	IFS=$OLDIFS
	count=1

	pipeline="DNA"
	specie="homo_sapiens"
	for j in "${array[@]}"
	do
  		if [ "${j}" == "project" ]
  	     	then
			awk -F"," '{print $'$count'}' ${LOGDIR}/TMP/${filePrefix}.tmp > ${LOGDIR}/TMP/${filePrefix}.tmp2
		elif [[ "${j}" == *"SampleType"* ]]
		then
			awk -F"," '{print $'$count'}' ${LOGDIR}/TMP/${filePrefix}.tmp > ${LOGDIR}/TMP/${filePrefix}.whichPipeline
			pipeline=$(head -1 ${LOGDIR}/TMP/${filePrefix}.whichPipeline)

		elif [[ "${j}" == "specie" ]]
		then
			awk -F"," '{print $'$count'}' ${LOGDIR}/TMP/${filePrefix}.tmp > ${LOGDIR}/TMP/${filePrefix}.specie		
			specie=$(head -1 ${LOGDIR}/TMP/${filePrefix}.specie)
  		elif [ "${j}" == "capturingKit" ]
  	     	then
			awk -F"," '{print $'$count'}' ${LOGDIR}/TMP/${filePrefix}.tmp > ${LOGDIR}/TMP/${filePrefix}.capturingKit

		fi
		count=$((count + 1))
	done

	cat ${LOGDIR}/TMP/${filePrefix}.tmp2 | sort -V | uniq > ${LOGDIR}/TMP/${filePrefix}.uniq.projects

        PROJECTARRAY=()
        while read line
        do
          	PROJECTARRAY+="${line} "

        done<${LOGDIR}/TMP/${filePrefix}.uniq.projects
	count=1

	cat ${LOGDIR}/TMP/${filePrefix}.capturingKit | sort -V | uniq > ${LOGDIR}/TMP/${filePrefix}.uniq.capturingKits	
	miSeqRun="no"
	while read line
        do
		if [[ "${line}" == *"CARDIO_v"* || "${line}" == *"DER_v"* || "${line}" == *"DYS_v"* || "${line}" == *"EPI_v"* || "${line}" == *"FH_v"* || "${line}" == *"LEVER_v"* || "${line}" == *"MYO_v"* || "${line}" == *"NEURO_v"* || "${line}" == *"ONCO_v"* || "${line}" == *"PCS_v"* || "${line}" == *"TID_v"* ]]
		then
			miSeqRun="yes"
			break
		fi
        done<${LOGDIR}/TMP/${filePrefix}.uniq.capturingKits

        OLDIFS=$IFS
        IFS=_
	set $filePrefix
        sequencer=$2
        run=$3
	IFS=$OLDIFS
        LOGGER=${LOGDIR}/${filePrefix}/${filePrefix}.pipeline.logger

	####
	### Decide if the scripts should be created (per Samplesheet)
	##
	#
	function finish {
        if [ -f ${LOGDIR}/${filePrefix}/${filePrefix}.pipeline.locked ]
        then
	       	echo "${filePrefix} TRAPPED"
	        rm ${LOGDIR}/${filePrefix}/${filePrefix}.pipeline.locked
	        fi
        }
        trap finish HUP INT QUIT TERM EXIT ERR

	if [[ -f $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToDiagnosticsCluster || -f $LOGDIR/${filePrefix}/${filePrefix}.dataCopiedToCalculonCluster ]] && [ ! -f $LOGDIR/${filePrefix}/${filePrefix}.scriptsGenerated ]
        then
               	### Step 4: Does the pipeline need to run?
               	if [ "${pipeline}" == "RNA-Lexogen-reverse" ]
               	then
               	        echo "RNA-Lexogen-reverse" >> ${LOGGER}
               	elif [ "${pipeline}" == "RNA-Lexogen" ]
               	then
               	        echo "RNA-Lexogen" >> ${LOGGER}
               	elif [ "${pipeline}" == "RNA" ]
               	then
			module load NGS_RNA/${NGS_RNA}

			projectName=""
			workflowRNA="hisat"
			build="b37"

			for PROJECT in ${PROJECTARRAY[@]}
                	do
               	        	projectName=${PROJECT}
				
			done
		
			echo "RNA" >> ${LOGGER}
			echo "WE ARE IN"
				

			#
			##      CHANGE WHEN FINISHED TESTING
			###
				EBROOTNGS_AUTOMATED=/home/umcg-rkanninga/github/NGS_Automated/
			###
			##
			#
						
			if [[ "${projectName}" == *"Lexogen"* ]]
			then
				workflowRNA="lexogen"
			fi
			# callithrix_jacchus, mus_musculus, homo_sapiens
			if [ $specie != "homo_sapiens" ]
			then
				build="b38"
			fi
			
			mkdir -p ${GENERATEDSCRIPTS}/${filePrefix}/
			echo "copying $EBROOTNGS_AUTOMATED/automated_RNA_generate_template.sh to ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh" >> $LOGGER		

			cp  $EBROOTNGS_AUTOMATED/automated_RNA_generate_template.sh ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh

			 perl -pi -e "s|VERSIONFROMSTARTPIPELINESCRIPT|${NGS_RNA}|" ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh

			if [ -f ${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv ]
                        then
                            	echo "${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv already existed, will now be removed and will be replaced by a fresh copy" >> $LOGGER
                                rm ${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv
                        fi

                        cp ${SAMPLESHEETSDIR}/${csvFile} ${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv

                        cd ${GENERATEDSCRIPTS}/${filePrefix}/

                        echo "sh ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh "${filePrefix}" ${build} ${specie} ${workflowRNA}"
			echo "sh ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh "${filePrefix}" ${build} ${specie} ${workflowRNA}" > ${GENERATEDSCRIPTS}/${filePrefix}/generate.logger
                        sh ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh "${filePrefix}" ${build} ${specie} ${workflowRNA} > ${GENERATEDSCRIPTS}/${filePrefix}/generate.logger 2>&1
                        cd scripts
			touch ${LOGDIR}/${filePrefix}/${filePrefix}.pipeline.locked
                        sh submit.sh
			rm ${LOGDIR}/${filePrefix}/${filePrefix}.pipeline.locked
                       	touch $LOGDIR/${filePrefix}/${filePrefix}.scriptsGenerated

               	elif [ "${pipeline}" == "DNA" ]
               	then
			module load NGS_DNA/${NGS_DNA}

			if pipelineVersion=$(module list | grep -o -P 'NGS_DNA(.+)')
			then
				echo ""
			else
				underline=`tput smul`
				normal=`tput sgr0`
				bold=`tput bold`
				printf "${bold}WARNING: there is no pipeline version loaded, this can be because this script is run manually.\nA default version of the NGS_DNA pipeline will be loaded!\n\n"
				module load $DNA
				pipelineVersion=$(module list | grep -o -P 'NGS_DNA(.+)')
				printf "The version which is now loaded is $pipelineVersion${normal}\n\n"
			fi
                       	mkdir -p ${GENERATEDSCRIPTS}/${filePrefix}/

			batching="_chr"

			if [ "${miSeqRun}" == "yes" ]
			then
				batching="_small"
			fi

			echo "copying $EBROOTNGS_AUTOMATED/automated_generate_template.sh to ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh" >> $LOGGER
                       	cp ${EBROOTNGS_AUTOMATED}/automated_generate_template.sh ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh

			perl -pi -e "s|VERSIONFROMSTARTPIPELINESCRIPT|${NGS_DNA}|" ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh

			if [ -f ${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv ]
			then
				echo "${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv already existed, will now be removed and will be replaced by a fresh copy" >> $LOGGER
				rm ${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv
			fi

			cp ${SAMPLESHEETSDIR}/${csvFile} ${GENERATEDSCRIPTS}/${filePrefix}/${filePrefix}.csv

			cd ${GENERATEDSCRIPTS}/${filePrefix}/

			sh ${GENERATEDSCRIPTS}/${filePrefix}/generate.sh "${filePrefix}" ${batching} > ${GENERATEDSCRIPTS}/${filePrefix}/generate.logger 2>&1 

			cd scripts
                        touch ${LOGDIR}/${filePrefix}/${filePrefix}.pipeline.locked
                        sh submit.sh
                        rm ${LOGDIR}/${filePrefix}/${filePrefix}.pipeline.locked
                        touch $LOGDIR/${filePrefix}/${filePrefix}.scriptsGenerated
		fi
	fi

	####
	### If generatedscripts is already done, step in this part to submit the jobs (per project)
	##
	#
	if [ -f $LOGDIR/${filePrefix}/${filePrefix}.scriptsGenerated ] 
	then
		for PROJECT in ${PROJECTARRAY[@]}
		do
			if [ ! -d ${LOGDIR}/${PROJECT} ]
			then
				mkdir ${LOGDIR}/${PROJECT}
			fi
 
			function finishProject {
                                if [ -f ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.locked ]
                                then
                                        echo "${PROJECT} TRAPPED"
                                        rm ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.locked      
                                fi
                        }
			trap finishProject HUP INT QUIT TERM EXIT ERR
			
			WHOAMI=$(whoami)
			HOSTN=$(hostname)
		        LOGGER=${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.logger
			if [[ ! -f ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.started  && ! -f ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.locked && ! -f ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.finished ]]
			then
				touch ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.locked
				cd ${PROJECTSDIR}/${PROJECT}/run01/jobs/
				sh submit.sh

				touch ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.started
				echo "${PROJECT} started" >> $LOGGER
				echo "${PROJECT} started"	
				printf "Pipeline: ${pipeline}\nStarttime:`date +%d/%m/%Y` `date +%H:%M`\nProject: $PROJECT\nStarted by: $WHOAMI\nHost: ${HOSTN}\n\nProgress can be followed via the command squeue -u $WHOAMI on $HOSTN.\nYou will receive an email when the pipeline is finished!\n\nCheers from the GCC :)" | mail -s "NGS_DNA pipeline is started for project $PROJECT on `date +%d/%m/%Y` `date +%H:%M`" ${ONTVANGER}
				sleep 40
				rm -f ${LOGDIR}/${PROJECT}/${PROJECT}.pipeline.locked
			fi
		done
	fi
done

trap - EXIT
exit 0
