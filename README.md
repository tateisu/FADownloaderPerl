# FADownloaderPerl
Perl script to detect FlashAir SD-WLAN card in network and download files.

## Usage

```
usage: perl fad.pl (options)...

options:

--net=(netspec)
   for detecting FlashAir, specify the "first 3 number part in IPv4 address" of your LAN network.
   default is "192.168.1".

--df (folder)
--download-folder=(folder)
   specify the directory path for download image.
   default is "./download".

--rf (folder)
--record-folder=(folder)
   specify the directory path for check files to skip already download.
   default is "./record".

-i (seconds)
--interval=(seconds)
   specify the seconds for polling interval.
   default is 5.

-v
--verbose
   verbose output for detecting trouble.
   default is not set.

--readonly
   download files only they has "read only" attribute.
   default is not set.

--filetype=".jp* .raw"
   specify space separated list of file types.
   each file type can use wildcard ? and *
   default is ".jp*".
```

## Setup
- Install Perl. https://www.perl.org/get.html
- Install cpanminus. https://metacpan.org/pod/App::cpanminus
- Run `cpanm Data::Dump AnyEvent::HTTP URI::Escape` to install dependencies of this app.
- Download fad.pl from this repository.
- Configure your FlashAir card using STA mode or Internet pass thru mode, congigure the card that connect to your WLAN network that reachable from your PC that runs this app.
- Please find your WLAN network address.
- Run `perl fad.pl --net=192.168.1`. please change the value of --net option to "first 3 number part in IPv4 address".

## Behavor of detecting FlashAir card
- This app periodically send UDP packet to all address in WLAN network, instead of send ARP request.
- This app periodically runs `arp -a` command to detect addresses in WLAN network.
- This app periodically send HTTP requests to detected addresses to find FlashAir card.

## Behavor of file download
- This app will periodically scans files in download files in FlashAir card.
- The file that has hidden/system attributes, or that's name is not match file types, or that is already downloaded will be ignored.
- This app will download files in FlashAir card and save it to "./download/{YYYYMMDD}/{file}". 
- This app also create empty file "./record/{YYYYMMDD}/{file}" to check the file is already download.

