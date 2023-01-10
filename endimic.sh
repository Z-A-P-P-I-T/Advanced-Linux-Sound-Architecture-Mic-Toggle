#!/bin/bash

title="Advanced Linux Sound Architecture Mic Toggle"
echo "------------------------------------------------------------"
echo "------- $title -------"
echo "------------------------------------------------------------"

while getopts ":o:" opt; do
  case $opt in
    o)
      state="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

if [[ -z "$state" ]]; then
  state=$(sudo amixer sset Capture toggle | grep -o "on\|off")
else
  sudo amixer sset Capture $state
fi
echo "Current State: $state"
echo "------------------------------------------------------------"
echo "--------------- Your Mic Has Been Modified -----------------"
echo "------------------------------------------------------------"

read -p "Press any key to continue" -t 3
