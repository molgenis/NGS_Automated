#!/usr/bin/env python3

import os
import glob
import csv
import sys
import re
import argparse
from collections import defaultdict
from os.path import basename
import logging

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
        # Check if columns are present and extra columns if necessary.
        # Columns may or may not already be present depending on
        #  * version of Darwin code that produced the samplesheet
        #  * whether were prepped at GenomeScan or in our own lab.
        #
        _potentiallyMissingColumns = ['barcode', 'barcode1', 'barcode2', 'GS_ID', 'gsBatch','gsBatchFolderName']
        for _potentiallyMissingColumn in _potentiallyMissingColumns:
            if not _potentiallyMissingColumn in _headers:
                _headers.append(_potentiallyMissingColumn)
        #
        # Parse sample from inhouse samplesheet.
        #
        _newRows = []
        _newRows.append(_headers)
        for _row in _reader:
            _sampleProcessStepID = _row['sampleProcessStepID'] # Uniquely identifies a sample.
            logging.debug('Found sampleProcessStepID ' + _sampleProcessStepID + '; starting lookup of additional sample meta data in _gsSamplesheetDataHashmap ...')
            #
            # Try to create new rows: one for each flowcell-lane combination for each sample (=sampleProcessStepID).
            #
            # Example data structure of _gsSamplesheetDataHashmap:
            # defaultdict(<type 'dict'>, {
            #    '123456': {
            #        'project': 'QXTR_426-Exoom_v1', 'GS_ID': '103373-032-059', 
            #        'FastQs': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CTCTCTAC-AGAGGATA'}, 
            #                   {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CTCTCTAC-AGAGGATA'}]},
            #
            # The key '123456' in the example above is the sampleProcessStepID.
            #
            try:
                if _row['project'] == _gsSamplesheetDataHashmap[_sampleProcessStepID]['project']:
                    
                    _newRowValues = []
                    for _header in _headers:
                        if _header == 'GS_ID':
                            _newRowValues.append(_gsSamplesheetDataHashmap[_sampleProcessStepID]['GS_ID'])
                        elif _header == 'gsBatch':
                            _newRowValues.append(_gsSamplesheetDataHashmap[_sampleProcessStepID]['gsBatch'])
                        elif _header == 'gsBatchFolderName':
                            _newRowValues.append(_gsSamplesheetDataHashmap[_sampleProcessStepID]['gsBatchFolderName'])
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
                    logging.critical('Project name for the sample with sampleProcessStepID ' + sampleProcessStepID + ' from inhouse sample sheet and from GenomeScan sample sheet is not the same project.')
                    sys.exit('FATAL ERROR!')
            except:
                logging.critical('Failed to supplement sample with sampleProcessStepID ' + sampleProcessStepID + ' with meta-data from GenomeScan sample sheet.')
                sys.exit('FATAL ERROR!')
        _f1.close()
    #
    # Write new inhouse complete samplesheet per project.
    #
    _newSamplesheetPath = _samplesheetsOutputDir + basename(_projectSamplesheetPath)
    logging.info('Writing new complete samplesheet to: ' + _newSamplesheetPath + ' ...')
    with open(_newSamplesheetPath, 'w') as f2:
        writer = csv.writer(f2, delimiter = ',')
        writer.writerows(_newRows)
    f2.close()



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
parser.add_argument("--inhouseSamplesheetsInputDir", type=readableDir, required=True, help='Input directory containing incomplete new inhouse samplesheets.')
parser.add_argument("--samplesheetsOutputDir", type=readableDir, required=True, help='Directory where complete, merged inhouse samplesheets are stored.')
parser.add_argument("--batchName", required=True, help='name of the folder of the batch')
parser.add_argument("--logLevel", required=False, default='INFO', choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'])
args = parser.parse_args()
#
# Initialize logging.
#
numericLogLevel = getattr(logging, args.logLevel.upper(), None)
if not isinstance(numericLogLevel, int):
    raise ValueError('Invalid log level specified with --logLevel: %s' % args.logLevel)
logging.basicConfig(level=numericLogLevel, format='%(filename)s %(asctime)s %(levelname)s @ L:%(lineno)d> %(message)s')
logging.info('Starting to combine samplesheets...')

#
# Check if input and output path are not the same.
#
if args.samplesheetsOutputDir == args.inhouseSamplesheetsInputDir:
    logging.critical('Samplesheet input and output folder are the same. Choose another folder for the output to prevent overwriting original files.')
    sys.exit('FATAL ERROR!')
#
# Check availability and readability of GS samplesheet.
#
for gsSamplesheetFile in glob.iglob(os.path.join(args.genomeScanInputDir, "UMCG_CSV_*.csv.converted")):
    if os.path.isfile(gsSamplesheetFile) and os.access(gsSamplesheetFile, os.R_OK):
        logging.info('Found GenomeScan samplesheet: ' + gsSamplesheetFile + '.')
    else:
        logging.critical('Either the ' + args.genomeScanInputDir + 'UMCG_CSV_*.csv.converted file is missing or it is not readable.')
        sys.exit('FATAL ERROR!')


# For debugging data structure only:
#import pprint
#pp = pprint.PrettyPrinter(indent=4)
#pp.pprint(gsFilenameDataHashmap)
#pp.pprint('=====================================================')

#
# Combine GS samplesheet with original filename information form gsFilenameDataHashmap.
#
# GS samplesheet filestructure for samples prepped not at GenomeScan and send in as pools:
#          GS_ID,         Sample_ID, Pool,   Index1,   Index2
# 103473-011-001, QXTR_222-Exoom_v1,    1, CGAGGCTG, AGGCTTAG
#
## GS samplesheet filestructure for samples prepped at GenomeScan:
#          GS_ID,                    ID, positie, geslacht, Pool,   Index1,   Index2
# 103473-011-001, GS_1A-Exoom_v3-123456,     A01,        V,    1, CGAGGCTG, AGGCTTAG
#
gsSamplesheetFileHandle = open(gsSamplesheetFile,'r')
gsReader = csv.DictReader(gsSamplesheetFileHandle)
gsHeaders = gsReader.fieldnames
gsSampleIdColumnName = 'Missing'
gsSamplesheetDataHashmap = defaultdict(dict)
gsProjects = []
if 'Sample_ID' in gsHeaders:
    gsSampleIdColumnName = 'Sample_ID'
elif 'ID' in gsHeaders:
    gsSampleIdColumnName = 'ID'
else:
    logging.critical('Cannot find sample ID column name in ' + gsSamplesheetFile + '.')
    sys.exit('FATAL ERROR!')
logging.debug('Found sample ID column name ' + gsSampleIdColumnName + ' in ' + gsSamplesheetFile + '.')

for row in gsReader:
    
    if row[gsSampleIdColumnName] in (None,""):
        logging.warning('Empty row detected in GS samplesheet.')
        continue
    #
    # The "sample ID" provided to GenomeScan by our lab is a combination of
    #  * project
    #  * sampleProcessStepID; a unique value for each sample.
    # Use a regular expression to parse the individual values from the combi.
    #
    if re.match("(^[a-zA-Z0-9_-]+)-([0-9]+)$", row[gsSampleIdColumnName]):
        m = re.match("(^[a-zA-Z0-9_-]+)-([0-9]+)$", row[gsSampleIdColumnName])
        gsProject = m.group(1)
        gsSampleProcessStepID = m.group(2)
        logging.debug('Found project ' + gsProject + ' and sampleProcessStepID ' + gsSampleProcessStepID + ' in column ' + gsSampleIdColumnName + '.')
    else:
        logging.critical('Cannot parse project name and sampleProcessStepID from "' + row[gsSampleIdColumnName] + '" in column ' + gsSampleIdColumnName + ' from ' + gsSamplesheetFile + '.')
        sys.exit('FATAL ERROR!')
    gsGenomeScanID=row['GS_ID']
    if re.match("(^[0-9]+-[0-9]+)-([0-9]+)$", row['GS_ID']):
        b = re.match("(^[0-9]+-[0-9]+)-([0-9]+)$", row['GS_ID'])
        gsBatch= b.group(1)
        gsProjects.append(gsProject)
        gsBarcodesAndGenomeScanID = row['Index1'] + '-' + row['Index2'] + '-' + gsGenomeScanID
    else:
        logging.critical('Cannot parse gsBatch name and project from "' + row[gsGenomeScanID] + '" in column ' + gsGenomeScanID + ' from ' + gsSamplesheetFile + '.')
        sys.exit('FATAL ERROR!')
    if gsSampleProcessStepID in gsSamplesheetDataHashmap:
        logging.critical('sampleProcessStepID ' + gsSampleProcessStepID + ' is not uniq in project ' + gsProject + '.')
        sys.exit('FATAL ERROR!')
    #
    # Example data structure of gsSamplesheetDataHashmap:
    # defaultdict(<type 'dict'>, {
    #    '123456': {
    #        'project': 'QXTR_426-Exoom_v1', 'GS_ID': '103373-032-059', 
    #        'FastQs': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CTCTCTAC-AGAGGATA'}, 
    #                   {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CTCTCTAC-AGAGGATA'}]},
    #    '789012': {
    #        'project': 'QXTR_426-Exoom_v1', 'GS_ID': '103373-032-058', 
    #        'FastQs': [{'lane': '7', 'sequencingStartDate': '181128', 'run': '0363', 'sequencer': 'K00296', 'flowcell': 'H2TGVBBXY', 'barcodes': 'CAGAGAGG-TCTACTCT'}, 
    #                   {'lane': '8', 'sequencingStartDate': '181128', 'run': '0364', 'sequencer': 'K00296', 'flowcell': 'HYKGJBBXX', 'barcodes': 'CAGAGAGG-TCTACTCT'}]}}
    #
    if args.batchName == gsBatch:
        logging.debug('args.batchName ' + args.batchName + ' is the same as ' + gsBatch)
        gsSamplesheetDataHashmap[gsSampleProcessStepID] = {
            'project': gsProject, 'GS_ID': gsGenomeScanID, 'gsBatch': gsBatch
        }
    else:
        logging.debug('args.batchName: ' + args.batchName + ' , is NOT the same as: ' + gsBatch)
        gsSamplesheetDataHashmap[gsSampleProcessStepID] = {
           'project': gsProject, 'GS_ID': gsGenomeScanID, 'gsBatch': gsBatch, 'gsBatchFolderName': args.batchName
        }
gsSamplesheetFileHandle.close()
#
# Get list of uniq project names and count number of samples per project.
#
uniqProjects =(sorted(set(gsProjects)))
projectCounts={}
for uniqProject in (uniqProjects):
    projectCounts[uniqProject]=gsProjects.count(uniqProject)
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
            logging.debug('File ' + projectSamplesheetPath + ' exists and is readable.')
        else:
            logging.critical('File ' + projectSamplesheetPath + ' is either missing or not readable.')
            sys.exit('FATAL ERROR!')
        if (projectCounts[project] == (len(open(projectSamplesheetPath).readlines())-1)):
            logging.debug('Number of samples in GS samplesheet (' + str(projectCounts[project]) + ') is the same as in inhouse samplesheet for project: ' + project + '.')
        else:
            logging.critical('Number of samples in GS samplesheet (' + str(projectCounts[project]) + ') is NOT the same as in inhouse Project (' + str(len(open(projectSamplesheetPath).readlines())-1) + ') for project ' + project + '.')
            sys.exit('FATAL ERROR!')
        #
        # Create new complete samplesheet.
        #
        printNewSamplesheet(projectSamplesheetPath, gsSamplesheetDataHashmap, args.samplesheetsOutputDir)

logging.info('Samplesheet merging DONE!')
