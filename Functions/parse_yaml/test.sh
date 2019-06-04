#!/bin/sh

# include parse_yaml function
. parse_yaml.sh

echo "===== Read and dump (test) ====="
parse_yaml sample-conf.yaml "SAMPLE"

echo "===== Read and set ====="
eval $( parse_yaml sample-conf.yaml "SAMPLE" )

echo "===== dump envs ===="
set | grep '^SAMPLE'

