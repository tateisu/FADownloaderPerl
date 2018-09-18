#!/usr/bin/perl --
use strict;
use warnings;
use Getopt::Long;
use Socket;
use AnyEvent;
use AnyEvent::HTTP;
use Data::Dump qw(dump);
use URI::Escape;
use Carp qw( cluck );
use Time::Local qw(timelocal);

# perlをインストール
# cpanminus をインストール
# 以下のコマンドでこのスクリプトの依存関係をインストール
# cpanm Data::Dump AnyEvent::HTTP URI::Escape 
# このスクリプトを起動
# perl fad.pl --net=192.168.1
# 起動したフォルダの下に downloadフォルダが出来てそこに転送される
# ダウンロード履歴の代わりにrecord フォルダができる

#########################################################

sub usage{
	print STDERR <<"END";

usage: $0 (options)...

options:

--net=(netspec)
   specify the your LAN network for detecting FlashAir.
   default is "192.168.1".

--df (folder)
--download-folder=(folder)
   specify the directory path for download image.
   default is "./download".

--rf (folder)
--record-folder=(folder)
   specify the directory path for check files to skil already download.
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
   download files only they has "read only" attrivute.
   default is not set.

--filetype=".jp* .raw"
   specify space separated list of file types.
   each file type can use wildcard ? and *
   default is ".jp*".

END
	exit 1;
}

#########################################################

my $net = "192.168.1";
my $downloadFolder = "./download";
my $recordFolder = "./record";
my $fileTypeSpec=".jp*";
my $checkInterval = 5;
my $verbose = 0;
my $intervalArpCheck = 5;
my $intervalSpray = 5;
my $timeoutFlashAirCheck = 15;
my $optProtectedOnly = 0;
my $downloadTimeout = 30;

GetOptions (
 "net=s" => \$net
,"df|download-folder=s" => \$downloadFolder
,"rf|record-folder=s" => \$recordFolder
,"i|interval=i" => \$checkInterval
,"v|verbose:+" => \$verbose
,"readonly:+" => \$optProtectedOnly
,"filetype=s" => \$fileTypeSpec
) or usage();

$net =~/\A\d+\.\d+\.\d+\z/ or die "parameter 'net': invalid  format.\n";

mkdir($downloadFolder);
mkdir($recordFolder);

(-d $downloadFolder) or die "parameter 'downloadFolder': is not directory.\n";
(-d $recordFolder) or die "parameter 'recordFolder': is not directory.\n";
($checkInterval >0 ) or die "parameter 'checkInterval': must greater than 0.\n";

my @reFileTypes ;
while( $fileTypeSpec =~ /(\S+)/g ){
	my $a = quotemeta($1);
	$a =~ s/\\([*])/.*?/;
	$a =~ s/\\([?])/[\\s\\S]/;
	warn "file type regex: $a\n";
	push @reFileTypes, qr/$a/i;
}
(@reFileTypes >0 ) or die "parameter 'filetype': must contains valid file types.\n";


my $downloadBusy = 0;
my $timeLastDownload = 0;
my $lastFlashAirStatus = -1;
my $targetAddr ="";
my @queue;
my $lastItem;

my $beforeFile = 1;
my $countFiles = 0;
my $countBytes = 0;
my $progressFiles = 0;
my $progressBytes = 0;
my $currentHttp;
my $progressBody;
my $currentFile ="";
my $currentFileSize =0;
my $progressEnabled;
my $lastProgressString="";

use subs 'log';
sub log{
	my @lt = localtime;
	$lt[4]+=1;
	$lt[5]+=1900;
	my $timestr = sprintf("%d-%02d-%02d_%02d:%02d:%02d",reverse @lt[0..5]);
	warn $timestr," ",@_,"\n";
}

#########################################################

my $cv = AnyEvent->condvar;

AnyEvent->signal(
	signal => "INT"
	, cb => sub {
		log( "signal INT catched.");
		$cv->send
	}
);



#########################################################
# flashair connection check

my %flashAirCheckStatus;
my $timeLastDetected =0;

