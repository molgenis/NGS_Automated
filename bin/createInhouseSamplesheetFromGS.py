#!/usr/bin/env python

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

#
# Combine the GS samplesheet data with that from the partial inhouse samplesheets
# to create new ones that are complete (= contain all the meta-data required for sequence analysis).
#
def printNewSamplesheet(_projectSamplesheetPath, _gsSamplesheetDataHashmap, _samplesheetsOutputDir):
    #
    # Parse incomplete inhouse sample sheet (per project).
    #
    with open(_projectSamplesheetPath, 'r') as _f1:
        _reader = csv.DictReader(_f1)
        _headers = _reader.fieldnames
        #
        # Add extra columns barcode1 and GenomeScanID.
        #
        _headers.append('barcode1')
        _headers.append('GS_ID')
        #
        # Parse sample from inhouse samplesheet.
        #
        _newRows = []
        _newRows.append(_headers)
        for _row in _reader:
            _barcodes = _row['barcode'] + '-' + _row['barcode2']
            _barcodesProject = _row['barcode'] + '-' + _row['barcode2'] + '-' + _row['project'] # Uniquely identifies a sample
            #
            # Try to create new rows: one for each flowcell-lane combination for each sample (=barcodes-project combination).
            #
            # Example data structure of _gsSamplesheetDataHashmap:
            # defaultdict(<type 'dict'>, {
            #    'CTCTCTAC-AGAGGATA-QXTR_426-Exoom_v1': {
            #        'project': 'QXTR_426-Exoom_v1', 'GS_ID': '103373-032-059', 
            #        'FastQs': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CTCTCTAC-AGAGGATA'}, 
            #                   {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CTCTCTAC-AGAGGATA'}]},
            #
            try:
                if _row['project'] == _gsSamplesheetDataHashmap[_barcodesProject]['project']:
                    for FastQ in _gsSamplesheetDataHashmap[_barcodesProject]['FastQs']:
                        _newRowValues=[]
                        for _header in _headers:
                            #
                            # list of columns for which the default/empty value from the inhouse samplesheet is replaced by values from the GS samplesheet.
                            #
                            if _header == 'lane':
                                _newRowValues.append(FastQ['lane'])
                            elif _header == 'sequencer':
                                _newRowValues.append(FastQ['sequencer'])
                            elif _header == 'run':
                                _newRowValues.append(FastQ['run'])
                            elif _header == 'flowcell':
                                _newRowValues.append(FastQ['flowcell'])
                            elif _header == 'sequencingStartDate':
                                _newRowValues.append(FastQ['sequencingStartDate'])
                            elif _header == 'barcode1':
                                _newRowValues.append(_row['barcode'])
                            elif _header == 'barcode':
                                _newRowValues.append(_barcodes)
                            elif _header == 'GS_ID':
                                _newRowValues.append(_gsSamplesheetDataHashmap[_barcodesProject]['GS_ID'])
                            else:
                                #
                                # Copy other, unmodified columns + their values from the original samplesheet to the new row.
                                #
                                _newRowValues.append(_row[_header])
                        #
                        # Add newly compiled row to list of new rows.
                        #
                        _newRows.append(_newRowValues)
                else:
                    print("FATAL: project name for the sample (_barcodesProject=" + _barcodesProject + ") from inhouse sample sheet and from GenomeScan sample sheet is not the same project.")
                    exit(1)
            except:
                logger.write('FATAL: failed to supplement sample (barcode_project=' + _barcodesProject + ') with meta-data from GenomeScan sample sheet.' + "\n")
                print('FATAL: failed to supplement sample (barcode_project=' + _barcodesProject + ') with meta-data from GenomeScan sample sheet.')
                exit(1)
        _f1.close()
    #
    # Write new inhouse complete samplesheet per project.
    #
    _newSamplesheetPath = _samplesheetsOutputDir + basename(_projectSamplesheetPath)
    logger.write("Writing new complete samplesheet to: " + _newSamplesheetPath + "...\n")
    with open(_newSamplesheetPath, 'w') as f2:
        writer = csv.writer(f2, delimiter = ',')
        writer.writerows(_newRows)
    f2.close()


