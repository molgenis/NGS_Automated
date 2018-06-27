import os
import glob
import csv
import sys
import re
import argparse
from collections import defaultdict
from os.path import basename


#
## functions
#

def printNewSamplesheet(projectSamplesheetPath, GSSamplesheetDataHashmap, samplesheetOutputDir):

        # Do the combining of GS samplesheet data with inhouse samplesheets
        with open(projectSamplesheetPath, 'r') as f1:
                # next(f1, None)  # skip the headers
                reader = csv.DictReader(f1)
                headers = reader.fieldnames

                #added missing headers barcode1, and Genomescan id for future reference.
                headers.append('barcode1')
                headers.append('GS_ID')

                new_rows_list = []
                new_rows_list.append(headers)

                #next(reader)
                for row in reader:
                        new_row=[]

                        for header in headers:
                                #make barcode_project key.
                                barcodes_project = row['barcode'] + '-' + row['barcode2'] + '-' + row['project']
                                barcodes_combined = row['barcode'] + '-' + row['barcode2']

                                #check if GS barcode_project key combination and Inhouse barcode_project combination are the same.
                                try:
                                        if row['project'] == GSSamplesheetDataHashmap[barcodes_project][0]:

                                                # list of exeptional column header, where the default value for inhouse samplesheet is replaced by GS value.
                                                if header == 'lane':
                                                        new_row.append(GSSamplesheetDataHashmap[barcodes_project][2])
                                                        continue
                                                if header == 'sequencer':
                                                        new_row.append(GSSamplesheetDataHashmap[barcodes_project][5])
                                                        continue
                                                if header == 'run':
                                                        new_row.append(GSSamplesheetDataHashmap[barcodes_project][6])
                                                        continue
                                                if header == 'flowcell':
                                                        new_row.append(GSSamplesheetDataHashmap[barcodes_project][3])
                                                        continue
                                                if header == 'sequencingStartDate':
                                                        new_row.append(GSSamplesheetDataHashmap[barcodes_project][4])
                                                        continue
                                                if header == 'barcode1':
                                                        new_row.append(row['barcode'])
                                                        continue
                                                if header == 'barcode':
                                                        new_row.append(barcodes_combined)
                                                        continue
                                                if header == 'GS_ID':
                                                        new_row.append(GSSamplesheetDataHashmap[barcodes_project][1])
                                                        continue
                                except:
                                        print("keyError:"+ barcodes_project)
                                        print("FATAL: Inhouse barcode_project " + barcodes_project + "and external:project" + GSSamplesheetDataHashmap[barcodes_project][0] + "are not the same.")
                                        exit(1)

                                # add non exeptional columns + values as they where in the original samplesheet to the list.
                                new_row.append(row[header])

                        #Add newly build row to to total csv list.
                        new_rows_list.append(new_row)

                f1.close()

        # Do the writing of new samplesheet tot outputPath.
        newfilename = samplesheetOutputDir + basename(projectSamplesheetPath)
        logger.write("outputFile:" + newfilename + "\n")
        with open(newfilename, 'w') as f2:
                writer = csv.writer(f2, delimiter = ',')
                writer.writerows(new_rows_list)
        f2.close()


