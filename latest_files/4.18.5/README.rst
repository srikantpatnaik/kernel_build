This directory contains the following fixes for RDP thinbook(11.6")
-------------------------------------------------------------------

#. Clear audio. Eliminates popping sound from background
#. Headphone/speaker auto detect
#. Internal and headset microphones work

This update will break the following
------------------------------------

#. Unreliable bluetooth detection: 
   Bluetooth works sometimes. Say 2 out of 10 reboots.
   I believe there is no issue with the driver, at boot time it gets hindered by some 
   driver/process, not sure, need more digging. 
   

#. Poor wireless:
   Signal strength fluctuates around 30% compare to 70% in kernel 4.16 or below). No issue 
   in connectivity and speed test. 


How to apply the fixes?
-----------------------
1. copy updated audio parameters to UCM location ::

    sudo cp -rv bytcr-rt5651 /usr/share/alsa/ucm

2. Copy asound.state ::
    sudo cp -v asound.state /var/lib/alsa

3. We need a Kernel version 4.17 or above.
   A ready to use Kernel can be obtained from `here <https://drive.google.com/drive/folders/1h31393xiC-_WazJSwAx_XsxGBoMLYtn6>`_. 