def makeOriginalFilenameHashmap(_checksumsFilePath):
    #
    # get sequence run dir information.
    # example sequenceRunDir: 180719_K00296_0345_HTCKVBBYXX
    #
    _flowcellDict = defaultdict(dict)
    for _root, _dirs, _files in os.walk(args.genomeScanInputDir):
        for _dir in _dirs:
            if re.match("([0-9]{6})_([a-zA-Z0-9]{6})_([0-9]{4})_([a-zA-Z0-9]{9})$", _dir):
                _m = re.match("^([0-9]{6})_([a-zA-Z0-9]{6})_([0-9]{4})_([a-zA-Z0-9]{9})$", _dir)
                _sequencingStartDate = _m.group(1)
                _sequencer = _m.group(2)
                _run = _m.group(3)
                _flowcell = _m.group(4)
                #
                # Example data structure:
                # defaultdict(<type 'dict'>, {'HTCKVBBYXX': {'flowcell': 'HTCKVBBYXX', 'sequencingStartDate': '170619', 'sequencer': 'K00296', 'run': '0111'}})
                #
                _flowcellDict[_flowcell]['sequencingStartDate'] = _sequencingStartDate
                _flowcellDict[_flowcell]['sequencer'] = _sequencer
                _flowcellDict[_flowcell]['run'] = _run
                logger.write('Parsed sequencingStartDate=' + _sequencingStartDate + ', sequencer=' + _sequencer + ' and run=' + _run + ' from converted FastQ output dir ' + _dir + ".\n")
            else:
                logger.write('Skipping dir ' + _dir + ', whose name is not in the expected format for a dir containing (renamed) FastQ files.' + "\n")
    #
    # Parse original fileNames listed in checksum file and combine with sequence run info for each sample.
    #
    # Example line from MD5 checksum file:
    #8f246fccfda8ba676b82edc1f66b0006  HWCKVBBXX_103373-011-004_GGACTCCT-ATAGAGAG_L001_R1.fastq.gz
    #
    _checksumsFileHandle=open(_checksumsFilePath, 'r')
    _originalFileNameDict = defaultdict(dict)
    for _line in _checksumsFileHandle:
        if re.match("^([a-z0-9]+).+?([a-zA-Z0-9]{9})_([0-9-]+)_([ATGCN]+-[ATGCN]+)_L00([0-9]{1}).+R1.fastq.gz$", _line):
            _m = re.match("^([a-z0-9]+).+?([a-zA-Z0-9]{9})_([0-9-]+)_([ATGCN]+-[ATGCN]+)_L00([0-9]{1}).+R1.fastq.gz$", _line)
            _flowcell = _m.group(2)
            _genomeScanID = _m.group(3)
            _barcodes = _m.group(4)
            _lane = _m.group(5)
            #
            # Example structure of _originalFileNameDict showing 2 samples both having 2 lanes from 2 different flowcells:
            #
            # defaultdict(<type 'dict'>, {'CGTACTAG-AGGCTTAG-103373-032-064': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CGTACTAG-AGGCTTAG'}, 
            #                                                                  {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CGTACTAG-AGGCTTAG'}], 
            #                             'CAGAGAGG-TCTACTCT-103373-032-058': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CAGAGAGG-TCTACTCT'}, 
            #                                                                  {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CAGAGAGG-TCTACTCT'}])
            #
            _barcodesPlusGenomeScanID = _barcodes + '-' + _genomeScanID
            if _originalFileNameDict.has_key(_barcodesPlusGenomeScanID):
                _originalFileNameDict[_barcodesPlusGenomeScanID].append(
                    {'lane': _lane, 'barcodes': _barcodes, 'flowcell': _flowcell, 
                     'sequencingStartDate': _flowcellDict[_flowcell]['sequencingStartDate'], 'sequencer': _flowcellDict[_flowcell]['sequencer'], 'run': _flowcellDict[_flowcell]['run']})
            else:
                _originalFileNameDict[_barcodesPlusGenomeScanID] = [
                    {'lane': _lane, 'barcodes': _barcodes, 'flowcell': _flowcell, 
                     'sequencingStartDate': _flowcellDict[_flowcell]['sequencingStartDate'], 'sequencer': _flowcellDict[_flowcell]['sequencer'], 'run': _flowcellDict[_flowcell]['run']}]
    _checksumsFileHandle.close()
    return _originalFileNameDict

