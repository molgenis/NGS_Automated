import sys
import csv

reader = csv.DictReader(open(sys.argv[1], "rb"), delimiter=",")
project=open(sys.argv[2],"w")

count=0
for row in reader:
        for (k,v) in row.items():
                if "project" in row:
                        if k == "project":
                                project.write(v+'\n')