sub startFlashAirCheck{
	my($addr)=@_;
	
	my $status = $flashAirCheckStatus{ $addr };
	$status or $status = $flashAirCheckStatus{ $addr } = {
		addr => $addr
		,alive => 0
		,timeLastOk => 0
	};

	return if $status->{alive};

	$status->{alive} = 1;
	
	my $url = "http://${addr}/command.cgi?op=108";

	$verbose >= 2 and log( "GET $url");

	$status->{http} = http_request (
		'GET' => $url
		,timeout => $timeoutFlashAirCheck
		,keepalive => 0
		,proxy => undef
		,sub {
			my($data, $headers) = @_;
			$status->{alive} = 0;
			$status->{http} = undef;
			if( $headers->{Status} == 200 ){
				log("$addr FlashAir detected.");
				my $now = time;
				$status->{timeLastOk} = $now;
				$timeLastDetected = $now;
			}
		}
	);
}


#########################################################
# read arp

my $timeLastArpCheck = 0;
my $lastStrDevices ="";
sub arpCheck{
	my $now = time;
	
	return if $downloadBusy;
	return if $now - $timeLastDetected < 15;

	return if $now -$timeLastArpCheck < $intervalArpCheck;
	$timeLastArpCheck = $now;

	$verbose and log("reading ARP table…");

	my $a = `arp -a`;
	$a or return log("can't read ARP table.");

	my(@addrs)= sort grep{
			/\A(\d+\.\d+\.\d+)\.(\d+)/;
			if( $1 ne $net){
				0
			}elsif( $2 eq "0" or $2 eq "1" or $2 eq "255" ){
				0
			}else{
				1
			}
		} 
		($a =~ /(\d+\.\d+\.\d+\.\d+)/g);

	my $strDevices = join(',',@addrs);
	if( $strDevices ne $lastStrDevices){
		$lastStrDevices = $strDevices;
		log("devices: ",$strDevices);
	}
	
	my %addrs;
	for my $addr(@addrs){
		$addrs{$addr} =1;
		startFlashAirCheck($addr);
	}
	for my $addr(keys %flashAirCheckStatus){
		next if $flashAirCheckStatus{$addr}{alive};
		$addrs{$addr} or delete $flashAirCheckStatus{$addr};
	}
}

#########################################################
# spray

my $timeLastSpray = 0;
sub spray{
	my $now = time;

	return if $downloadBusy;
	return if $now - $timeLastDetected < 15;
	return if $now - $timeLastSpray < $intervalSpray;
	$timeLastSpray = $now;

	$verbose and log("spray UDP packet to $net …");

	my $socket;

	if( not socket($socket, PF_INET, SOCK_DGRAM, 0) ){
		return log("can't open UDP socket. $!");
	}

	my $msg  = "0";
	my $port = 80;
	for(my $i=2;$i <= 254;++$i){
		my $ipstr = "$net.$i";
		my $ipaddr = inet_aton($ipstr);
		my $sockaddr = pack_sockaddr_in($port, $ipaddr);
		send($socket,$msg , 0, $sockaddr);
	}

	close($socket)
}


#########################################################

sub clearBusy{
	$timeLastDownload = time;
	$downloadBusy = 0;
}

sub formatFileSize($){
	my( $n )= @_;
	if($n >= 1000000000){
		return sprintf("%.1fG",$n/(1000000000));
	}elsif($n >= 1000000){
		return sprintf("%.1fM",$n/(1000000));
	}elsif( $n >= 1000){
		return sprintf("%.1fK",$n/(1000));
	}else{
		return sprintf("%d",$n);
	}
}

sub sayProgress{
	my $currnetBytes = length($progressBody);

	my $currnetBytesPercent;
	if( $currentFileSize <= 0 ){
		$currnetBytesPercent = 0;
	}else{
		$currnetBytesPercent = 100 * ($currnetBytes) / $currentFileSize ;
	}

	my $progressBytesPercent;
	if( $countBytes == 0 ){
		$progressBytesPercent = 0;
	}else{
		$progressBytesPercent = 100 * ($progressBytes+$currnetBytes) / $countBytes ;
	}
	
	my $line = sprintf("#total %s/%s(%d%%)bytes #current %s/%s(%d%%)bytes #file %d/%d %s"

		,formatFileSize($progressBytes+$currnetBytes)
		,formatFileSize($countBytes)
		,$progressBytesPercent

		,formatFileSize($currnetBytes)
		,formatFileSize($currentFileSize)
		,$currnetBytesPercent

		,$progressFiles +1,
		,$countFiles
		,$currentFile
	);
	
	if( $line ne $lastProgressString ){
		$lastProgressString = $line;
		log($line);
	}
}

