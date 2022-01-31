# co2mini
Module to get CO2 readings from a co2mini device (sold under various names), with USB ID 04d9:a052

## Installation 
In FHEM do this:
- `update add https://raw.githubusercontent.com/ThorstenPferdekaemper/FHEM-co2mini/master/controls_co2mini.txt`
- `update all co2mini`
Wait for it to finish, including commandref rebuild.
- `shutdown restart`
Check local commandref for co2mini.

## References
Reverse engineering documented in https://hackaday.io/project/5301-reverse-engineering-a-low-cost-usb-co-monitor