#
# Check for argparse input validation: check if input is dir and if we have read permission.
#
def readableDir(prospectiveDir):
    if not os.path.isdir(prospectiveDir):
        raise Exception("readableDir: {0} is not a valid path".format(prospectiveDir))
    if os.access(prospectiveDir, os.R_OK):
        return prospectiveDir
    else:
        raise Exception("readableDir: {0} is not a readable dir".format(prospectiveDir))

#
##
### Main
##
#

#
# Get commandline parameters.
#
parser = argparse.ArgumentParser(description='Commandline parameters:')
parser.add_argument("--genomeScanInputDir", type=readableDir, required=True, help='Input directory containing one GenomeScan batch (*.csv, checksums.m5 and *.fastq.gz files).')
parser.add_argument("--samplesheetsOutputDir", type=readableDir, required=True, help='Directory where complete, merged inhouse samplesheets are stored.')
parser.add_argument("--inhouseSamplesheetsInputDir", type=readableDir , required=True, help='Input directory containing incomplete new inhouse samplesheets.')
parser.add_argument("--logFile" , required=True)
args = parser.parse_args()
#
# Open log file.
#
logger = open(args.logFile, 'w')
print("\nStarting to combine samplesheets.\n")
#
# Check if input and output path are not the same.
#
if args.samplesheetsOutputDir == args.inhouseSamplesheetsInputDir:
    logger.write("Samplesheet input and output folder are the same. Not allowed to prevent overrwiting original files.\n")
    sys.exit('FATAL ERROR! Check the log file: ' + args.logFile)
#
# Check availability and readability of GS samplesheet.
#
for gsSamplesheetFile in glob.iglob(os.path.join(args.genomeScanInputDir, "CSV_UMCG_*.csv")):
    if os.path.isfile(gsSamplesheetFile) and os.access(gsSamplesheetFile, os.R_OK):
        logger.write("GenomeScan samplesheet:" + gsSamplesheetFile + "\n")
    else:
        logger.write("Either the " + args.genomeScanInputDir+ "CSV_UMCG_*.csv" + " file is missing or it is not readable.\n")
        sys.exit('FATAL ERROR! Check the log file: ' + args.logFile)
#
# Check availability and readability of md5sum file.
#
checksumsFilePath = args.genomeScanInputDir + 'checksums.md5'
if os.path.isfile(checksumsFilePath) and os.access(checksumsFilePath, os.R_OK):
    logger.write('Found checksums file: ' + checksumsFilePath + "\n")
else:
    logger.write('Either the ' + checksumsFilePath + ' file is missing or it is not readable.' + "\n")
    sys.exit('FATAL ERROR! Check the log file: ' + args.logFile)

#
# Get sequencing meta-data from original filenames as listed in the checksum file.
#
gsFilenameDataHashmap = makeOriginalFilenameHashmap(checksumsFilePath)