sub statusErrorString($){
	my($headers)=@_;
	my $status = $headers->{Status};
	return "Connection failed." if $status == 595;
	return "Can't receive response." if $status == 596;
	return "Bad response." if $status == 597;
	return "Request cancelled." if $status == 598;

	return "HTTP error $status" if $status;

	return "(? missing status)";
}

sub readQueue;

sub handleFolderResult{
	eval{
		my($data,$headers)=@_;
		
		if( $headers->{Status} != 200 ){
			return log("$lastItem->{path} : ",statusErrorString($headers));
		}
		if( not defined $data ){
			return log("$lastItem->{path} : missing response body.");
		}
		while( $data =~ /([^\x0d\x0a]+)/g ){
			my $line = $1;
			
			next if not $line =~ /,(\d+),(\d+),(\d+),(\d+)$/;

			my $startMeta = $-[0]; # $line 中のマッチ開始位置
			my ($size,$attr,$bits_date,$bits_time)=map{ 0+$_} ($1,$2,$3,$4);

			my $y = (($bits_date >> 9) & 0x7f) + 1980;
			my $m = ($bits_date >> 5 )&  0xf;
			my $d = $bits_date & 0x1f;
			my $h = ($bits_time >> 11) & 0x1f;
			my $j = ($bits_time >> 5 )& 0x3f;
			my $s = ($bits_time & 0x1f) * 2;
			my $time = timelocal($s,$j,$h,$d,$m-1,$y-1900);

			## https://flashair-developers.com/ja/support/forum/#/discussion/3/%E3%82%AB%E3%83%B3%E3%83%9E%E5%8C%BA%E5%88%87%E3%82%8A
			my $dir = $lastItem->{path} eq "/" ? "" : $lastItem->{path};
			my $dir_length = length($dir)+1;
			my $file_name = substr($line, $dir_length, $startMeta - $dir_length);

			if( $attr & 2 ){
				$verbose and log("$file_name : skip hidden file.");
				next;
			}

			if( $attr & 4 ){
				$verbose and log( "$file_name : skip system file.");
				next;
			}

			my $item = {
				 path => "$dir/$file_name"
				 , isFolder => ($attr & 0x10)
				 , size => $size 
			};

			if( $item->{isFolder} ){
				# フォルダはキューの頭に追加
				unshift @queue, $item;

			}else{
				# 設定によっては、リードオンリーがオフのファイルは転送しない
				if( $optProtectedOnly and 0==($attr & 1) ){
					$verbose and log( "$file_name : not readonly.");
					next;
				}
				
				# ファイル拡張子がマッチしないなら転送しない
				if( not grep{ $file_name =~ /$_\z/i} @reFileTypes ){
					$verbose and log( "$file_name : not match to file types.");
					next;
				}
				my $dateFolder = sprintf("%d%02d%02d",$y,$m,$d);
				$item->{downloadPath} = "$downloadFolder/$dateFolder/$file_name";
				$item->{recordPath} = "$recordFolder/$dateFolder/$file_name";
				
				# 既読スキップ1
				if(-f $item->{recordPath} ){
					$verbose and log( "$file_name : already downloaded.");
					next;
				}
				
				# 既読スキップ2
				my $fs = (-s $item->{downloadPath});
				if( $fs and $fs >= $size ){
					$verbose and log( "$file_name : already downloaded.");
					next;
				}

				mkdir("$downloadFolder/$dateFolder");
				mkdir("$recordFolder/$dateFolder");

				# ファイルはキューの末尾に追加
				push @queue,$item;
			}
		}
	
	};
	$@ and cluck $@;
	readQueue();
}

sub writeFile{
	my($path,$data)=@_;
	if( not open(my $fh,">:raw",$path) ){
		log("$path: $!");
	}else{
		print $fh $data;
		if( not close ($fh) ){
			log( "$path: $!");
		}else{
			log( "$path file saved.");
		}
	}
}

