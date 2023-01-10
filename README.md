# Advanced-Linux-Sound-Architecture-Mic-Toggle
Here is a very short script that might come in handy if you wan't to quickly be able to disable/enable your microphone.

Since ALSA subsides under PULSE there is no way to add 'On/Off' functionality without using the ALSA toggle.

Usage:

chmod +x endimic.sh

./endimic.sh -o on
It will set microphone state to on.


./endimic.sh 
It will toggle the microphone's state.