#
# Combine GS samplesheet with original filename information form gsFilenameDataHashmap.
# GS samplesheet filestructure:
#          GS_ID,         Sample_ID, Pool,   Index1,   Index2
# 103473-011-001, QXTR_222-Exoom_v1,    1, CGAGGCTG, AGGCTTAG
#
gsSamplesheetFileHandle = open(gsSamplesheetFile,'r')
gsReader = csv.DictReader(gsSamplesheetFileHandle)
gsHeaders = gsReader.fieldnames
gsSamplesheetDataHashmap = defaultdict(dict)
projects = []
for row in gsReader:
    if row['Sample_ID'] in (None,""):
        logger.write('WARN: Empty row detected in GS samplesheet.' + "\n")
        continue
    project=row['Sample_ID'] # Confusingly 'Sample_ID' column actually contains the projectName.
    genomeScanID=row['GS_ID']
    projects.append(project)
    barcodesProject = row['Index1'] + '-' + row['Index2'] + '-' + project
    barcodesGenomeScanID = row['Index1'] + '-' + row['Index2'] + '-' + genomeScanID
    if gsSamplesheetDataHashmap.has_key(barcodesProject):
        logger.write('FATAL: Barcodes ' + row['Index1'] + '-' + row['Index2'] + ' are not uniq in project ' + project + "\n")
        sys.exit('FATAL ERROR! Check the log file: ' + args.logFile)
    try:
        #
        # Example data structure of gsSamplesheetDataHashmap:
        # defaultdict(<type 'dict'>, {
        #    'CTCTCTAC-AGAGGATA-QXTR_426-Exoom_v1': {
        #        'project': 'QXTR_426-Exoom_v1', 'GS_ID': '103373-032-059', 
        #        'FastQs': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CTCTCTAC-AGAGGATA'}, 
        #                   {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CTCTCTAC-AGAGGATA'}]},
        #    'CAGAGAGG-TCTACTCT-QXTR_426-Exoom_v1': {
        #        'project': 'QXTR_426-Exoom_v1', 'GS_ID': '103373-032-058', 
        #        'FastQs': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CAGAGAGG-TCTACTCT'}, 
        #                   {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CAGAGAGG-TCTACTCT'}]}}
        #
        gsSamplesheetDataHashmap[barcodesProject] = {
            'project': project, 'GS_ID': genomeScanID,
            'FastQs': gsFilenameDataHashmap[barcodesGenomeScanID]
        }
        # For debugging data structure only:
        #import pprint
        #pp = pprint.PrettyPrinter(indent=4)
        #pp.pprint(gsSamplesheetDataHashmap)
        #pp.pprint('#####################################################')
    except:
        logger.write('FATAL: Meta data parsed from original FastQ filenames as supplied by GenomeScan missing for sample ' + genomeScanID + ' with barcodes ' + row['Index1'] + '-' + row['Index2'] + ' from project ' + project + ".\n")
        sys.exit('FATAL ERROR! Check the log file: ' + args.logFile)
gsSamplesheetFileHandle.close()
#
# Get list of uniq project names and count number of samples per project.
#
uniqProjects =(sorted(set(projects)))
projectCounts={}
for uniqProject in (uniqProjects):
    projectCounts[uniqProject]=projects.count(uniqProject)
#
# Parse sample sheets per project.
#
for project in (uniqProjects):
    if __name__ == '__main__':
        projectSamplesheetPath=args.inhouseSamplesheetsInputDir + project + '.csv'
        #
        # Check if project samplesheet is present and if number of samples for this project is the same as in GD samplesheet.
        #
        if os.path.isfile(projectSamplesheetPath) and os.access(projectSamplesheetPath, os.R_OK):
            logger.write('File ' + projectSamplesheetPath + ' exists and is readable.' + ".\n")
        else:
            logger.write('FATAL: File ' + projectSamplesheetPath + ' is either missing or not readable.' + ".\n")
            sys.exit('FATAL ERROR! Check the log file: ' + args.logFile)
        if (projectCounts[project] == (len(open(projectSamplesheetPath).readlines())-1)):
            logger.write('Number of samples in GS samplesheet (' + str(projectCounts[project]) + ') is the same as in inhouse samplesheet for project: ' + project + ".\n")
        else:
            logger.write('FATAL: Number of samples in GS samplesheet (' + str(projectCounts[project]) + ') is NOT the same as in inhouse Project (' + (len(open(projectSamplesheetPath).readlines())-1) + ' for project ' + project + ".\n")
            sys.exit('FATAL ERROR! Check the log file: ' + args.logFile)
        #
        # Create new complete samplesheet.
        #
        printNewSamplesheet(projectSamplesheetPath, gsSamplesheetDataHashmap, args.samplesheetsOutputDir)

logger.write("\nSamplesheet merging DONE.\n")
logger.close()
print("\nSamplesheet merging DONE.\n")