# BSCF - BBS Single Connection Filter

This is an entry point gateway for a telnet BBS that only allows one connection at a time. This program can be used to gracefully handle follow up connections while the BBS is busy as well as show a template file when the destination BBS is currently offline.

Currently this is being written for use with my Atari 8-bit BBS [Action 8](https://github.com/shamrice/action8bbs) but can be configured for any type of BBS.

## Usage ##
Foreground usage:
```
./script/bscf
```

Background usage:

*start:*
```
./script/start.sh
```

*stop:*
```
./script/stop.sh
```

## Additional Credits ##
The idea for this application came from [BusyBBS](https://www.southernamis.com/busybbs) written by John Polka. Honestly, I would have just used his application if I had a Windows set up already running. I needed something for Linux and decided to write this and add some QoL customizations for my personal needs.