def makeOriginalFilenameHashmap(md5file):


        flowcellDict = defaultdict(dict)

        #get sequencerundir information.
        for root, dirs, files in os.walk(args.GenomeScanInputDir):
                for dir in dirs:

                        if re.match("([0-9]{6})_([a-zA-Z0-9]{6})_([0-9]{4})_([a-zA-Z0-9]{9})$", dir):
                                m = re.match("^([0-9]{6})_([a-zA-Z0-9]{6})_([0-9]{4})_([a-zA-Z0-9]{9})$", dir)

                                runStartDate = m.group(1)
                                sequencer = m.group(2)
                                runId = m.group(3)
                                flowcellId = m.group(4)

                                flowcellDict[flowcellId]=(runStartDate,sequencer,runId,flowcellId)

                        else:
                                logger.write(dir + " is not the converted sequence outputdir.\n")

        originalFileNameDict = defaultdict(dict)

        #parse original fileNames, and combine with sequence run dir.
        for line in md5file:

                if re.match("^([a-z0-9]+).+?([a-zA-Z0-9]{9})_([0-9-]+)_([ATGCN]+-[ATGCN]+)_L00([0-9]{1}).+R1.fastq.gz$",line):
                        m = re.match("^([a-z0-9]+).+?([a-zA-Z0-9]{9})_([0-9-]+)_([ATGCN]+-[ATGCN]+)_L00([0-9]{1}).+R1.fastq.gz$", line)
                        flowcellId = m.group(2)
                        GS_ID = m.group(3)
                        barcodes = m.group(4)
                        lane = m.group(5)


                        originalFileNameDict.setdefault(barcodes + '-' + GS_ID, []).append(lane)
                        originalFileNameDict.setdefault(barcodes + '-' + GS_ID, []).append(barcodes)
                        originalFileNameDict.setdefault(barcodes + '-' + GS_ID, []).append(flowcellId)
                        originalFileNameDict.setdefault(barcodes + '-' + GS_ID, []).append(flowcellDict[flowcellId][0])
                        originalFileNameDict.setdefault(barcodes + '-' + GS_ID, []).append(flowcellDict[flowcellId][1])
                        originalFileNameDict.setdefault(barcodes + '-' + GS_ID, []).append(flowcellDict[flowcellId][2])

        md5file.close()
        return originalFileNameDict


#
## Main
#

#get commandline parameters
parser = argparse.ArgumentParser(description='Commandline parameters:')
parser.add_argument("--GenomeScanInputDir")
parser.add_argument("--samplesheetOutputDir")
parser.add_argument("--samplesheetNewDir")
parser.add_argument("--logfile")

args = parser.parse_args()

#open loggerFile
logger = open(args.logfile, 'w')
print("\nStarting to combine samplesheets.\n")

# check if input and output path are not the same.
if args.samplesheetOutputDir == args.samplesheetNewDir:
        logger.write("samplesheet input and outputfolder are the same. Not allowed to prevent overrwiting original files.\n")
        sys.exit('FATAL ERROR! Check: ' + args.logfile)

#Check availability, and readability of GS samplesheet.
for file in glob.iglob(os.path.join(args.GenomeScanInputDir, "CSV_UMCG_*.csv")):
        if os.path.isfile(file) and os.access(file, os.R_OK):
                logger.write("GenomeScan samplesheet:" + file + "\n")
        else:
                logger.write("Either file " + args.GenomeScanInputDir+ "CSV_UMCG_*.csv" + " is missing or is not readable.\n")
                sys.exit('FATAL ERROR! Check: ' + args.logfile)

#Check availability, and readability of md5sum file.
if os.path.isfile(args.GenomeScanInputDir+'checksums.md5') and os.access(args.GenomeScanInputDir+'checksums.md5', os.R_OK):
        md5file = open(args.GenomeScanInputDir + 'checksums.md5', 'r')
        logger.write("md5sum file:" + args.GenomeScanInputDir + 'checksums.md5' + "\n")
else:
        logger.write("Either file " + args.GenomeScanInputDir + 'checksums.md5' + " is missing or is not readable" + "\n")
        sys.exit('FATAL ERROR! Check: ' + args.logfile)

f = open(file,'r') # open the GS samplesheet csv file
GSReader = csv.DictReader(f)  # creates the reader object
GSSamplesheetfileName=(basename(file))
GSheaders = GSReader.fieldnames

# Get filename information from orinal filenames.
GSFilenameDataHashmap = makeOriginalFilenameHashmap(md5file)

GSSamplesheetDataHashmap = defaultdict(dict)
projects = []

