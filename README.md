# co2mini
Module to get CO2 readings from a co2mini device (sold under various names), with USB ID 04d9:a052

## Installation 
In FHEM do this:

`update add https://raw.githubusercontent.com/ThorstenPferdekaemper/FHEM-co2mini/master/controls_co2mini.txt`

`update all co2mini`

Wait for it to finish, including commandref rebuild.

`shutdown restart`

The CO2 sensor appears as /dev/hidraw<n>, e.g. /dev/hidraw0. Make sure that the fhem user can access this device file. 
The easiest way to achieve this is by copying the file /opt/fhem/FHEM/lib/co2mini/90-co2mini.rules into directory /etc/udev/rules.d and then reboot the system.
This makes sure that the device is accessible by the fhem user under the name /dev/co2mini0. 
This probably does not work if you have multiple co2mini sensors attached. 

Check local commandref for co2mini on how to create the co2mini device in FHEM.

## References
Reverse engineering documented in https://hackaday.io/project/5301-reverse-engineering-a-low-cost-usb-co-monitor
