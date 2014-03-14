#!/usr/bin/perl
=description

Authors:
Alexander Kaidalov <kaidalov@fastvps.ru>
Pavel Odintsov <odintsov@fastvps.ee>
License: GPLv2

=cut

# TODO
# Добавить выгрузку информации по Физическим Дискам: 
# megacli -PDList -Aall
# arcconf getconfig 1 pd
# Перенести исключение ploop на этап идентификации дисковых устройств
# Добавить явно User Agent как у мониторинга, чтобы в случае чего их не лочило
# В случае Adaptec номер контроллера зафикисрован как 1

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request::Common qw(GET POST);
use File::Spec;

use Data::Dumper;

# Конфигурация
my $VERSION = "1.0";

# diagnostic utilities
my $ADAPTEC_UTILITY = '/usr/local/bin/arcconf';
my $LSI_UTILITY = '/opt/MegaRAID/MegaCli/MegaCli64';

# API
my $API_URL = 'https://bill2fast.com/monitoring_control.php';

# Centos && Debian uses same path
my $parted = "LANG=POSIX /sbin/parted";

# find disks
my %disks = find_disks();

my $only_detect_drives = 0;

# Запуск из крона
my $cron_run = 0;

if (scalar @ARGV > 0 and $ARGV[0] eq '--detect') {
    $only_detect_drives = 1;

    print Dumper(\%disks);
    exit(0);
}

if (scalar @ARGV > 0 and $ARGV[0] eq '--cron') {
    $cron_run = 1;
}

if ($cron_run) {
    if(!send_disks_results(%disks)) {
        print "Failed to send storage monitoring data to FastVPS";
        exit(1);
    }
}

if ($only_detect_drives) {
    # Детектируем винты и выводим их
}

# check diag utilities
check_disk_utilities(%disks);

# get all info from disks
%disks = diag_disks(%disks);

if (!$only_detect_drives && !$cron_run) {
    print "This information was gathered and will be sent to FastVPS:\n";
    print "Disks found: " . (scalar keys %disks) . "\n\n";

    while((my $key, my $value) = each(%disks)) {   
        print $key . " is " . $value->{'disk'}->{'type'} . " Diagnostic data:\n";
        print $value->{'diag'} . "\n\n";
    }       
}



#
# Functions
#

# Функция обнаружения всех дисковых устройств в системе
sub find_disks {
    # here we'll save disk => ( info, ... )
    my %disks = ();
    
    # get list of disk devices with parted 
    my @parted_output = `$parted -lms`;

    if ($? != 0) {
        die "Can't get parted output. Not installed?!";
    }
 
    for my $line (@parted_output) {
        chomp $line;
        # skip empty line
        next if $line =~ /^\s/;
        next unless $line =~ m#^/dev#;   

        # После очистки нам приходят лишь строки вида:
        # /dev/sda:3597GB:scsi:512:512:gpt:DELL PERC H710P;
        # /dev/sda:599GB:scsi:512:512:msdos:Adaptec Device 0;
        # /dev/md0:4302MB:md:512:512:loop:Linux Software RAID Array;
        # /dev/sdc:1500GB:scsi:512:512:msdos:ATA ST31500341AS;

        # Отрезаем точку с запятой в конце
        $line =~ s/;$//; 
            
        # get fields
        my @fields = split ':', $line;
        my $device_name = $fields[0];        
        my $device_size = $fields[1]; 
        my $model = $fields[6];

        # Это виртуальные устройства в OpenVZ, их не нужно анализировать
        if ($device_name =~ m#/dev/ploop\d+#) {
            next;
        }

        # add to list
        my $tmp_disk = {};
        $tmp_disk->{"disk"} = {
            "device" => $device_name,
            "size"   => $device_size,
            "model"  => $model,
        };
    
        # detect type (raid or disk)
        my $type = 'disk';
                    
        # adaptec
        if($model =~ m/adaptec/i) {
            $type = 'adaptec';
        }
            
        # Linux MD raid (Soft RAID)
        $type = 'md' if $fields[0] =~ m/\/md\d+/;
            
        # LSI (3ware)
        $type = 'lsi' if $fields[6] =~ m/lsi/i;
            
        # add type
        $tmp_disk->{"disk"}{"type"} = $type;
        

        %{$disks{$tmp_disk->{"disk"}->{"device"}}} = %$tmp_disk;    
    }

    return %disks;
}

# Check diagnostic utilities availability
sub check_disk_utilities {
    my (%disks) = @_;

    my $adaptec_needed = 0;
    my $lsi_needed = 0;

    while((my $key, my $value) = each(%disks)) {
        # Adaptec
        if($value->{"disk"}{type} eq "adaptec") {
            $adaptec_needed = 1;
        }
            
        # LSI
        if($value->{"disk"}{type} eq "lsi") {
            $lsi_needed = 1;
        }
    }

    if ($adaptec_needed) {
        die "Adaptec utility not found. Please, install Adaptech raid management utility into " . $ADAPTEC_UTILITY . "\n" unless -e $ADAPTEC_UTILITY;
    }

    if ($lsi_needed) {
        die "not found. Please, install LSI MegaCli raid management utility into " . $LSI_UTILITY . " (symlink if needed)\n" unless -e $LSI_UTILITY
    }

    return ($adaptec_needed, $lsi_needed);
}

# Run disgnostic utility for each disk
sub diag_disks {
    my (%disks) = @_;

    while((my $key, my $value) = each(%disks)) {
        my $type = $value->{"disk"}{"type"};
        my $res = '';
        my $cmd = '';
            
        # adaptec
        if($type eq "adaptec") {
            $cmd = $ADAPTEC_UTILITY . " getconfig 1 ld";
        }

        # md
        if($type eq "md") {    
            $cmd = 'cat /proc/mdstat';
        }

        # lsi (3ware)
        # TODO:
        if($type eq "lsi") {
            # it may be run with -L<num> for specific logical drive
            $cmd = $LSI_UTILITY . " -LDInfo -Lall -Aall";
        }
            
        # disk
        if($type eq "disk") {
            $cmd = "smartctl --all $key";
        }

        $res = `$cmd` if $cmd;
        $disks{$key}{"diag"} = $res;
    }

    return %disks;
}

# Send disks diag results
sub send_disks_results {
    my (%disks) = @_;

    foreach(keys(%disks)) {
        my $disk = $disks{$_};
        my $diag = $disk->{'diag'};
            
        # send results
        my $status = 'error';
        $status = 'success' if $diag ne '';
                
        my $req = POST($API_URL, [
            action => "save_data",
            status => $status,
            agent_name => 'disks',
            agent_data => $diag,
            agent_version => $VERSION,
        ]);

        # get result
        my $ua = LWP::UserAgent->new();
        my $res = $ua->request($req);
                
        # TODO: check $res? old data in monitoring system will be notices
        #       one way or the other...

        return $res->is_success;
    }
}

