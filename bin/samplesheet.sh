set -e
set -u

ml ngs-utils

worksheet="170704_M01997_0382_000000000-B66FM_QXTR_17.csv"
sort project.txt.tmp | uniq > project.txt
python samplesheetChecker.py "${worksheet}" 
count=1

zinc="down"
leuc="down"
CLUSTERS=()
if ssh -q zinc-finger.gcc.rug.nl "ls /groups/umcg-gd/tmp05/logs/production.ready"
then
	CLUSTERS+=("ZF")
	mkdir -p thisDir/project_ZF

fi
if ssh -q leucine-zipper.umcg.nl "ls /groups/umcg-gd/tmp06/logs/production.ready"
#if ssh -q calculon.hpc.rug.nl "ls /groups/umcg-gaf/tmp04/logs/production.ready"
then
	CLUSTERS+=("LZ")
	mkdir -p thisDir/project_LZ
fi

cluster=""
count=1
for project in $(awk '$1' "project.txt")
do
	if [[ $((count % 2)) == 0 ]]
	then
		if [[ ${#CLUSTERS[@]} == 2 ]]
		then
			cluster=${CLUSTERS[1]}
		else
			cluster=${CLUSTERS[0]}
		fi

	else
		cluster=${CLUSTERS[0]}
	fi
	extract_samples_from_GAF_list.pl --i "${worksheet}" --o "thisDir/project_${cluster}/${project}.csv" --c project --q "${project}"
	perl -pi -e 's/\r(?!\n)//g' "thisDir/project_${cluster}/${project}.csv"

	count=$((count+1))
done