sub handleFileResult{
	eval{

		sayProgress();

		my($data,$headers)=@_;
		
		my $item = $lastItem;
		
		if( $headers->{Status} != 200 ){
			return log( "$lastItem->{path} : ",statusErrorString($headers));
		}

		if( not defined $data ){
			return log( "$item->{path} : missing response body.");
		}

		if( $progressBody ){
			$data = $progressBody;
		}
		writeFile($item->{downloadPath},$data);
		writeFile($item->{recordPath},"");
	};
	$@ and cluck $@;

	$progressFiles++;
	$progressBytes+= $lastItem->{size};

	readQueue();
}


sub readQueue{
	$progressEnabled = 0;
	$lastProgressString = "";
	$progressBody="";
	$currentFile ="";
	$currentFileSize=0;

	if( not @queue ){
		log("Scan complete.");
		clearBusy();
		return;
	}

	if( $beforeFile && ! $queue[0]->{isFolder} ){
		$beforeFile = 0;
		## 転送予定のファイル数とバイト数を調べる
		$countFiles = 0;
		$countBytes = 0;
		$progressFiles = 0;
		$progressBytes = 0;
		for my $item (@queue){
			next if $item->{isFolder};
			$countFiles += 1;
			$countBytes += $item->{size};
		}
	}

	my $item = shift @queue;
	$lastItem = $item;
	if( $item->{isFolder} ){
		log("$item->{path} reading directory…");
		$currentHttp = http_get "http://$targetAddr/command.cgi?op=100&DIR=".uri_escape($item->{path})
			,timeout => $downloadTimeout
			,keepalive => 0
			,proxy => undef
			,\&handleFolderResult;
	}else{

		$progressEnabled = 1;
		$currentFile = $item->{path};
		$currentFileSize = $item->{size};
		log( "$item->{path} reading file…");

		$currentHttp = http_get "http://$targetAddr/".uri_escape($item->{path})
			,timeout => $downloadTimeout
			,keepalive => 0
			,proxy => undef
			,on_body => sub{
				# my($partial_body, $headers)=@_;
				$progressBody .= $_[0] if defined $_[0];
			}
			,\&handleFileResult;
		
	}
}

sub download{

	return if $downloadBusy;

	my $now = time;
	return if $now -$timeLastDownload < $checkInterval;

	# ターゲットデバイス
	my($device) = 
		sort{ $b->{timeLastOk} <=> $a->{timeLastOk} } 
		grep{ $_->{timeLastOk} } 
		values %flashAirCheckStatus;
	return if not $device;

	# ダウンロード処理中
	$downloadBusy =1;
	$timeLastDownload = $now;
	$targetAddr = $device->{addr};
	$beforeFile = 1;
	@queue=();

	# FlashAir 更新ステータスの確認
	$currentHttp = http_get "http://$targetAddr/command.cgi?op=121"
		,timeout => $downloadTimeout
		,keepalive => 0
		,proxy => undef
		,sub{
			my($data,$headers)=@_;
			if( $headers->{Status} != 200 or not defined $data ){
				# ステータス取得ができない
				log( "$targetAddr : ",statusErrorString($headers));
				if( $headers->{Status} >= 590 ){
					clearBusy();
					return;
				}
				# 古いFlashAirかもしれない。通常のスキャンを行う
			}elsif( not $data =~/(-?\s*\d+)/ ){
				# ステータス取得ができない
				log( "can't get FlashAir update status. data=$data");
				# 古いFlashAirかもしれない。通常のスキャンを行う
			}else{
				my $v = 0+ $1;
				if( $v != -1 and $v == $lastFlashAirStatus ){
					# 前回スキャン開始時と同じ値なので変更されていない
					log( "FlashAir update status is not changed.");
					clearBusy();
					return;
				}else{
					log( "FlashAir update status is changed. $lastFlashAirStatus => $v");
					$lastFlashAirStatus = $v;
				}
			}
			push @queue,{ path => "/" ,isFolder => 1};
			readQueue();
		}
}

##########################################################

# 1秒ごとのタイマー
my $timer = AnyEvent->timer(
	after =>1
	,interval => 1
	,cb => sub { 
		download();
		arpCheck();
		spray();
		$verbose >= 10 and log("anyevent active connections: $AnyEvent::HTTP::ACTIVE");
		
		if( $progressEnabled ){
			sayProgress();
		}
	}
);

# イベントループ開始
log( "AnyEvent loop start.");
$cv->recv(); 
log( "AnyEvent loop end.");