#Combine GS samplesheet with original filename information form GSFilenameDataHashmap.
for row in GSReader:
        project=row['Sample_ID']
        projects.append(project)

        try:
                GSSamplesheetDataHashmap.setdefault(row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID'], []).append(row['Sample_ID'])
                GSSamplesheetDataHashmap.setdefault(row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID'], []).append(row['GS_ID'])
                GSSamplesheetDataHashmap.setdefault(row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID'], []).append(GSFilenameDataHashmap[row['Index1'] + "-" + row['Index2'] + "-" + row['GS_ID']][0])
                GSSamplesheetDataHashmap.setdefault(row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID'], []).append(GSFilenameDataHashmap[row['Index1'] + "-" + row['Index2'] + "-" + row['GS_ID']][2])
                GSSamplesheetDataHashmap.setdefault(row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID'], []).append(GSFilenameDataHashmap[row['Index1'] + "-" + row['Index2'] + "-" + row['GS_ID']][3])
                GSSamplesheetDataHashmap.setdefault(row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID'], []).append(GSFilenameDataHashmap[row['Index1'] + "-" + row['Index2'] + "-" + row['GS_ID']][4])
                GSSamplesheetDataHashmap.setdefault(row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID'], []).append(GSFilenameDataHashmap[row['Index1'] + "-" + row['Index2'] + "-" + row['GS_ID']][5])
        except:

                print("FATAL ERROR! Check if barcodes are uniq within project, or GS sampleIDs from samplesheet don't correspond with original filenames barcodes." + row['Sample_ID'] + ': ' + row['Index1'] + "-" + row['Index2'] + "-" + row['Sample_ID' + " vs " + row['Index1'] + "-" + row['Index2'] + "-" + row['GS_ID']])
                logger.write("FATAL ERROR! Check if barcodes are uniq within project: " + row['Sample_ID'])
                sys.exit('FATAL ERROR! Check if barcodes are uniq within projects: ' + args.logfile)
f.close()

#get uniq projectNames
uniq_projects =(sorted(set(projects)))

# count number of samples per project
project_counts={}
for p in (uniq_projects):
        projects.count(p)
        project_counts[p]=projects.count(p)

inhouse_barcodes_sampleId=defaultdict(str)

#dubble check if samplesheets are there, and check if number of samples add up.
for project in (uniq_projects):

        GSProjectSamplesheetDataHashmap=defaultdict(dict)

        if __name__ == '__main__':
                if os.path.isfile(args.samplesheetNewDir+project+'.csv') and os.access(args.samplesheetNewDir+project+'.csv', os.R_OK):
                        print("File "+args.samplesheetNewDir+project+'.csv' + " exists and is readable.")
                else:
                        print("Either file "+args.samplesheetNewDir+project+'.csv'+" is missing or is not readable.")
                        sys.exit('FATAL ERROR! Check: ' + args.logfile)

                if (project_counts[project] == (len(open(args.samplesheetNewDir+project+'.csv').readlines())-1)):
                        logger.write("Number of samples in GS samplesheet (" + str(project_counts[project]) + ") is the same in inhouse samplesheet: " + str(len(open(args.samplesheetNewDir+project+'.csv').readlines())-1) + " for project: " + project + ".\n")
                else:
                        logger.write("FATAL: Number (" + str(project_counts[project]) + ") of samples in GS samplesheet project: " + project + " are NOT the same as in inhouse Project: " + str(project_counts[project]) + ".\n")
                        sys.exit('FATAL ERROR! Check: ' + args.logfile)

        logger.write('GS samplesheet name: ' + project + '.csv' + "\n")
        projectSamplesheetPath=args.samplesheetNewDir + project + '.csv'

        #print new Samplesheet.
        printNewSamplesheet(projectSamplesheetPath, GSSamplesheetDataHashmap, args.samplesheetOutputDir)

print("\nSamplesheet merging DONE.\n")
logger.write("\nSamplesheet merging DONE.\n")
logger.close()
