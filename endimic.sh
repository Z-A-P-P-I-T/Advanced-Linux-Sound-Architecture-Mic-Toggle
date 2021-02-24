#!/bin/bash
echo ------------------------------------------------------------
echo ------- Advanced Linux Sound Architecture Mic Toggle -------
echo ------------------------------------------------------------
echo                                                             
sleep 1
#amixer -c 0 set Mic mute
#sleep 1
sudo amixer sset Capture toggle > endimiclog.txt
sleep 1

sleep 1
grep -w "on\|off" endimiclog.txt
	
sleep 1
echo                                                             
echo ------------------------------------------------------------
echo --------------- Your Mic Has Been Modified -----------------
echo ------------------------------------------------------------
echo                                                             
sleep 3
exit
