# SG F100 NGS_Automated 

The NGS_Automated is created to automatically go through all the steps to get from Bcl (NGS) or IDAT (Array) to a variant output file (vcf) and storing that data to an archive
In this document all the steps will be explained separately and which user is executing the script and on which server.

## 1	NGS
#### 1.1 Demultiplexing (Bcl to FastQ)
The NGS pipeline starts with data that comes from the NextSeq sequencer. The output of this data is in bcl format.
The NGS_Demultiplexing pipeline (SG F101 NGS_Demultiplexing) will convert the bcl to a readable format (fastQ format).
The script will be triggered when there is data in /groups/umcg-lab/scr01/sequencers/ folder (this is where the sequencer writes its data to).

To start when it checks whether there is a file named RunCompletionStatus.xml in the subfolder ({sequencingStartDate}_{sequencer}_{run}_{flowcell}) and there is a samplesheet in the samplesheets folder (/groups/{group}/scr01/Samplesheets/) matching the foldername but with a .csv extension:
({sequencingStartDate}_{sequencer}_{run}_{flowcell}.csv

**Scriptname:** demultiplexing.sh <br />
User:**  umcg-gd-ateambot <br />
Cluster:** gattaca01.gcc.rug.nl / gattaca02.gcc.rug.nl<br />

**Trigger(s):** samplesheet + RuncompletionStatus.xml <br />
**Finished check:** logs folder contains .demultiplexing.finished file <br />
**Cronjob:** */30 * * * * /bin/bash -c "export SOURCE_HPC_ENV="True"; . ~/.bashrc; module load NGS_Automated/${VERSION}-NGS_Demultiplexing-${VERSION}; demultiplexing.sh -g ${GROUP}"


#### 1.2 copy FastQ files (rawdata) to prm
The data will be transferred from the gattaca machines to a permanent storage (prm)
**Scriptname:** copyRawDataToPrm.sh<br />
**User:**  umcg-gd-dm <br />
**Cluster:** chaperone.umcg.nl / coenzyme.umcg.nl<br />

**Trigger(s):** Samplesheet + logs (.demultiplexing.finished)<br />
**Finished check:** logs folder contains .copyRawDataToPrm.finished file<br />
**Cronjob:** */10 * * * * /bin/bash -c "export SOURCE_HPC_ENV="True"; . ~/.bashrc; module load NGS_Automated/${VERSION}-bare; copyRawDataToPrm.sh -g umcg-gd -s ${SOURCESERVER}


#### 1.3 running NGS_DNA pipeline
This script will first produce a generatedscripts <br>
**Scriptname:** startPipeline.sh<br />
**User:**  umcg-gd-ateambot<br />
**Cluster:** leucine-zipper.umcg.nl / zinc-finger.gcc.rug.nl<br />

**Start check:** .copyRawDataToPrm.finished<br />
**Finished check:** logs folder contains .pipeline.finished<br />
**Cronjob:** */30 * * * * /bin/bash -c "export SOURCE_HPC_ENV="True"; . ~/.bashrc; module load NGS_Automated/${VERSION}-NGS_DNA-${VERSION}; startPipeline.sh -g umcg-gd"

#### 1.4 calculate project md5s
**Scriptname:** calculateProjectMd5s.sh<br />
**User:**  umcg-gd-ateambot<br />
**Cluster:** leucine-zipper.umcg.nl / zinc-finger.gcc.rug.nl<br />

**Start check:** .pipeline.finished<br />
**Finished check:** logs folder contains .calculateProjectMd5s.finished<br />
**Cronjob:** */30 * * * * /bin/bash -c "export SOURCE_HPC_ENV="True"; . ~/.bashrc; module load NGS_Automated/${VERSION}-bare; calculateProjectMd5s.sh -g umcg-gd"

#### 1.5 copy project data to prm
This script will copy the project data to an archive storage

**Scriptname:** calculateProjectMd5s.sh<br />
**User:**  umcg-gd-dm<br />
**Cluster:** chaperone.umcg.nl / coenzyme.umcg.nl<br />

**Start check:** .calculateProjectMd5s.finished<br />
**Finished check:** logs folder contains .calculateProjectMd5s.finished<br />
**Cronjob:** */30 * * * * /bin/bash -c "export SOURCE_HPC_ENV="True"; . ~/.bashrc; module load NGS_Automated/${VERSION}-bare; copyProjectDataToPrm.sh -g umcg-gd"


2.	Array

